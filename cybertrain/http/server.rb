# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/server and the Cybertrain:: names of
# spinel-http/server.rb as constant aliases (the same class objects).
require "spinel-http/server"
require "cybertrain/http/parser"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/handler"
require "cybertrain/http/body_writer"
require "cybertrain/http/client_error"
require "cybertrain/http/stream_failure"
require "cybertrain/http/log"

module Cybertrain
  Server = SpinelHttp::Server
  PortInUse = SpinelHttp::PortInUse
end
