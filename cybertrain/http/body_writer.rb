# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/body_writer and the Cybertrain:: names of
# spinel-http/body_writer.rb as constant aliases (the same class objects).
require "spinel-http/body_writer"
require "cybertrain/http/log"

module Cybertrain
  BodyWriter = SpinelHttp::BodyWriter
  BlockWriter = SpinelHttp::BlockWriter
  Sink = SpinelHttp::Sink
end
