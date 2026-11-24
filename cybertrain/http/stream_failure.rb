# The HTTP layer is spinel-http's (docs/design.md D91): this file keeps the
# require path cybertrain/http/stream_failure, the Cybertrain:: names of
# spinel-http/stream_failure.rb as constant aliases (the same class objects)
# and Cybertrain.stream_failure as methods that forward to SpinelHttp's.
require "spinel-http/stream_failure"

module Cybertrain
  StreamFailure = SpinelHttp::StreamFailure

  # {SpinelHttp.stream_failure}, under the name cybertrain has always had.
  # @return [StreamFailure]
  # @api private
  def self.stream_failure
    SpinelHttp.stream_failure
  end

  # {SpinelHttp.stream_failure=}: installs what the Server tells a streamed
  # body's failure.
  # @param failure [StreamFailure]
  # @return [nil]
  # @api private
  def self.stream_failure=(failure)
    SpinelHttp.stream_failure = failure
    nil
  end
end
