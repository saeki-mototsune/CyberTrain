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
    # then does `reset_to(status)` (or its own 500 page), so the next
    # client-fault class changes this file only.
    def self.classify(e, logger)
      status = self.status(e)
      if status >= 500
        logger.error("#{e.class.name}: #{e.message}")
      else
        logger.info("rejected request (#{status} #{Response.status_text(status)}): #{e.message}")
      end
      status
    end

    # 400 for a client fault, 500 for the app's own exception. The class
    # test is a re-raise into rescue clauses rather than
    # `e.is_a?(Query::Invalid)`: under Spinel is_a? on an exception
    # object answered false for its own superclass (a TooDeep reached every
    # error path as a 500 on the local 2026.09.12 build), while
    # rescue-by-class is what every rescue in the framework already relies
    # on (NOTES rule 47).
    def self.status(e)
      begin
        raise e
      rescue Query::Invalid
        400
      rescue JSON::ParserError, StandardError
        500
      end
    end
  end
end
