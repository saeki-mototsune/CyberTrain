require "cybertrain/http/request"
require "cybertrain/http/response"

module Cybertrain
  # What the Server calls for each request: the only thing the HTTP layer
  # knows about the application on top of it. A subclass overrides
  # #call(request) and returns the Response to write; an exception it lets
  # escape becomes a 4xx/500 (see Server#respond). Typed as a base class so
  # Spinel can resolve #call statically, like Middleware.
  class HttpHandler
    def call(request)
      Response.new
    end
  end
end
