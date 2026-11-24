# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/cookies and the Cybertrain:: names of
# spinel-http/cookies.rb as constant aliases (the same class objects).
require "spinel-http/cookies"
require "cybertrain/http/query"
require "cybertrain/http/request"

module Cybertrain
  Cookies = SpinelHttp::Cookies
end
