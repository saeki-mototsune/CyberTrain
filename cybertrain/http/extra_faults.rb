# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/extra_faults and the Cybertrain:: names of
# spinel-http/extra_faults.rb as constant aliases (the same class objects).
require "spinel-http/extra_faults"

module Cybertrain
  ClientError = SpinelHttp::ClientError
end
