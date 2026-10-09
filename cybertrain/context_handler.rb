require "cybertrain/http/handler"
require "cybertrain/context"
require "cybertrain/middleware"

module Cybertrain
  # Joins the HTTP layer to the framework: gives each request a Context, runs
  # the middleware stack on it and hands its Response back to the Server.
  class ContextHandler < HttpHandler
    def initialize(app)
      @app = app
    end

    def call(request)
      ctx = Context.new(request)
      @app.call(ctx)
      ctx.response
    end
  end
end
