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
        logger.error("#{e.class.name.to_s}: #{e.message}")
      else
        logger.info("rejected request (#{status} #{Response.status_text(status)}): #{e.message}")
      end
      status
    end

    # Full class names of the client-fault exceptions: THE place to add a new
    # one (a new Query::Invalid subclass is listed here and in
    # BARE_CLIENT_FAULTS, which test/client_error.rb keeps in step).
    # `e.is_a?(Query::Invalid)` cannot do this job: under Spinel is_a? on an
    # exception object answered false for its own superclass (a TooDeep
    # reached every error path as a 500 on the 2026.09.12 build, NOTES rule
    # 47). Matching by class name is what Controller#rescue_with_handler
    # already does for rescue_from.
    CLIENT_FAULTS = ["Cybertrain::Query::Invalid", "Cybertrain::Query::LimitExceeded",
                     "Cybertrain::Query::TooDeep", "Cybertrain::Query::TooMany",
                     "Cybertrain::Query::Malformed"]

    # The same list without the namespace, for a runtime whose Class#name has
    # none (Spinel, NOTES rule 46). A literal, not CLIENT_FAULTS.map, so no
    # method call runs at load time.
    BARE_CLIENT_FAULTS = ["Invalid", "LimitExceeded", "TooDeep", "TooMany", "Malformed"]

    # 400 for a client fault, 500 for the app's own exception: an Array
    # lookup, no raise, so RequestLogger (for its Completed line) and the
    # error path outside it (ErrorPages, Dev::ErrorPage, Server#respond) can
    # each ask and always agree. `to_s`: Class#name is nil for an anonymous
    # class (`Class.new(StandardError)`) under CRuby, and this runs inside
    # error handlers' rescue clauses, where a NoMethodError would escape and
    # close the connection with no response at all.
    def self.status(e)
      status_for_name(e.class.name.to_s)
    end

    # The decision on a class name alone, so it can be tested with names from
    # either runtime. A namespaced name (CRuby) must match in full: a bare
    # "Invalid" or "TooMany" is also what an app or library raises
    # (Billing::Invalid, RateLimiter::TooMany) and that is a 500, not the
    # client's fault. A name with no "::" (Spinel, which cannot tell the two
    # apart, or a top-level class; "" for an anonymous one) is matched
    # against the bare names.
    def self.status_for_name(name)
      if name.index("::").nil?
        BARE_CLIENT_FAULTS.include?(name) ? 400 : 500
      else
        CLIENT_FAULTS.include?(name) ? 400 : 500
      end
    end

    # The part after the last "::": Class#name carries no namespace under
    # Spinel ("TooDeep") but does under CRuby ("Cybertrain::Query::TooDeep")
    # (NOTES rule 46). Only ever given a String (status passes `name.to_s`).
    def self.bare_name(name)
      i = name.rindex("::")
      return name if i.nil?
      name[(i + 2)..-1]
    end
  end
end
