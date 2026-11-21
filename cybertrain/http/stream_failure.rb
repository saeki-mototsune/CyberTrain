module Cybertrain
  # What the Server tells when a streamed or upgraded body's writer raised
  # (docs/design.md D88): {Server} calls {#stream_failed} on
  # {Cybertrain.stream_failure} after it logged its `stream error:` line,
  # with the request's log context current ({Response#body_log_context}),
  # once per failed stream. A client that went away (EOFError, IOError,
  # Errno::ECONNRESET, Errno::EPIPE: what the server treats as a closed
  # peer) is not a failure and is not told.
  #
  # The HTTP layer loads alone (script/check-http-layer), so it names no
  # reporter: this base does nothing, and cybertrain/error_reporter
  # installs the subclass that reports (ErrorReporter::StreamReport). An
  # object with a method, not a stored block (spikes/NOTES.md rules 88 and
  # 103).
  # @api private
  class StreamFailure
    # One writer's failure. The base does nothing. Must not raise.
    # @param error [Exception]
    # @return [nil]
    # @api private
    def stream_failed(error)
      nil
    end
  end

  # A module-level instance variable, as Cybertrain.logger's
  # (spikes/NOTES.md rule 18).
  @stream_failure = StreamFailure.new

  # Where the Server tells a streamed body's failure: the base, which does
  # nothing, until cybertrain/error_reporter installs its reporting one.
  # @return [StreamFailure]
  # @api private
  def self.stream_failure
    @stream_failure
  end

  # Installs what the Server tells a streamed body's failure.
  # @param failure [StreamFailure]
  # @return [nil]
  # @api private
  def self.stream_failure=(failure)
    @stream_failure = failure
    nil
  end
end
