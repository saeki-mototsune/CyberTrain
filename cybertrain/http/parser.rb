# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/parser and the Cybertrain:: names of
# spinel-http/parser.rb as constant aliases (the same class objects).
require "spinel-http/parser"

module Cybertrain
  HttpParser = SpinelHttp::HttpParser
  RequestHead = SpinelHttp::RequestHead
end
