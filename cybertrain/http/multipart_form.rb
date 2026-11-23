# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/multipart_form and the Cybertrain:: names of
# spinel-http/multipart_form.rb as constant aliases (the same class objects).
require "spinel-http/multipart_form"
require "cybertrain/http/query"
require "cybertrain/http/uploaded_file"

module Cybertrain
  MultipartForm = SpinelHttp::MultipartForm
  MultipartParser = SpinelHttp::MultipartParser
  MultipartMalformed = SpinelHttp::MultipartMalformed
  MultipartTooManyParts = SpinelHttp::MultipartTooManyParts
  MultipartPartTooLarge = SpinelHttp::MultipartPartTooLarge
  MultipartHeaderTooLarge = SpinelHttp::MultipartHeaderTooLarge
  UnsupportedMediaType = SpinelHttp::UnsupportedMediaType
end
