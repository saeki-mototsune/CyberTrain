# Cybertrain::WebSocket::Client -- a synchronous RFC 6455 client on the
# bounded socket layer (cybertrain/net/socket.rb): connect, send, receive
# with a wait, close. For consuming a data feed; long-lived subscriptions
# with reconnects are built on it.
#
# Every wait is bounded. Connecting, each TLS step and the handshake use a
# Net::Timer of `timeout` per wait and `timeout * 3` overall; each write
# `timeout`; `receive(wait)` at most `wait` seconds, after which it answers
# nil. A frame that is only partly there when the wait ends stays in the
# Reader's buffer (nothing is consumed until the whole frame is), so the next
# receive goes on from where this one stopped.
#
# The URL parsing, the non-public address policy and the dialling are
# HttpClient's (parse_url_for, dial), so ws:// behaves like http:// there:
# private destinations are refused unless allowed, every resolved address is
# tried, and errors name the host and port, never the path or the query.
# wss:// needs `require "cybertrain/net/tls"` as well.
#
# Not supported: extensions (permessage-deflate), subprotocols, sending
# fragmented messages. A server that answers with an extension or a
# subprotocol fails the handshake.
require "securerandom"
require "base64"
require "cybertrain/version"
require "cybertrain/config"
require "cybertrain/net/socket"
require "cybertrain/http_client"
require "cybertrain/websocket/frame"

