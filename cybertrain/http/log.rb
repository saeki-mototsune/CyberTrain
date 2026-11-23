# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/log and the Cybertrain:: names of
# spinel-http/log.rb as constant aliases (the same class objects).
require "spinel-http/log"

module Cybertrain
  HttpLog = SpinelHttp::HttpLog
  HttpLogContext = SpinelHttp::HttpLogContext
  HttpLogSwitch = SpinelHttp::HttpLogSwitch
end
