# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/handler and the Cybertrain:: names of
# spinel-http/handler.rb as constant aliases (the same class objects).
require "spinel-http/handler"
require "cybertrain/http/request"
require "cybertrain/http/response"

module Cybertrain
  HttpHandler = SpinelHttp::HttpHandler
end