module Cybertrain
  module WebSocket
    # A WebSocket connection to a server, used from one thread.
    # @example
    #   require "cybertrain/websocket/client"
    #   require "cybertrain/net/tls"
    #
    #   ws = Cybertrain::WebSocket::Client.connect("wss://feed.example.com/v1/trades")
    #   ws.send_text(JSON.generate({ "subscribe" => "BTC-USD" }))
    #   while (msg = ws.receive(10))
    #     handle(msg.ws_data) if msg.ws_opcode == :text
    #   end
    #   ws.close
    # @api public
    class Client
      # Seeded with a String pair, then emptied (spikes/NOTES.md rule 9): the
      # default for `headers:`.
      NO_HEADERS = { "" => "" }
      NO_HEADERS.delete("")

      # Connects and performs the opening handshake.
      # @param url [String] ws:// or wss://
      # @param headers [Hash{String => String}] extra handshake headers (not
      #   Host, Upgrade, Connection, Sec-WebSocket-*, Content-Length, ...)
      # @param timeout [Numeric] seconds for each wait while connecting and
      #   for each write; the handshake as a whole gets three times that
      # @param max_message [Integer] the largest message accepted, in bytes
      # @param allow_private [Boolean] allow loopback, private and other
      #   non-public destinations. Default Config#http_allow_private.
      # @return [Client]
      # @raise [Error] a subclass; ArgumentError for a URL or header the
      #   client refuses
      # @api public
      def self.connect(url, headers: NO_HEADERS, timeout: 5, max_message: 1_048_576,
                       allow_private: Cybertrain.config.http_allow_private)
        target = HttpClient.parse_url_for(url, "ws://", "wss://")
        seconds = timeout.to_f
        limit = max_message.to_i
        raise ArgumentError, "timeout must be positive" unless seconds > 0.0
        raise ArgumentError, "max_message must be at least 1" if limit < 1

        key = Base64.strict_encode64(SecureRandom.random_bytes(16))
        head = Client.handshake_head(target, key, headers)
        Client.ws_open(target, key, head, seconds, limit, allow_private == true)
      end

      # The opening handshake, its Net errors translated. The rescue ladder
      # is in a method that takes no block (NOTES rules 32, 45) and tells the
      # classes apart by clause (rule 47); full names in the clauses (rule 70).
      def self.ws_open(target, key, head, timeout, max_message, allow_private)
        Client.ws_handshake(target, key, head, timeout, max_message, allow_private)
      rescue Cybertrain::Net::TimeoutError => e
        raise Cybertrain::WebSocket::TimeoutError, e.message
      rescue Cybertrain::Net::BlockedError => e
        raise Cybertrain::WebSocket::BlockedAddressError, e.message
      rescue Cybertrain::Net::TlsError => e
        raise Cybertrain::WebSocket::TLSError, e.message
      rescue Cybertrain::Net::ConnectError => e
        raise Cybertrain::WebSocket::RefusedError, e.message
      rescue Cybertrain::Net::LimitError => e
        raise Cybertrain::WebSocket::HandshakeError, e.message
      rescue Cybertrain::Net::ProtocolError => e
        raise Cybertrain::WebSocket::HandshakeError, e.message
      end

      def self.ws_handshake(target, key, head, timeout, max_message, allow_private)
        label = target.target_label
        timer = Net::Timer.new(label, timeout, timeout * 3)
        stream = HttpClient.dial(target, timer, allow_private)
        reader = Net::Reader.new(stream, timer)
        done = false
        begin
          stream.stream_write(head, timer)
          Client.check_answer(reader, label, key)
          done = true
        ensure
          stream.stream_close unless done
        end
        Client.new(stream, reader, label, timeout, max_message)
      end

      # The GET that asks for the upgrade. Raises ArgumentError for a header
      # the client sets itself or one HttpClient.check_header refuses; the
      # messages name the header, never its value.
      def self.handshake_head(target, key, headers)
        head = String.new
        head << "GET " << target.request_target << " HTTP/1.1\r\n"
        head << "Host: " << target.host_header << "\r\n"
        user_agent = false
        headers.each_key do |name_key|
          name = name_key.to_s
          value = headers[name_key].to_s
          lower = name.downcase
          raise ArgumentError, "header #{name} is set by the client itself" if lower.start_with?("sec-websocket-")

          HttpClient.check_header(name, value)
          user_agent = true if lower == "user-agent"
          head << name << ": " << value << "\r\n"
        end
        head << "User-Agent: cybertrain/" << VERSION << "\r\n" unless user_agent
        head << "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        head << "Sec-WebSocket-Key: " << key << "\r\n"
        head << "Sec-WebSocket-Version: 13\r\n\r\n"
        head
      end

      # Reads the answer and raises HandshakeError unless it is a 101 that
      # accepts this key with no extension and no subprotocol. Bytes after
      # the blank line stay in the reader: they are the first frames.
      def self.check_answer(reader, label, key)
        status = HttpClient.status_code(reader.read_line(HttpClient::MAX_LINE_BYTES), label)
        headers = HttpClient.read_headers(reader, label)
        lead = "#{label}: the WebSocket handshake failed (#{status})"
        raise HandshakeError, "#{lead}: the server did not answer 101 Switching Protocols" if status != 101
        raise HandshakeError, "#{lead}: the Upgrade header is not websocket" unless headers["upgrade"].to_s.downcase == "websocket"
        raise HandshakeError, "#{lead}: the Connection header has no upgrade" unless Client.has_token?(headers["connection"].to_s, "upgrade")
        raise HandshakeError, "#{lead}: the Sec-WebSocket-Accept does not match the key" unless headers["sec-websocket-accept"].to_s == Frame.accept_key(key)
        raise HandshakeError, "#{lead}: the server chose an extension, which was not offered" unless headers["sec-websocket-extensions"].nil?
        raise HandshakeError, "#{lead}: the server chose a subprotocol, which was not offered" unless headers["sec-websocket-protocol"].nil?

        nil
      end

      # Whether the comma-separated `list` holds `token` (any case).
      def self.has_token?(list, token)
        parts = list.to_s.split(",")
        i = 0
        while i < parts.size
          return true if HttpClient.trim(parts[i]).downcase == token

          i += 1
        end
        false
      end

      # Use Client.connect.
      def initialize(stream, reader, label, timeout, max_message)
        @stream = stream
        @reader = reader
        @label = label
        @timeout = timeout
        @max_message = max_message
        @assembler = Frame::Assembler.new(max_message)
        # Bytes of the fragmented message being assembled so far.
        @assembled = 0
        @open = true
        @close_code = 1006
        @close_reason = ""
        @last_activity_at = Net::Timer.now
        # The payload of the frame ws_read_frame read last.
        @frame_payload = ""
      end

      # @return [Boolean] false once the connection is closed (by #close, by
      #   the server or by an error)
      # @api public
      def ws_open?
        @open
      end

      # When a frame last arrived (or the connection opened), on the
      # monotonic clock (Net::Timer.now).
      # @return [Float]
      # @api public
      def last_activity_at
        @last_activity_at
      end

      # "host:port", what error messages name.
      # @return [String]
      # @api public
      def ws_label
        @label
      end

      # Sends a text message in one frame.
      # @param text [String] UTF-8
      # @return [nil]
      # @raise [Error] TimeoutError, ClosedError, ...
      # @api public
      def send_text(text)
        ws_send(Frame::OP_TEXT, text.to_s)
      end

      # Sends a binary message in one frame.
      # @param data [String]
      # @return [nil]
      # @api public
      def send_binary(data)
        ws_send(Frame::OP_BINARY, data.to_s)
      end

      # Sends a ping; the server's pong counts as activity.
      # @param payload [String] at most 125 bytes
      # @return [nil]
      # @api public
      def send_ping(payload = "")
        data = payload.to_s
        raise ArgumentError, "a ping payload is at most 125 bytes" if data.bytesize > 125

        ws_send(Frame::OP_PING, data)
      end

      # The next data message, waiting at most `wait` seconds. Pings are
      # answered and pongs noted on the way.
      # @param wait [Numeric] seconds
      # @return [Message, nil] nil when the wait ends first
      # @raise [ClosedError] the server closed (its code) or the connection
      #   ended (1006)
      # @raise [ProtocolError] the server broke the framing (close 1002 sent)
      # @raise [TooLargeError] a message past max_message (close 1009 sent)
      # @api public
      def receive(wait)
        ws_require_open
        seconds = wait.to_f
        @reader.reader_timer = Net::Timer.new(@label, seconds, seconds)
        ws_receive_guarded
      end

      # Sends close 1000, waits at most `timeout` for the server's close and
      # closes the connection. Safe to call twice; never raises.
      # @return [nil]
      # @api public
      def close
        return nil unless @open

        ws_try_write(Frame.encode(Frame::OP_CLOSE, Frame.close_payload(1000, ""), Client.mask_key))
        ws_await_close
        @close_code = 1000
        ws_drop
        nil
      end

      # ---- internals ------------------------------------------------------

      def self.mask_key
        SecureRandom.random_bytes(4)
      end

      def ws_require_open
        return nil if @open

        message = "#{@label}: the connection is closed"
        raise Cybertrain::WebSocket::ClosedError.new(message, @close_code, @close_reason)
      end

      def ws_send(opcode, payload)
        ws_require_open
        ws_write(Frame.encode(opcode, payload, Client.mask_key))
      end

      # Writes a frame, its Net errors translated; the connection is
      # dropped on any of them (a frame may have been half written).
      def ws_write(frame)
        @stream.stream_write(frame, Net::Timer.new(@label, @timeout, @timeout))
        nil
      rescue Cybertrain::Net::TimeoutError => e
        ws_drop
        raise Cybertrain::WebSocket::TimeoutError, e.message
      rescue Cybertrain::Net::TlsError => e
        ws_drop
        raise Cybertrain::WebSocket::TLSError, e.message
      rescue Cybertrain::Net::ConnectError => e
        ws_drop
        raise Cybertrain::WebSocket::ClosedError.new(e.message, 1006, "")
      end

      # Writes a frame when it can; for close frames, whose failure changes
      # nothing.
      def ws_try_write(frame)
        @stream.stream_write(frame, Net::Timer.new(@label, @timeout, @timeout))
        nil
      rescue Cybertrain::Net::Error
        nil
      end

      def ws_drop
        @open = false
        @stream.stream_close
        nil
      end

      # Sends a close with `code` (1002, 1009) and drops the connection.
      def ws_fail(code)
        ws_try_write(Frame.encode(Frame::OP_CLOSE, Frame.close_payload(code, ""), Client.mask_key))
        @close_code = code
        ws_drop
      end

      # receive's frame loop, its errors translated. A Net::TimeoutError
      # comes only from a read here (writes translate their own), and a read
      # that times out has consumed nothing: the answer is nil.
      def ws_receive_guarded
        ws_receive_loop
      rescue Cybertrain::Net::TimeoutError
        nil
      rescue Cybertrain::Net::ProtocolError
        ws_drop
        raise Cybertrain::WebSocket::ClosedError.new("#{@label}: the connection closed without a close frame", 1006, "")
      rescue Cybertrain::Net::ConnectError => e
        ws_drop
        raise Cybertrain::WebSocket::ClosedError.new(e.message, 1006, "")
      rescue Cybertrain::Net::TlsError => e
        ws_drop
        raise Cybertrain::WebSocket::TLSError, e.message
      rescue Cybertrain::WebSocket::ProtocolError => e
        ws_fail(1002)
        raise Cybertrain::WebSocket::ProtocolError, "#{@label}: #{e.message}"
      rescue Cybertrain::WebSocket::TooLargeError => e
        ws_fail(1009)
        raise Cybertrain::WebSocket::TooLargeError, "#{@label}: #{e.message}"
      end

      def ws_receive_loop
        while true
          header = ws_read_frame
          op = header.frame_opcode
          payload = @frame_payload
          @last_activity_at = Net::Timer.now
          if op == Frame::OP_PING
            ws_write(Frame.encode(Frame::OP_PONG, payload, Client.mask_key))
          elsif op == Frame::OP_CLOSE
            ws_closed_by_peer(payload)
          elsif op != Frame::OP_PONG
            if @assembler.add(op, header.frame_fin, payload)
              @assembled = 0
              return @assembler.take_message
            end
            @assembled = op == Frame::OP_CONTINUATION ? @assembled + payload.bytesize : payload.bytesize
          end
        end
        nil
      end

      # Reads one whole frame and consumes it; its payload (unmasked) goes
      # to @frame_payload. Nothing is consumed until the whole frame is
      # buffered, so a Net::TimeoutError leaves the Reader as it was. Raises
      # WebSocket::ProtocolError for a header a server may not send and
      # TooLargeError for a data frame that would pass max_message, both
      # before the payload is read.
      def ws_read_frame
        ws_ended unless @reader.fill_to(2)
        b1 = @reader.peek_bytes(2).getbyte(1)
        len7 = b1 & 0x7f
        size = 2
        size += 2 if len7 == 126
        size += 8 if len7 == 127
        size += 4 if (b1 & 0x80) != 0
        ws_ended unless @reader.fill_to(size)
        header = Frame.parse_header(@reader.peek_bytes(size))
        Frame.check_header(header, @assembler.assembling?, true)
        length = header.frame_length
        op = header.frame_opcode
        if op < 8
          before = op == Frame::OP_CONTINUATION ? @assembled : 0
          raise Cybertrain::WebSocket::TooLargeError, "message larger than #{@max_message} bytes" if before + length > @max_message
        end
        ws_ended unless @reader.fill_to(size + length)
        whole = @reader.read_exact(size + length)
        @frame_payload = Frame.unmask(whole.byteslice(size, length), header.frame_mask_key)
        header
      end

      # The stream ended without a close frame.
      def ws_ended
        raise Cybertrain::Net::ProtocolError, "#{@label}: the connection closed without a close frame"
      end

      # The server sent a close: answer it with its code, drop the
      # connection and raise ClosedError with the code and the reason.
      def ws_closed_by_peer(payload)
        code = Frame.close_code(payload)
        reason = Frame.close_reason(payload)
        answer = code == 1005 || code == 1006 || code == 1015 ? "" : Frame.close_payload(code, "")
        ws_try_write(Frame.encode(Frame::OP_CLOSE, answer, Client.mask_key))
        @close_code = code
        @close_reason = reason
        ws_drop
        message = "#{@label}: closed by the server (#{code})"
        raise Cybertrain::WebSocket::ClosedError.new(message, code, reason)
      end

      # After our close: reads (and drops) frames until the server's close,
      # the end of the stream, an error or `timeout` seconds.
      def ws_await_close
        @reader.reader_timer = Net::Timer.new(@label, @timeout, @timeout)
        while true
          header = ws_read_frame
          return nil if header.frame_opcode == Frame::OP_CLOSE
        end
        nil
      rescue Cybertrain::Net::Error, Cybertrain::WebSocket::Error
        nil
      end
    end
  end
end
