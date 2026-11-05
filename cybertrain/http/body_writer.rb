require "socket"

module Cybertrain
  # What a streaming response carries instead of a body (docs/design.md D35):
  # the Server sends the head, then calls #write_body on the connection's
  # thread with a {Sink} on the socket, then ends the response and closes
  # the connection. A subclass overrides #write_body; the base is typed like
  # Middleware so Spinel resolves the call statically (spikes/NOTES.md
  # rule 3). Set one with {Response#body_writer=}, or in an action with
  # {Controller#stream}.
  # @api public
  class BodyWriter
    # Writes the body to `sink` and returns when it is done (or the client
    # went away: {Sink#closed?}). An exception it raises is logged and ends
    # the connection.
    # @param sink [Sink]
    # @return [nil]
    # @api public
    def write_body(sink)
      nil
    end
  end

  # A BodyWriter that runs a block: what {Controller#stream} builds. The
  # block is stored and called with `.call` from this plain method, never
  # yielded to (spikes/NOTES.md rules 2, 31, 69).
  class BlockWriter < BodyWriter
    def initialize(writer_block)
      @writer_block = writer_block
    end

    def write_body(sink)
      @writer_block.call(sink)
      nil
    end
  end

  # The socket of a streaming response, as a {BodyWriter} sees it. #write
  # sends one chunk (with the `Transfer-Encoding: chunked` framing when the
  # response is chunked, HTTP/1.1; as it is for HTTP/1.0 and for an
  # upgraded connection); it never raises: once a write fails (EPIPE,
  # ECONNRESET) or a read sees EOF, #closed? is true and later writes do
  # nothing, so a writer's loop only has to look at #closed?.
  # @example an SSE loop
  #   until sink.closed?
  #     sink.write(Cybertrain::SSE.event(next_json))
  #     break if sink.wait_closed(1)
  #   end
  # @api public
  class Sink
    def initialize(socket, chunked)
      @socket = socket
      @chunked = chunked
      @closed = false
      # A write failed: nothing more can be sent, not even the terminator.
      @broken = false
    end

    # The connection's socket, for a writer that speaks its own protocol on
    # it (the WebSocket session after a 101). Every read on it must be
    # preceded by `wait_readable` (spikes/NOTES.md rule 20).
    # @return [TCPSocket]
    # @api public
    def socket
      @socket
    end

    # Sends one chunk; "" sends nothing (an empty chunk would end a chunked
    # body). Returns nil, also when the client is gone.
    # @param bytes [String]
    # @return [nil]
    # @api public
    def write(bytes)
      return nil if @closed

      # A new local (spikes/NOTES.md rule 62); appended with << so bytes
      # after a NUL survive (rule 60).
      data = bytes.to_s
      n = data.bytesize
      return nil if n == 0

      frame = +""
      if @chunked
        frame << n.to_s(16)
        frame << "\r\n"
        frame << data
        frame << "\r\n"
      else
        frame << data
      end
      sink_send(frame)
    end

    # True once the client went away: a write failed or a read saw EOF
    # (also when the server shut the read side because it is stopping).
    # @return [Boolean]
    # @api public
    def closed?
      @closed
    end

    # Waits up to `seconds` for the client to close its end; true if it did
    # (or already had). Anything else the client sends is read and dropped
    # (an SSE client sends nothing). wait_readable before the read
    # (spikes/NOTES.md rule 20); 0 only looks.
    # @param seconds [Numeric]
    # @return [Boolean]
    # @api public
    def wait_closed(seconds)
      return true if @closed

      sock = @socket
      return false if sock.wait_readable(seconds).nil?

      sink_drain(sock)
      @closed
    end

    # The end of the body: the terminating chunk of a chunked response.
    # The Server calls it after #write_body returned. Also after a read saw
    # EOF (the client half-closed, or the server shut the read side to
    # stop): the write side may still be open.
    def sink_finish
      return nil if @broken || !@chunked

      @socket.write("0\r\n\r\n")
      nil
    rescue IOError, SystemCallError
      @broken = true
      nil
    end

    # Marks the client gone without touching the socket.
    def sink_close!
      @closed = true
      nil
    end

    private

    def sink_send(frame)
      @socket.write(frame)
      nil
    rescue IOError, SystemCallError
      @closed = true
      @broken = true
      nil
    end

    def sink_drain(sock)
      sock.readpartial(4096)
      nil
    rescue EOFError, IOError, SystemCallError
      @closed = true
      nil
    end
  end
end
