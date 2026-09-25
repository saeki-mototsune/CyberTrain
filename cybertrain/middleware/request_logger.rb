require "cybertrain/middleware"
require "cybertrain/logger"

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
      target = request.query_string.empty? ? request.path : "#{request.path}?#{request.query_string}"
      @logger.info("Started #{request.method} \"#{target}\" for #{request.remote_addr}")
      started = Time.now
      begin
        super
      rescue StandardError
        # Still two lines per request: the Server turns the exception into
        # a 500, so log that status (as Rails does) and let it propagate.
        log_completed(500, started)
        raise
      end
      log_completed(ctx.response.status, started)
      nil
    end

    private

    def log_completed(status, started)
      elapsed = ((Time.now - started) * 1000).to_i
      @logger.info("Completed #{status} in #{elapsed}ms")
    end
  end
end
