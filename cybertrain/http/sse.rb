# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/sse and the Cybertrain:: names of
# spinel-http/sse.rb as constant aliases (the same class objects).
require "spinel-http/sse"

module Cybertrain
  SSE = SpinelHttp::SSE
end
