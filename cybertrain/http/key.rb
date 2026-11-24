# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/key and the Cybertrain:: names of
# spinel-http/key.rb as constant aliases (the same class objects).
require "spinel-http/key"

module Cybertrain
  Key = SpinelHttp::Key
end
