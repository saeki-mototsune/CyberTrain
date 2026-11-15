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
    # `reset_to(status)` (or its own 500 page); the next client-fault class
    # is added to CLIENT_FAULTS below and nowhere else.
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
    # Every subclass must be listed by its full name: the hierarchy is not
    # visible under Spinel (a raised QueryTooMany's class chain there is
    # QueryTooMany, Object, BasicObject; NOTES rules 47, 54), so there is no
    # "any descendant of QueryInvalid" test that means the same on both
    # runtimes. An app's own exception class, even one that subclasses
    # QueryLimitExceeded, is the app's 500 on both; the list is the
    # framework's. script/check-client-faults (run by CI) fails when a
    # QueryInvalid subclass or ParameterMissing is not listed, or an entry
    # names no class.
    CLIENT_FAULTS = ["Cybertrain::QueryInvalid", "Cybertrain::QueryLimitExceeded",
                     "Cybertrain::QueryTooDeep", "Cybertrain::QueryTooMany",
                     "Cybertrain::QueryMalformed",
                     "Cybertrain::BodyUndecodable", "Cybertrain::BodyTooLarge",
                     "Cybertrain::MultipartMalformed", "Cybertrain::MultipartTooManyParts",
                     "Cybertrain::MultipartPartTooLarge", "Cybertrain::MultipartHeaderTooLarge",
                     "Cybertrain::Params::ParameterMissing"]

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
      name = e.class.name.to_s
      i = 0
      while i < CLIENT_FAULTS.length
        return 400 if CLIENT_FAULTS[i] == name
        i += 1
      end
      500
    end
  end
end
