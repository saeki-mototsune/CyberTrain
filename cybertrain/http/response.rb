# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/response and the Cybertrain:: names of
# spinel-http/response.rb as constant aliases (the same class objects).
require "spinel-http/response"
require "cybertrain/http/header_name"
require "cybertrain/http/body_writer"
require "cybertrain/http/log"

module Cybertrain
  Response = SpinelHttp::Response
end
