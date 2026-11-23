# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/gzip_ffi and the Cybertrain:: names of
# spinel-http/gzip.rb as constant aliases (the same class objects).
require "spinel-http/gzip"
require "cybertrain/http/request"
require "cybertrain/http/gzip_decoder"

module Cybertrain
  GzipFFI = SpinelHttp::GzipFFI
  GzipFFIDecoder = SpinelHttp::GzipFFIDecoder
end
