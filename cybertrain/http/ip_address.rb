# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/ip_address and the Cybertrain:: names of
# spinel-http/ip_address.rb as constant aliases (the same class objects).
require "spinel-http/ip_address"

module Cybertrain
  IpAddress = SpinelHttp::IpAddress
end
