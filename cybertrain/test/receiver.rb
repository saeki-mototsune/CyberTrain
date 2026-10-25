# Cybertrain::Test::Receiver -- what the in-process receivers for outbound
# calls share: a listener on 127.0.0.1, one thread that accepts a bounded
# number of connections one after the other, and bounded reads.
#
# Under Spinel a blocking socket call holds an OS worker, so nothing here
# blocks (spikes/NOTES.md rules 5, 20-22):
#
# - the accept is a wait_readable in POLL slices and an accept only once a
#   connection is queued, so the thread notices #stop within POLL seconds
#   and gives up after `accept_window` seconds without a connection: a
#   client that never connects cannot leave a thread behind that takes the
#   next test's connection;
# - every read is wait_readable (in POLL slices, at most `read_timeout`
#   seconds of silence) and then readpartial, framed with byte offsets
#   (byteindex / byteslice, rule 27), never IO#gets;
# - the thread is started through a method whose parameter the block
#   captures (rule 21), after SPINEL_WORKERS is set (rule 22), as
#   Cybertrain::Server does.
#
# The thread closes the listener when it ends; #stop asks it to end and
# joins it, bounded. Nothing here requires openssl or the rest of the
# framework (only Ruby's socket library), so a test program pays for no
# more than it uses.
require "socket"

module Cybertrain
  module Test
    # The base of {HttpReceiver} and {SmtpReceiver}.
    # @api public
    class Receiver
      # Seconds each wait lasts before the thread looks at #stop again.
      POLL = 0.05

      # The largest line or head a receiver buffers before giving up on the
      # connection.
      MAX_LINE_BYTES = 65_536

      # @return [Integer] the bound port, 0 before {#start}
      # @api public
      attr_reader :port

      def initialize(max, accept_window, read_timeout)
        @max = max.to_i
        @accept_window = accept_window.to_f
        @read_timeout = read_timeout.to_f
        @port = 0
        @thread = nil
        @stopping = false
        @serving = false
        # The connection's bytes: a buffer and a read offset into it, as
        # Net::Reader keeps them. String.new, not +"": binary under CRuby,
        # so byteindex never meets a character boundary check (rule 52).
        @inbuf = String.new
        @inpos = 0
        raise ArgumentError, "max must be at least 1" if @max < 1
        raise ArgumentError, "accept_window must be positive" unless @accept_window > 0.0
        raise ArgumentError, "read_timeout must be positive" unless @read_timeout > 0.0
      end

      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Binds 127.0.0.1:`port` (0 for any free port) and starts the thread
      # that accepts the connections. Returns once listening.
      # @param port [Integer]
      # @return [Integer] the bound port
      # @raise [ArgumentError] when already started
      # @api public
      def start(port: 0)
        raise ArgumentError, "the receiver is already started" if @serving

        # spikes/NOTES.md rule 22: before the first Thread.new.
        ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
        listener = TCPServer.new("127.0.0.1", port.to_i)
        @port = listener.addr[1].to_i
        @stopping = false
        @serving = true
        @thread = rx_spawn(listener)
        @port
      end

      # Stops accepting, ends the connection in progress at its next wait,
      # and joins the thread (at most `read_timeout` + 1 seconds). What has
      # arrived stays readable. Safe to call twice, or before {#start}.
      # @return [nil]
      # @api public
      def stop
        @stopping = true
        thread = @thread
        thread.join(@read_timeout + 1.0) unless thread.nil?
        @thread = nil
        nil
      end

      # Whether the thread is still accepting or serving.
      # @return [Boolean]
      # @api public
      def serving?
        @serving
      end

      # The hook a receiver implements: one accepted connection, read and
      # answered. The socket is closed by the caller.
      def serve_connection(sock)
        nil
      end

      # How many results (requests, messages) have been recorded.
      def received_count
        0
      end

      # NOTES rule 21: the listener reaches the thread through this method's
      # parameter, never as a Thread.new argument.
      def rx_spawn(listener)
        Thread.new { rx_accept_loop(listener) }
      end

      # Accepts up to `max` connections, one at a time; each may take
      # `accept_window` seconds to arrive. Closes the listener when done.
      def rx_accept_loop(listener)
        served = 0
        waiting_since = Receiver.now
        while served < @max && !@stopping
          break if Receiver.now - waiting_since >= @accept_window

          unless listener.wait_readable(POLL).nil?
            accept_and_serve(listener)
            served += 1
            waiting_since = Receiver.now
          end
        end
        nil
      rescue IOError, SystemCallError
        nil
      ensure
        listener.close unless listener.closed?
        @serving = false
      end

      # The accepted socket stays a typed local of this method (a nullable
      # local holding it would box it, and wait_readable on a boxed socket
      # does not dispatch: rule 21's failure).
      def accept_and_serve(listener)
        sock = listener.accept
        serve_and_close(sock)
        nil
      end

      def serve_and_close(sock)
        @inbuf = String.new
        @inpos = 0
        serve_connection(sock)
        nil
      rescue EOFError, IOError, SystemCallError
        nil
      ensure
        sock.close unless sock.closed?
      end

      # Waits until `count` results are recorded: true, or false once
      # `wait` seconds have passed or the thread has ended without them.
      def await_count(count, wait)
        ends_at = Receiver.now + wait.to_f
        while received_count < count
          return false if Receiver.now >= ends_at
          return received_count >= count unless @serving

          sleep(0.01)
        end
        true
      end

      # ---- bounded reads -------------------------------------------------

      # Bytes rx_buffered and not yet consumed.
      def rx_buffered
        @inbuf.bytesize - @inpos
      end

      # Waits (in POLL slices, at most read_timeout seconds of silence) and
      # reads what arrived. False when the peer is silent, gone, or the
      # receiver is stopping.
      def rx_fill(sock)
        started = Receiver.now
        while true
          return false if @stopping
          return false if Receiver.now - started >= @read_timeout

          break unless sock.wait_readable(POLL).nil?
        end
        chunk = sock.readpartial(16_384)
        if @inpos > 0 && @inpos * 2 >= @inbuf.bytesize
          rest = @inbuf.byteslice(@inpos, @inbuf.bytesize - @inpos)
          @inbuf = String.new
          @inbuf << rest
          @inpos = 0
        end
        @inbuf << chunk
        true
      rescue EOFError
        false
      end

      # True once `marker` is rx_buffered (reading as needed); false when the
      # connection ends first or more than `limit` bytes come without it.
      def marker_ready?(sock, marker, limit)
        while @inbuf.byteindex(marker, @inpos).nil?
          return false if rx_buffered > limit
          return false unless rx_fill(sock)
        end
        true
      end

      # True once `count` bytes are rx_buffered.
      def bytes_ready?(sock, count)
        while rx_buffered < count
          return false unless rx_fill(sock)
        end
        true
      end

      # The bytes before the next `marker`, consumed with it. Call after
      # #marker_ready?.
      def cut_to(marker)
        at = @inbuf.byteindex(marker, @inpos)
        out = @inbuf.byteslice(@inpos, at - @inpos)
        @inpos = at + marker.bytesize
        out
      end

      # The next `count` bytes. Call after #bytes_ready?.
      def cut_bytes(count)
        out = @inbuf.byteslice(@inpos, count)
        @inpos += count
        out
      end

      # Whether the unread bytes start with `prefix`.
      def unread_starts?(prefix)
        return false if rx_buffered < prefix.bytesize

        @inbuf.byteslice(@inpos, prefix.bytesize) == prefix
      end
    end
  end
end
