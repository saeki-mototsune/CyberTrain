# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/multipart and the Cybertrain:: names of
# spinel-http/multipart.rb as constant aliases (the same class objects).
require "spinel-http/multipart"
require "cybertrain/http/query"
require "cybertrain/http/uploaded_file"
require "cybertrain/http/multipart_form"

module Cybertrain
  Multipart = SpinelHttp::Multipart
  MultipartFormParser = SpinelHttp::MultipartFormParser
end
