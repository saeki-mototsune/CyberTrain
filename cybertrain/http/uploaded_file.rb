# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/uploaded_file and the Cybertrain:: names of
# spinel-http/uploaded_file.rb as constant aliases (the same class objects).
require "spinel-http/uploaded_file"

module Cybertrain
  UploadedFile = SpinelHttp::UploadedFile
end
