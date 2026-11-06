require "json"
require "cybertrain/logger"
require "cybertrain/http/body_writer"
require "cybertrain/websocket/frame"
require "cybertrain/stream"

module Cybertrain
  module Stream
    # A control message the reader thread hands the session thread through
    # the subscriber's queue (id CONTROL_ID, the kind as its stream name, the
    # frame's payload as its payload), so that one thread does every write.
    CONTROL_ID = -1

    # Reads a WebSocket client's frames on a thread of its own and turns
    # each into a control message on the subscriber's queue: "text" and
    # "binary" (a whole message), "ping", "pong", "close" (its payload),
    # "eof" (the stream ended, also when the server shut the read side to
    # stop), "protocol" (a framing error) and "toobig" (past max_message).
    # Every read is preceded by wait_readable (spikes/NOTES.md rule 20). The
    # buffer is an ivar filled with << and consumed by an offset, so a NUL
    # byte in a masked payload is never lost to a strlen copy (rule 60).
    class WsReader
      READ_CHUNK = 16384
      POLL = 1.0

      def initialize(socket, sub, max_message)
        @socket = socket
        @sub = sub
        @max_message = max_message
        @assembler = WebSocket::Frame::Assembler.new(max_message)
        @assembled = 0
        @buf = +""
        @pos = 0
        @done = false
      end

      # Asks the thread to end (it does within POLL seconds).
      def reader_stop!
        @done = true
        nil
      end

      # The thread's body: frames until EOF, an error or reader_stop!.
      def reader_loop
        while !@done
          ready = @socket.wait_readable(POLL)
          next if ready.nil?

          chunk = reader_read
          if chunk.empty?
            reader_push("eof", "")
            return nil
          end
          @buf << chunk
          return nil unless reader_frames
        end
        nil
      rescue IOError, SystemCallError
        reader_push("eof", "")
        nil
      end

      private

      def reader_read
        @socket.readpartial(READ_CHUNK)
      rescue EOFError, IOError, SystemCallError
        ""
      end

      # False once the subscriber's control queue is full (the reader stops).
      def reader_push(kind, payload)
        @done = true unless @sub.stream_control(Message.new(CONTROL_ID, kind, payload))
        !@done
      end

      # Takes every whole frame off the buffer; false once the connection
      # must end (a close, a framing error, a message too large).
      def reader_frames
        while true
          outcome = reader_one
          return true if outcome == 0
          return false if outcome < 0
        end
        true
      rescue Cybertrain::WebSocket::TooLargeError
        reader_push("toobig", "")
        false
      rescue Cybertrain::WebSocket::ProtocolError
        reader_push("protocol", "")
        false
      end

      # 1: a frame was taken, 0: more bytes are needed, -1: a close came.
      def reader_one
        have = @buf.bytesize - @pos
        return 0 if have < 2

        head_bytes = @buf.byteslice(@pos, have < 14 ? have : 14)
        header = WebSocket::Frame.parse_header(head_bytes)
        size = header.frame_header_size
        return 0 if size == 0

        WebSocket::Frame.check_header(header, @assembler.assembling?, false)
        op = header.frame_opcode
        length = header.frame_length
        if op < 8
          before = op == WebSocket::Frame::OP_CONTINUATION ? @assembled : 0
          raise Cybertrain::WebSocket::TooLargeError, "message too large" if before + length > @max_message
        end
        return 0 if have < size + length

        payload = WebSocket::Frame.unmask(@buf.byteslice(@pos + size, length), header.frame_mask_key)
        reader_consume(size + length)
        if op == WebSocket::Frame::OP_PING
          return -1 unless reader_push("ping", payload)
        elsif op == WebSocket::Frame::OP_PONG
          reader_push("pong", "")
        elsif op == WebSocket::Frame::OP_CLOSE
          # A close code a peer may not send is a framing error (1002).
          WebSocket::Frame.close_code(payload)
          reader_push("close", payload)
          return -1
        else
          if @assembler.add(op, header.frame_fin, payload)
            @assembled = 0
            msg = @assembler.take_message
            return -1 unless reader_push(msg.ws_opcode == :text ? "text" : "binary", msg.ws_data)
          else
            @assembled = op == WebSocket::Frame::OP_CONTINUATION ? @assembled + payload.bytesize : payload.bytesize
          end
        end
        1
      end

      # Moves the offset; an emptied buffer starts over as a fresh literal,
      # a large consumed prefix is cut by copying the rest with <<.
      def reader_consume(n)
        @pos += n
        if @pos >= @buf.bytesize
          @buf = +""
          @pos = 0
        elsif @pos > 65536
          rest = +""
          rest << @buf.byteslice(@pos, @buf.bytesize - @pos)
          @buf = rest
          @pos = 0
        end
        nil
      end
    end

    # The WebSocket session (RFC 6455, server side) after the 101 the
    # Server wrote: a reader thread for the client's frames ({WsReader}),
    # and this thread for every write, waiting on the subscriber's queue,
    # which carries both the broadcasts and the reader's control messages.
    # Broadcasts go out as text frames (the payload as it is, or the
    # mode=json envelope); a ping after ping_interval seconds of silence; a
    # client ping is answered with a pong; a client close with a close. In
    # mode=json the client's text frames `{"subscribe":"<token>"}` and
    # `{"unsubscribe":"<token>"}` change the streams, answered with
    # `{"subscribed":[...]}` / `{"unsubscribed":[...]}` or
    # `{"error":"bad token"}`. Frames to the client are unmasked
    # (`Frame.encode(op, payload, "")`). Close codes: 1000 when the server
    # stops (the reader sees the read side shut), 1008 for a bad token at
    # connect, 1009 for a message past {Config#stream_max_message}, 1002
    # for a framing error, 1013 past {Config#stream_max_connections} and
    # for a subscriber dropped for its backlog.
    class WebSocketWriter < BodyWriter
      SLICE = 1.0
      # How long to wait for the client's close after ours.
      CLOSE_WAIT = 1.0

      # close_code > 0: answer the handshake with that close at once.
      def initialize(hub, names, json, after, ping_interval, max_message, close_code, max_connections)
        @max_connections = max_connections
        @hub = hub
        @names = names
        @json = json
        @after = after
        @head = -1
        @ping_interval = ping_interval
        @max_message = max_message
        @close_code = close_code
      end

      def write_body(sink)
        hub = @hub
        code = @close_code
        sub = Subscriber.new(Array.new(0) { "" }, 1)
        if code == 0
          # The head before the subscription (Stream.replay_start).
          @head = Stream.replay_head(@after)
          # The limit under the hub's lock (see SSEWriter#write_body).
          within = hub.subscribe_within(@names, @max_connections)
          if within.nil?
            code = 1013
          else
            sub = within
          end
        end
        # A connection closed at once keeps a subscriber of its own, outside
        # the hub, for the reader's control messages while it waits for the
        # client's close.
        sock = sink.socket
        reader = WsReader.new(sock, sub, @max_message)
        thread = WebSocketWriter.spawn_reader(reader)
        begin
          if code > 0
            ws_close(sink, sub, code)
          else
            ws_session(sink, sub)
          end
        ensure
          WebSocketWriter.stop_reader(reader, thread, sock)
          hub.unsubscribe(sub)
        end
        nil
      end

      # Ends the reader before the Server closes the socket (so it never
      # waits on a descriptor that a new connection may reuse): shutting
      # the read side wakes its wait at once (as Server#drain does), then
      # it is joined.
      def self.stop_reader(reader, thread, sock)
        reader.reader_stop!
        WebSocketWriter.shut_read(sock)
        thread.join
        nil
      end

      def self.shut_read(sock)
        sock.shutdown(Socket::SHUT_RD) unless sock.closed?
        nil
      rescue IOError, SystemCallError
        nil
      end

      # Through a method whose parameter the closure captures (rule 21).
      def self.spawn_reader(reader)
        Thread.new { reader.reader_loop }
      end

      private

      def ws_session(sink, sub)
        last = Stream.replay_start(@after, @head)
        if last >= 0
          # By chunks, as SSEWriter does.
          cursor = sub.boundary
          names = sub.stream_names
          while !sink.closed?
            backlog = Stream.replay(names, last)
            i = 0
            while i < backlog.size
              msg = backlog[i]
              ws_send(sink, WebSocket::Frame::OP_TEXT, ws_text(msg))
              last = msg.message_id
              i += 1
            end
            break if backlog.size < Stream::REPLAY_CHUNK || last >= cursor
          end
          sub.skip_through!(last)
        end
        ping = @ping_interval.to_f
        slice = ping < SLICE ? ping : SLICE
        started = Time.now.to_f
        quiet_since = started
        empty_since = started
        while !sink.closed?
          if sub.dropped?
            ws_close(sink, sub, 1013)
            return nil
          end
          if sub.control_overflow?
            ws_close(sink, sub, 1008)
            return nil
          end
          # The server stops (as the SSE loop ends with the poller).
          unless Poller.running?
            ws_close(sink, sub, 1000)
            return nil
          end
          # Decision: a connection that listens to nothing (mode=json with
          # no token and no subscribe) for one ping interval is closed with
          # 1008, so it cannot hold a connection slot on pings alone. The
          # interval counts from when the name list became (or stayed)
          # empty, so a client that unsubscribes its last stream and then
          # subscribes another is not cut off between the two.
          if sub.name_count > 0
            empty_since = Time.now.to_f
          elsif Time.now.to_f - empty_since >= ping
            ws_close(sink, sub, 1008)
            return nil
          end
          msg = sub.stream_pop(slice)
          now = Time.now.to_f
          if msg.nil?
            if now - quiet_since >= ping
              ws_send(sink, WebSocket::Frame::OP_PING, "")
              quiet_since = now
            end
          elsif msg.message_id == CONTROL_ID
            return nil unless ws_control(sink, sub, msg.message_stream, msg.message_payload)
          else
            ws_send(sink, WebSocket::Frame::OP_TEXT, ws_text(msg))
            quiet_since = now
          end
        end
        nil
      end

      # One control message; false once the session is over.
      def ws_control(sink, sub, kind, payload)
        case kind
        when "ping"
          ws_send(sink, WebSocket::Frame::OP_PONG, payload)
        when "text"
          ws_client_text(sink, sub, payload) if @json
        when "close"
          # The reader validated it (Frame.close_code); answered with the
          # client's code, none for an empty close, never its raw bytes.
          code = WebSocket::Frame.close_code(payload)
          answer = code == 1005 ? "" : WebSocket::Frame.close_payload(code, "")
          ws_send(sink, WebSocket::Frame::OP_CLOSE, answer)
          return false
        when "overflow"
          ws_close(sink, sub, 1008)
          return false
        when "eof"
          # the client is gone, or the server shut the read side to stop:
          # a close 1000 reaches a client that is still there
          ws_send(sink, WebSocket::Frame::OP_CLOSE, WebSocket::Frame.close_payload(1000, ""))
          return false
        when "toobig"
          ws_close(sink, sub, 1009)
          return false
        when "protocol"
          ws_close(sink, sub, 1002)
          return false
        end
        true
      end

      # `{"subscribe":"<token>"}` / `{"unsubscribe":"<token>"}`.
      def ws_client_text(sink, sub, text)
        request = WebSocketWriter.client_request(text)
        kind = request[0]
        if kind.empty?
          ws_send(sink, WebSocket::Frame::OP_TEXT, "{\"error\":\"bad message\"}")
          return nil
        end
        names = Stream.verified_names(request[1])
        if names.empty?
          ws_send(sink, WebSocket::Frame::OP_TEXT, "{\"error\":\"bad token\"}")
          return nil
        end
        if kind == "subscribe"
          unless @hub.add_names(sub, names)
            ws_send(sink, WebSocket::Frame::OP_TEXT, "{\"error\":\"too many streams\"}")
            return nil
          end
          ws_send(sink, WebSocket::Frame::OP_TEXT, JSON.generate({ "subscribed" => sub.stream_names }))
        else
          @hub.remove_names(sub, names)
          ws_send(sink, WebSocket::Frame::OP_TEXT, JSON.generate({ "unsubscribed" => names }))
        end
        nil
      end

      # ["subscribe" | "unsubscribe", token], or ["", ""] for anything else.
      # The rescue in a plain method (rules 32/45); NestingError first (61).
      def self.client_request(text)
        parsed = JSON.parse(text)
        case parsed
        when Hash
          token = parsed["subscribe"]
          case token
          when String then return ["subscribe", token]
          end
          token = parsed["unsubscribe"]
          case token
          when String then return ["unsubscribe", token]
          end
        end
        ["", ""]
      rescue JSON::NestingError, JSON::ParserError, StandardError
        ["", ""]
      end

      # Sends close `code` and waits up to CLOSE_WAIT for the client's.
      def ws_close(sink, sub, code)
        ws_send(sink, WebSocket::Frame::OP_CLOSE, WebSocket::Frame.close_payload(code, ""))
        deadline = Time.now.to_f + CLOSE_WAIT
        while !sink.closed?
          left = deadline - Time.now.to_f
          break if left <= 0

          msg = sub.stream_pop(left)
          break if msg.nil?
          next unless msg.message_id == CONTROL_ID

          kind = msg.message_stream
          break if kind == "close" || kind == "eof" || kind == "protocol" || kind == "toobig"
        end
        nil
      end

      def ws_send(sink, opcode, payload)
        sink.write(WebSocket::Frame.encode(opcode, payload, ""))
        nil
      end

      def ws_text(msg)
        @json ? Stream.envelope(msg) : msg.message_payload
      end
    end
  end
end
