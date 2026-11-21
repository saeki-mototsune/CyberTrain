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
    # not decodable, QueryInvalid; a missing required parameter) is its 4xx
    # at info, so a flood of them does not fill the error log; anything else
    # is 500 at error, as `class: message`. Each error path then does
    # `reset_to(status)` (or its own 500 page); the layer's next
    # client-fault class is added to CLIENT_FAULTS below and nowhere else
    # (one defined outside the layer, to extra_faults). `logger` is the
    # Server's {HttpLog} (cybertrain's Logger is one).
    # @param e [Exception]
    # @param logger [HttpLog]
    # @return [Integer]
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
    # place to add a new one (a new QueryInvalid subclass, say).
    # `e.is_a?(QueryInvalid)` cannot do this job: under Spinel is_a? on an
    # exception object answered false for its own superclass (a QueryTooDeep
    # reached every error path as a 500 on the 2026.09.12 build, NOTES rule
    # 47). Matching by class name is what Controller#rescue_with_handler
    # already does for rescue_from.
    #
    # Class#name has no namespace under Spinel (rule 46), so there only the
    # part after the last "::" is compared (status_for_name). That is safe
    # only while every bare name here is unique in the program: the Query
    # classes are QueryXxx, not Query::Invalid / Query::TooMany, so an app's
    # own Billing::Invalid or RateLimiter::TooMany cannot be taken for them.
    # A new entry must be named so as not to collide the same way.
    #
    # Every subclass must be listed by its full name: the hierarchy is not
    # visible under Spinel (a raised QueryTooMany's class chain there is
    # QueryTooMany, Object, BasicObject; NOTES rules 47, 54), so there is no
    # "any descendant of QueryInvalid" test that means the same on both
    # runtimes. An app's own exception class, even one that subclasses
    # QueryLimitExceeded, is the app's 500 on both; the list is the
    # framework's. script/check-client-faults (run by CI) fails when a
    # QueryInvalid subclass or cybertrain's ParameterMissing is in neither
    # this list nor extra_faults, or an entry names no class.
    CLIENT_FAULTS = ["Cybertrain::QueryInvalid", "Cybertrain::QueryLimitExceeded",
                     "Cybertrain::QueryTooDeep", "Cybertrain::QueryTooMany",
                     "Cybertrain::QueryMalformed",
                     "Cybertrain::BodyUndecodable", "Cybertrain::BodyTooLarge",
                     "Cybertrain::MultipartMalformed", "Cybertrain::MultipartTooManyParts",
                     "Cybertrain::MultipartPartTooLarge", "Cybertrain::MultipartHeaderTooLarge"]

    # The client faults the layer does not define, added at load by the
    # code that defines them (cybertrain/context.rb adds
    # "Cybertrain::Params::ParameterMissing"): full class names, matched
    # exactly as CLIENT_FAULTS' are and under the same rule of a bare name
    # unique in the program. Module-level ivars with literal defaults (the
    # Params.max_page shape, spikes/NOTES.md rule 18); the bare names are
    # derived by the setter, as CLIENT_FAULT_BARE_NAMES is from
    # CLIENT_FAULTS, so a lookup never slices.
    @extra_faults = Array.new(0) { "" }
    @extra_fault_bare_names = Array.new(0) { "" }

    # @return [Array<String>] the client faults added to CLIENT_FAULTS
    # @api public
    def self.extra_faults
      @extra_faults
    end

    # Installs the client faults added to CLIENT_FAULTS, replacing the
    # earlier ones: add to them with
    # `ClientError.extra_faults = ClientError.extra_faults + [name]`.
    # Called at load, before any thread starts.
    # @param names [Array<String>] full class names
    # @return [nil]
    # @api public
    def self.extra_faults=(names)
      full = Array.new(0) { "" }
      bare = Array.new(0) { "" }
      i = 0
      while i < names.length
        full << names[i]
        bare << bare_name(names[i])
        i += 1
      end
      @extra_faults = full
      @extra_fault_bare_names = bare
      nil
    end

    # 400 for a client fault, 500 for the app's own exception: an Array
    # lookup, no raise, so RequestLogger (for its Completed line) and the
    # error path outside it (ErrorPages, Dev::ErrorPage, Server#respond) can
    # each ask and always agree. `to_s`: Class#name is nil for an anonymous
    # class (`Class.new(StandardError)`) under CRuby, and this runs inside
    # error handlers' rescue clauses, where a NoMethodError would escape and
    # close the connection with no response at all. Named status_for, not
    # status: DB::Migrator#status and DB::CLI.status share the program and
    # return other types (NOTES rules 10, 34).
    def self.status_for(e)
      status_for_name(e.class.name.to_s, namespaced_names?)
    end

    # Whether Class#name carries its namespace on this runtime, asked of the
    # framework's own class rather than RUBY_ENGINE: "Cybertrain::QueryInvalid"
    # under CRuby, "QueryInvalid" under Spinel (NOTES rule 46). Computed per
    # call, a String#index on a short name, and not held in a constant: a
    # constant initialised from a method call at load time is not vouched for
    # by NOTES under Spinel (only literals are).
    def self.namespaced_names?
      !Cybertrain::QueryInvalid.name.to_s.index("::").nil?
    end

    # The decision on a class name alone; `namespaced` is the runtime's
    # answer from namespaced_names?, a parameter so it can be tested with
    # names from either runtime. Where names are namespaced (CRuby) every
    # framework fault has one, so it must match an entry in full:
    # "Billing::Invalid" and "Other::QueryMalformed" are the app's, and so is
    # a name with no "::", which can only be the app's own top-level class (an
    # `class QueryTooMany < StandardError` of its own is a 500, not a 400;
    # "" for an anonymous class likewise). Where they are not (Spinel, which
    # cannot tell the namespaces apart) the name is matched against the bare
    # names (CLIENT_FAULT_BARE_NAMES), so it is 400 only for a name that is
    # unique to the framework (see CLIENT_FAULTS): a bare "Invalid" or
    # "TooMany" is a 500. A while loop, not a block: no closure, nothing to
    # widen (rules 32, 45).
    def self.status_for_name(name, namespaced)
      listed = namespaced ? CLIENT_FAULTS : CLIENT_FAULT_BARE_NAMES
      return 400 if fault_name_in?(name, listed)

      extra = namespaced ? @extra_faults : @extra_fault_bare_names
      return 400 if fault_name_in?(name, extra)

      500
    end

    # Whether name is one of names. A while loop, not a block (rules 32, 45).
    def self.fault_name_in?(name, names)
      i = 0
      while i < names.length
        return true if names[i] == name
        i += 1
      end
      false
    end

    # The part after the last "::": Class#name carries no namespace under
    # Spinel ("QueryTooDeep") but does under CRuby ("Cybertrain::QueryTooDeep")
    # (NOTES rule 46). Only ever given a String.
    def self.bare_name(name)
      i = name.rindex("::")
      return name if i.nil?
      name[(i + 2)..-1]
    end

    # DERIVED from CLIENT_FAULTS, never edited: the bare name of each entry,
    # so a lookup under Spinel compares against constants instead of slicing
    # six strings per call (and per failing request, which asks twice). Built
    # here, after bare_name is defined, with a plain while loop in the module
    # body (no block) and an element-typed empty Array (rule 9). A module-body
    # statement calling a module method is not covered by NOTES: verify it on
    # the Spinel build.
    CLIENT_FAULT_BARE_NAMES = Array.new(0) { "" }
    bare_i = 0
    while bare_i < CLIENT_FAULTS.length
      CLIENT_FAULT_BARE_NAMES << bare_name(CLIENT_FAULTS[bare_i])
      bare_i += 1
    end
  end
end
