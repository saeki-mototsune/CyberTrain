# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/header_name and the Cybertrain:: names of
# spinel-http/header_name.rb as constant aliases (the same class objects).
require "spinel-http/header_name"

module Cybertrain
  HeaderName = SpinelHttp::HeaderName
end
