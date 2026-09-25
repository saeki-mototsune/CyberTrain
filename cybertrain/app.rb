require "cybertrain/middleware"
require "cybertrain/router"
require "cybertrain/logger"
require "cybertrain/middleware/static"
require "cybertrain/middleware/request_logger"
require "cybertrain/middleware/method_override"

module Cybertrain
  # The application as the Server sees it: the default middleware stack
  # (RequestLogger -> Static -> MethodOverride) in front of the Router.
  class App < Middleware
    attr_reader :router

    def initialize(router, public_root: "public", logging: true, logger: Cybertrain.logger)
      @router = router
      stack = Static.new(MethodOverride.new(router), public_root)
      if logging
        super(RequestLogger.new(stack, logger))
      else
        super(stack)
      end
    end

    def call(ctx)
      @app.call(ctx) unless @app.nil?
      nil
    end
  end
end
