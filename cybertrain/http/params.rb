# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/params and the Cybertrain:: names of
# spinel-http/params.rb as constant aliases (the same class objects).
require "spinel-http/params"
require "cybertrain/http/uploaded_file"
require "cybertrain/http/key"

module Cybertrain
  Params = SpinelHttp::Params
end
