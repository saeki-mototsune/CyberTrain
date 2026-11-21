require "json"
require "cybertrain/http/query"
require "cybertrain/http/response"

module Cybertrain
  # The one place that says which exceptions out of the app are the client's
  # fault and what status they get. Server#respond (a bare app), ErrorPages
  # (production) and Dev::ErrorPage (development) each catch everything the
  # app raises and ask here first, so a new client-fault class (a body-size
  # or multipart limit, say) is added once and all three paths answer alike
  # instead of one of them quietly answering 500.
  module ClientError
    # The status for an exception out of the app, logged at the level it
    # deserves: a client fault (request parameters past Query's limits or
    # not decodable, QueryInvalid; or a class in {.extra_faults}, such as a
    # framework's missing-required-parameter error) is its 4xx at info, so
    # a flood of them does not fill the error log; anything else is 500 at
    # error, as `class: message`. Each error path then does
    # `reset_to(status)` (or its own 500 page); the layer's next
    # client-fault class is added to CLIENT_FAULTS below and nowhere else,
    # and one defined outside the layer to {.extra_faults}.
    # @param e [Exception]
    # @param logger [HttpLog] the Server's sink, the base or a subclass
    # @return [Integer] 400 or 500 ({.status_for})
    def self.classify(e, logger)
      status = self.status_for(e)
      if status >= 500
        logger.error("#{e.class.name.to_s}: #{e.message}")
      else
        logger.info("rejected request (#{status} #{Response.status_text(status)}): #{e.message}")
      end
      status
    end

    # Full class names of the client-fault exceptions: THE list, and the one
    # place to add a new one (a new QueryInvalid subclass, say). The list
    # stands in for `e.is_a?(QueryInvalid)`: on Spinel 2026.09.12 is_a? on
    # an exception object answered false for its own superclass (a
    # QueryTooDeep reached every error path as a 500, NOTES rule 47), and a
    # raised QueryTooMany's class chain was QueryTooMany, Object,
    # BasicObject (rule 54). On the pinned build small programs of both
    # shapes answer as CRuby does for classes the program defines, while
    # `superclass` still raises NoMethodError on a package's exception
    # class and, in a program that defines a module, on Ruby's own (NOTES
    # status 47, 54 and 104). The list stays until a change replaces it
    # with a compiled test of these error paths. Matching by class name is
    # what Controller#rescue_with_handler does for rescue_from.
    #
    # Every subclass must be listed by its full name, which is what
    # ClientError.status_for compares. An app's own exception class, even
    # one that subclasses QueryLimitExceeded, is the app's 500; the list is the
    # layer's. script/check-client-faults (run by CI) fails when a
    # client-fault class is in neither this list nor {.extra_faults}, or an
    # entry names no class.
    CLIENT_FAULTS = ["Cybertrain::QueryInvalid", "Cybertrain::QueryLimitExceeded",
                     "Cybertrain::QueryTooDeep", "Cybertrain::QueryTooMany",
                     "Cybertrain::QueryMalformed",
                     "Cybertrain::BodyUndecodable", "Cybertrain::BodyTooLarge",
                     "Cybertrain::MultipartMalformed", "Cybertrain::MultipartTooManyParts",
                     "Cybertrain::MultipartPartTooLarge", "Cybertrain::MultipartHeaderTooLarge"]

    # The client faults the layer does not define: full class names,
    # matched exactly as CLIENT_FAULTS' are. Registering one is the job of
    # the library that defines the class, at load (a framework's
    # missing-required-parameter error, say); a program that never loads
    # that registration answers the class with 500. A module-level ivar
    # with a literal default (the Params.max_page shape, spikes/NOTES.md
    # rule 18).
    @extra_faults = Array.new(0) { "" }

    # The client faults registered on top of CLIENT_FAULTS, empty until a
    # library adds one with {.extra_faults=}.
    # @return [Array<String>] full class names
    # @api public
    def self.extra_faults
      @extra_faults
    end

    # Installs the client faults added to CLIENT_FAULTS, replacing the
    # earlier ones (a copy of `names` is kept): add to them with
    # `ClientError.extra_faults = ClientError.extra_faults + [name]`.
    # Called at load, before any thread starts.
    # @example
    #   ClientError.extra_faults = ClientError.extra_faults + ["MyLib::MissingInput"]
    # @param names [Array<String>] full class names
    # @return [nil]
    # @api public
    def self.extra_faults=(names)
      full = Array.new(0) { "" }
      i = 0
      while i < names.length
        full << names[i]
        i += 1
      end
      @extra_faults = full
      nil
    end

    # 400 for a client fault (CLIENT_FAULTS or {.extra_faults}), 500 for
    # the app's own exception: an Array lookup, no raise, so a request
    # logger (for its completion line) and every error path (an error page,
    # Server#respond) can each ask and always agree. `to_s`: Class#name is
    # nil for an anonymous class (`Class.new(StandardError)`) under CRuby,
    # and this runs inside error handlers' rescue clauses, where a
    # NoMethodError would escape and close the connection with no response
    # at all. Named status_for, not status: other classes in one program
    # define `status` with other return types (NOTES rules 10, 34).
    # @param e [Exception]
    # @return [Integer] 400 or 500
    def self.status_for(e)
      name = e.class.name.to_s
      return 400 if fault_name_in?(name, CLIENT_FAULTS)
      return 400 if fault_name_in?(name, @extra_faults)

      500
    end

    # Whether name is one of names. A while loop, not a block: no closure,
    # nothing to widen (rules 32, 45).
    # @param name [String]
    # @param names [Array<String>]
    # @return [Boolean]
    # @api private
    def self.fault_name_in?(name, names)
      i = 0
      while i < names.length
        return true if names[i] == name
        i += 1
      end
      false
    end
  end
end
