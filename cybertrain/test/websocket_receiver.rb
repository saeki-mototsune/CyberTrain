# Cybertrain::Test::WebSocketReceiver -- a scripted WebSocket server on
# 127.0.0.1 for testing code that consumes a feed through
# Cybertrain::WebSocket::Client. Each connection plays a script (the
# handshake answer, frames to send, frames to expect, a pause, a close, a
# drop) and every frame the client sent is recorded, unmasked. See
# cybertrain/test/receiver.rb for how every wait is bounded.
#
# Only the frame codec (cybertrain/websocket/frame.rb) comes along, not the
# client or the rest of the framework, so a test program pays for no more
# than it uses.
require "cybertrain/test/receiver"
require "cybertrain/websocket/frame"

module Cybertrain
  module Test
    # One step of a connection's script: a `kind` and its `data`.
    #
    # - "accept": the 101 answer with the right Sec-WebSocket-Accept.
    # - "reply_raw": `data` as the answer, as it is (`{accept}` in it is
    #   replaced by the right Sec-WebSocket-Accept): a wrong Accept, a 200.
    # - "send_with_101": the 101 and a text frame carrying `data`, in one
    #   write.
    # - "send_text" / "send_binary": one frame carrying `data`.
    # - "send_raw": `data`'s bytes, as they are (a protocol violation).
    # - "split_frame": a text frame carrying `data`, its header first and
    #   the payload 1 s later.
    # - "expect": reads one frame from the client and records it.
    # - "echo_until_close": records each frame; sends data frames back,
    #   answers a ping with a pong and a close with a close, then ends.
    # - "silent": does nothing for `data` seconds ("3").
    # - "close": sends a close with the code in `data` ("1001"), then reads
    #   and records the client's answer.
    # - "drop": closes the connection without a close frame.
    # @api public
    class WsStep
      # @return [String]
      # @api public
      attr_reader :step_kind
      # @return [String]
      # @api public
      attr_reader :step_data

      # @param kind [String]
      # @param data [String]
      # @api public
      def initialize(kind, data = "")
        @step_kind = kind.to_s
        @step_data = data.to_s
      end
    end

    # A frame the client sent, as the receiver read it.
    # @api public
    class RecordedFrame
      # @return [Integer] 1 text, 2 binary, 8 close, 9 ping, 10 pong, ...
      # @api public
      attr_reader :rec_opcode
      # @return [Boolean] whether the client masked it (a client must)
      # @api public
      attr_reader :rec_masked
      # @return [String] the payload, unmasked
      # @api public
      attr_reader :rec_data

      def initialize(opcode, masked, data)
        @rec_opcode = opcode
        @rec_masked = masked
        @rec_data = data
      end
    end

    # A receiver for outbound WebSocket connections in a test. Give each
    # connection a script with {#ws_script} (in the order the connections
    # will come; one without a script accepts and echoes until close), start
    # it, point the client at {#url}, then read what the client sent with
    # {#ws_received}.
    # @example
    #   rx = Cybertrain::Test::WebSocketReceiver.new
    #   rx.ws_script([Cybertrain::Test::WsStep.new("accept"),
    #                 Cybertrain::Test::WsStep.new("send_text", "hello"),
    #                 Cybertrain::Test::WsStep.new("expect")])
    #   rx.start
    #   Cybertrain.config.http_allow_private = true
    #   ws = Cybertrain::WebSocket::Client.connect(rx.url("/feed"))
    #   msg = ws.receive(5)             # "hello"
    #   ws.send_text("thanks")
    #   frames = rx.ws_received         # [RecordedFrame "thanks"]
    #   ws.close
    #   rx.stop
    # @api public
    class WebSocketReceiver < Receiver
      # The largest frame payload the receiver reads.
      MAX_FRAME_BYTES = 16_777_216

      # A typed empty Hash (spikes/NOTES.md rule 9).
      def self.no_headers
        h = { "" => "" }
        h.delete("")
        h
      end

      # @param max [Integer] how many connections to accept
      # @param accept_window [Numeric] seconds to wait for each connection
      #   before the receiver gives up and closes its port
      # @param read_timeout [Numeric] seconds of silence that end a read
      # @api public
      def initialize(max: 1, accept_window: 10.0, read_timeout: 5.0)
        super(max, accept_window, read_timeout)
        # Scripts are kept flat: each step with the number of the connection
        # it belongs to.
        @script_steps = Array.new(0) { WsStep.new("", "") }
        @script_owner = Array.new(0) { 0 }
        @scripts_given = 0
        @frames = Array.new(0) { RecordedFrame.new(0, false, "") }
        @heads = Array.new(0) { WebSocketReceiver.no_headers }
        @targets = Array.new(0) { "" }
        @last_frame = RecordedFrame.new(0, false, "")
        @lock = Mutex.new
        @started_count = 0
        @finished_count = 0
      end

      # "ws://127.0.0.1:<port><path>", once started.
      # @param path [String]
      # @return [String]
      # @api public
      def url(path = "/")
        "ws://127.0.0.1:#{@port}#{path}"
      end

      # The script of the next connection that has none yet.
      # @param steps [Array<WsStep>]
      # @return [nil]
      # @api public
      def ws_script(steps)
        @lock.synchronize do
          owner = @scripts_given
          i = 0
          while i < steps.size
            @script_steps << steps[i]
            @script_owner << owner
            i += 1
          end
          @scripts_given = owner + 1
        end
        nil
      end

      # Every frame recorded so far, once the connections that have begun
      # have ended (at least one), waiting at most `wait` seconds for that.
      # @param wait [Numeric]
      # @return [Array<RecordedFrame>]
      # @api public
      def ws_received(wait = 5.0)
        ends_at = Receiver.now + wait.to_f
        while Receiver.now < ends_at
          break if ws_idle?

          sleep(0.01)
        end
        out = Array.new(0) { RecordedFrame.new(0, false, "") }
        @lock.synchronize do
          i = 0
          while i < @frames.size
            out << @frames[i]
            i += 1
          end
        end
        out
      end

      # The handshake request headers of connection `index` (0 the first),
      # names lowercased; empty when it sent none (or not yet, after 5 s).
      # @param index [Integer]
      # @return [Hash{String => String}]
      # @api public
      def ws_request_headers(index)
        return WebSocketReceiver.no_headers unless ws_await_head(index)

        seen = WebSocketReceiver.no_headers
        @lock.synchronize { seen = @heads[index] }
        # A head is never changed once recorded, so the copy is made
        # outside the lock (and outside its block).
        WebSocketReceiver.ws_copy_headers(seen)
      end

      def self.ws_copy_headers(seen)
        out = WebSocketReceiver.no_headers
        seen.each_key { |k| out[k] = seen[k].to_s }
        out
      end

      # The request target (path and query) of connection `index`'s
      # handshake; "" when it sent none.
      # @param index [Integer]
      # @return [String]
      # @api public
      def ws_request_target(index)
        return "" unless ws_await_head(index)

        out = ""
        @lock.synchronize { out = @targets[index].to_s }
        out
      end

      # Connections that have ended.
      def received_count
        n = 0
        @lock.synchronize { n = @finished_count }
        n
      end

      def ws_idle?
        idle = false
        @lock.synchronize { idle = @finished_count >= 1 && @finished_count == @started_count }
        idle
      end

      def ws_await_head(index)
        ends_at = Receiver.now + 5.0
        while true
          n = 0
          @lock.synchronize { n = @heads.size }
          return true if n > index
          return false if Receiver.now >= ends_at

          sleep(0.01)
        end
        false
      end

      # ---- one connection -----------------------------------------------

      def serve_connection(sock)
        index = 0
        @lock.synchronize do
          index = @started_count
          @started_count = index + 1
        end
        begin
          ws_play(sock, index)
        ensure
          @lock.synchronize { @finished_count = @finished_count + 1 }
        end
        nil
      end

      def ws_play(sock, index)
        steps = ws_steps_for(index)
        key = ws_read_request(sock)
        i = 0
        while i < steps.size
          return nil if @stopping
          return nil unless ws_run_step(sock, steps[i], key)

          i += 1
        end
        nil
      end

      # The steps of connection `index`: its script, or accept and echo.
      def ws_steps_for(index)
        out = Array.new(0) { WsStep.new("", "") }
        @lock.synchronize do
          i = 0
          while i < @script_steps.size
            out << @script_steps[i] if @script_owner[i] == index
            i += 1
          end
        end
        if out.empty?
          out << WsStep.new("accept", "")
          out << WsStep.new("echo_until_close", "")
        end
        out
      end

      # Reads and records the handshake request; returns its
      # Sec-WebSocket-Key ("" when there is none). Bytes that are not an
      # HTTP request (a TLS ClientHello) are left unread and recorded as an
      # empty head, so the script can still answer them.
      def ws_read_request(sock)
        headers = WebSocketReceiver.no_headers
        target = ""
        if bytes_ready?(sock, 1) && unread_starts?("G") && marker_ready?(sock, "\r\n\r\n", Receiver::MAX_LINE_BYTES)
          head = cut_to("\r\n\r\n")
          line_end = head.byteindex("\r\n")
          line_end = head.bytesize if line_end.nil?
          parts = head.byteslice(0, line_end).split(" ")
          target = parts[1].to_s if parts.size == 3
          headers = WebSocketReceiver.ws_parse_headers(head, line_end)
        end
        @lock.synchronize do
          @heads << headers
          @targets << target
        end
        headers["sec-websocket-key"].to_s
      end

      # The header lines after the request line: names lowercased, values
      # trimmed, repeated names joined with ", ".
      def self.ws_parse_headers(head, line_end)
        headers = WebSocketReceiver.no_headers
        pos = line_end + 2
        while pos < head.bytesize
          stop = head.byteindex("\r\n", pos)
          stop = head.bytesize if stop.nil?
          line = head.byteslice(pos, stop - pos)
          colon = line.byteindex(":")
          unless colon.nil?
            name = line.byteslice(0, colon).strip.downcase
            value = line.byteslice(colon + 1, line.bytesize - colon - 1).strip
            seen = headers[name]
            if seen.nil?
              headers[name] = value
            else
              joined = String.new
              joined << seen.to_s << ", " << value
              headers[name] = joined
            end
          end
          pos = stop + 2
        end
        headers
      end

      # One step; false ends the connection.
      def ws_run_step(sock, step, key)
        kind = step.step_kind
        data = step.step_data
        case kind
        when "accept"
          sock.write(WebSocketReceiver.ws_answer(key))
        when "reply_raw"
          sock.write(WebSocketReceiver.ws_fill_accept(data, key))
        when "send_with_101"
          answer = WebSocketReceiver.ws_answer(key)
          frame = WebSocket::Frame.encode(WebSocket::Frame::OP_TEXT, data, "")
          out = String.new
          out << answer
          out << frame
          sock.write(out)
        when "send_text"
          sock.write(WebSocket::Frame.encode(WebSocket::Frame::OP_TEXT, data, ""))
        when "send_binary"
          sock.write(WebSocket::Frame.encode(WebSocket::Frame::OP_BINARY, data, ""))
        when "send_raw"
          sock.write(data)
        when "split_frame"
          frame = WebSocket::Frame.encode(WebSocket::Frame::OP_TEXT, data, "")
          cut = frame.bytesize - data.bytesize
          sock.write(frame.byteslice(0, cut))
          ws_pause(1.0)
          sock.write(frame.byteslice(cut, frame.bytesize - cut))
        when "expect"
          return ws_read_frame(sock)
        when "echo_until_close"
          ws_echo(sock)
          return false
        when "silent"
          ws_pause(data.to_f)
        when "close"
          payload = WebSocket::Frame.close_payload(data.to_i, "")
          sock.write(WebSocket::Frame.encode(WebSocket::Frame::OP_CLOSE, payload, ""))
          ws_read_frame(sock)
          return false
        when "drop"
          return false
        end
        true
      end

      # Records frames, answering each, until a close (answered) or the end
      # of the connection.
      def ws_echo(sock)
        while ws_read_frame(sock)
          frame = @last_frame
          op = frame.rec_opcode
          if op == WebSocket::Frame::OP_CLOSE
            sock.write(WebSocket::Frame.encode(WebSocket::Frame::OP_CLOSE, frame.rec_data, ""))
            return nil
          elsif op == WebSocket::Frame::OP_PING
            sock.write(WebSocket::Frame.encode(WebSocket::Frame::OP_PONG, frame.rec_data, ""))
          elsif op == WebSocket::Frame::OP_TEXT || op == WebSocket::Frame::OP_BINARY
            sock.write(WebSocket::Frame.encode(op, frame.rec_data, ""))
          end
        end
        nil
      end

      # Reads one frame and records it (also in @last_frame). False when the
      # connection ends, stays silent or the frame is too large.
      def ws_read_frame(sock)
        return false unless bytes_ready?(sock, 2)

        first = cut_bytes(2)
        b1 = first.getbyte(1)
        len7 = b1 & 0x7f
        extra = len7 == 126 ? 2 : (len7 == 127 ? 8 : 0)
        extra += 4 if (b1 & 0x80) != 0
        head = String.new
        head << first
        if extra > 0
          return false unless bytes_ready?(sock, extra)

          head << cut_bytes(extra)
        end
        header = WebSocket::Frame.parse_header(head)
        length = header.frame_length
        return false if length > MAX_FRAME_BYTES
        return false unless bytes_ready?(sock, length)

        data = WebSocket::Frame.unmask(cut_bytes(length), header.frame_mask_key)
        rec = RecordedFrame.new(header.frame_opcode, header.frame_masked, data)
        @lock.synchronize { @frames << rec }
        @last_frame = rec
        true
      end

      # Sleeps `seconds`, in POLL slices so #stop is noticed.
      def ws_pause(seconds)
        ends_at = Receiver.now + seconds
        while Receiver.now < ends_at
          return nil if @stopping

          sleep(Receiver::POLL)
        end
        nil
      end

      # The 101 answer for `key`.
      def self.ws_answer(key)
        accept = WebSocket::Frame.accept_key(key)
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
          "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
      end

      # `text` with "{accept}" replaced by the Accept value for `key`.
      def self.ws_fill_accept(text, key)
        s = text.to_s # NOTES rule 62
        at = s.byteindex("{accept}")
        return s if at.nil?

        accept = WebSocket::Frame.accept_key(key)
        rest = s.byteslice(at + 8, s.bytesize - at - 8)
        out = String.new
        out << s.byteslice(0, at)
        out << accept
        out << rest
        out
      end
    end
  end
end
