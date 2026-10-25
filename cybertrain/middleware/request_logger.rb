require "json"
require "cybertrain/middleware"
require "cybertrain/logger"
require "cybertrain/http/client_error"

module Cybertrain
  # Rails-style request log lines around the rest of the stack:
  #   Started GET "/posts?page=2" for 127.0.0.1
  #   Completed 200 in 3ms
  class RequestLogger < Middleware
    def initialize(app, logger = Cybertrain.logger)
      super(app)
      @logger = logger
    end

    def call(ctx)
      request = ctx.request
      target = log_field(request.path)
      target = "#{target}?#{log_field(request.query_string)}" unless request.query_string.empty?
      @logger.info("Started #{log_field(request.method)} \"#{target}\" for #{request.remote_addr}")
      started = Time.now
      begin
        super
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        # Still two lines per request: the error path outside this
        # middleware (ErrorPages, Dev::ErrorPage or the Server) answers the
        # status ClientError.status_for gives the exception -- 400 for a client
        # fault, 500 otherwise (a name lookup, nothing is re-raised, so both
        # sites always agree) -- so log that status (as Rails does) and let
        # it propagate. JSON::ParserError named too (NOTES rule 33), or an
        # action's bad JSON.parse would leave the request without its
        # Completed line under Spinel.
        log_completed(ClientError.status_for(e), started)
        raise e
      end
      log_completed(ctx.response.status, started)
      nil
    end

    private

    # Binary inspect escapes every control byte, including terminal escapes,
    # and quotes/backslashes. Strip only its surrounding quotes so normal
    # request log lines keep their existing format.
    def log_field(value)
      quoted = value.b.inspect
      quoted[1, quoted.size - 2]
    end

    def log_completed(status, started)
      elapsed = ((Time.now - started) * 1000).to_i
      @logger.info("Completed #{status} in #{elapsed}ms")
    end
  end
end
