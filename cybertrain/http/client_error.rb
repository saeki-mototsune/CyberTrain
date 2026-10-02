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
    # The 4xx status for a client fault, or 0 when the exception is the
    # app's (a 500). 0 rather than nil: an Integer-or-nil return would not
    # type under Spinel. The class test is a re-raise into rescue clauses
    # rather than `e.is_a?(Query::LimitExceeded)`: under Spinel is_a? on an
    # exception object answered false for its own superclass (a TooDeep
    # reached every error path as a 500 on the local 2026.09.12 build),
    # while rescue-by-class is what every rescue in the framework already
    # relies on (NOTES rule 47).
    def self.status(e)
      begin
        raise e
      rescue Query::LimitExceeded
        400
      rescue JSON::ParserError, StandardError
        0
      end
    end

    # The info-level log line for a client fault (a flood of them must not
    # fill the error log), worded from the status so it stays right for any
    # 4xx `status` returns: "rejected request (400 Bad Request): <message>".
    def self.log_line(e, status)
      "rejected request (#{status} #{Response.status_text(status)}): #{e.message}"
    end
  end
end
