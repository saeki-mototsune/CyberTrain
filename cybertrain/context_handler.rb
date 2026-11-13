require "cybertrain/http/handler"
require "cybertrain/context"
require "cybertrain/middleware"
require "cybertrain/i18n"

module Cybertrain
  # Joins the HTTP layer to the framework: gives each request a Context, runs
  # the middleware stack on it and hands its Response back to the Server.
  class ContextHandler < HttpHandler
    def initialize(app)
      @app = app
    end

    # Each request starts at the default locale: I18n.locale is the
    # thread's, and a keep-alive connection serves its requests on one.
    def call(request)
      I18n.locale = nil
      ctx = Context.new(request)
      @app.call(ctx)
      ctx.response
    end
  end
end
