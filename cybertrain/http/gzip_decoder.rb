# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/gzip_decoder and the Cybertrain:: names of
# spinel-http/gzip_decoder.rb as constant aliases (the same class objects).
require "spinel-http/gzip_decoder"

module Cybertrain
  GzipDecoder = SpinelHttp::GzipDecoder
end
