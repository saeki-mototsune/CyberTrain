# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/request and the Cybertrain:: names of
# spinel-http/request.rb as constant aliases (the same class objects).
# It also loads cybertrain/request_format, so that this require path still
# gives Request's format family (#format, #format_extension,
# Request.format_for_extension, Request.mime_type), as it did before the
# layer moved. That file requires this one back: whichever loads first,
# the alias below is defined before request_format reopens the class
# through it.
require "spinel-http/request"
require "cybertrain/http/query"
require "cybertrain/http/header_name"
require "cybertrain/http/parser"
require "cybertrain/http/multipart_form"
require "cybertrain/http/multipart"
require "cybertrain/http/ip_address"
require "cybertrain/http/log"

module Cybertrain
  Request = SpinelHttp::Request
  BodyUndecodable = SpinelHttp::BodyUndecodable
  BodyTooLarge = SpinelHttp::BodyTooLarge
end

require "cybertrain/request_format"
