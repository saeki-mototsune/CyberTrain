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
    # not decodable, Query::Invalid) is
    # its 4xx at info, so a flood of them does not fill the error log;
    # anything else is 500 at error, as `class: message`. Each error path
    # then does `reset_to(status)` (or its own 500 page); the next
    # client-fault class is added to CLIENT_FAULTS below and nowhere else.
    def self.classify(e, logger)
      status = self.status(e)
      if status >= 500
        logger.error("#{e.class.name}: #{e.message}")
      else
        logger.info("rejected request (#{status} #{Response.status_text(status)}): #{e.message}")
      end
      status
    end

    # Bare class names of the client-fault exceptions: THE place to add a new
    # one (a new Query::Invalid subclass is listed here and nowhere else).
    # `e.is_a?(Query::Invalid)` cannot do this job: under Spinel is_a? on an
    # exception object answered false for its own superclass (a TooDeep
    # reached every error path as a 500 on the 2026.09.12 build, NOTES rule
    # 47). Matching by class name is what Controller#rescue_with_handler
    # already does for rescue_from.
    CLIENT_FAULTS = ["Invalid", "LimitExceeded", "TooDeep", "TooMany", "Malformed"]

    # 400 for a client fault, 500 for the app's own exception: an Array
    # lookup, no raise, so RequestLogger (for its Completed line) and the
    # error path outside it (ErrorPages, Dev::ErrorPage, Server#respond) can
    # each ask and always agree.
    def self.status(e)
      CLIENT_FAULTS.include?(bare_name(e.class.name)) ? 400 : 500
    end

    # The part after the last "::": Class#name carries no namespace under
    # Spinel ("TooDeep") but does under CRuby ("Cybertrain::Query::TooDeep")
    # (NOTES rule 46).
    def self.bare_name(name)
      i = name.rindex("::")
      return name if i.nil?
      name[(i + 2)..-1]
    end
  end
end
