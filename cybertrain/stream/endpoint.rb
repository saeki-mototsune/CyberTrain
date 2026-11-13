require "json"
require "cybertrain/middleware"
require "cybertrain/http/body_writer"
require "cybertrain/http/sse"
require "cybertrain/http/parser"
require "cybertrain/http/query"
require "cybertrain/stream"
require "cybertrain/stream/websocket_server"

module Cybertrain
  module Stream
    # What one request to the endpoint asked for: the verified stream
    # names, the mode, and where a replay starts.
    class StreamRequest
      attr_reader :request_names, :request_json, :request_after, :request_problem, :request_tokens

      def initialize(names, json, after, problem, tokens)
        @request_names = names
        @request_json = json
        @request_after = after
        @request_problem = problem
        @request_tokens = tokens
      end
    end

    # The realtime endpoint (docs/design.md D36), mounted by
    # Application#build_stack at {Config#stream_path}
    # (`/cybertrain/stream`) unless that is "". A GET with `s=<token>`
    # (repeatable; {Stream.sign}, what `turbo_stream_from` writes) and
    # optionally `mode=raw|json` is answered as Server-Sent Events: each
    # message of the token's streams as an event (`id:` and `data:`; with
    # mode=json also `event: <stream>` and the data is
    # `{"stream":...,"id":...,"data":...}`), a `: ping` comment after
    # {Config#stream_ping_interval} seconds of silence. `Last-Event-ID`
    # replays what is still in the table after that id first. A GET with
    # `Upgrade: websocket` gets the same messages over a WebSocket
    # ({WebSocketWriter}).
    #
    # Authorisation is the token's signature: a bad or missing one is a 403
    # (with no body, nothing read from the database); no session is read.
    # Past {Config#stream_max_connections} open streams the answer is 503.
    # @api public
    class Endpoint < Middleware
      def initialize(app, config)
        super(app)
        @config = config
        @stream_path = config.stream_path
      end

      def call(ctx)
        request = ctx.request
        return super unless request.path == @stream_path

        response = ctx.response
        unless request.get? || request.head?
          Endpoint.plain(response, 405)
          response.set_header("Allow", "GET")
          return nil
        end
        # Application#serve starts the poller before it binds the port; a
        # stack without it would subscribe connections nothing feeds.
        unless Poller.running?
          Endpoint.plain(response, 503)
          response.body = "stream poller is not running"
          return nil
        end
        wanted = Endpoint.parse(request)
        return Endpoint.upgrade(ctx, wanted, @config) if Endpoint.websocket?(request)

        problem = wanted.request_problem
        if problem > 0
          Endpoint.plain(response, problem)
          return nil
        end
        config = @config
        hub = Stream.hub
        if hub.subscriber_count >= config.stream_max_connections
          Endpoint.plain(response, 503)
          return nil
        end
        response.status = 200
        response.content_type = "text/event-stream"
        response.set_header("Cache-Control", "no-store")
        response.set_header("X-Accel-Buffering", "no")
        after = Endpoint.last_event_id(request.header("last-event-id").to_s, wanted.request_after)
        response.body_writer = SSEWriter.new(hub, wanted.request_names, wanted.request_json, after,
                                             config.stream_ping_interval, config.stream_max_connections)
        nil
      end

      # Whether the request asks for a WebSocket (`Upgrade: websocket`).
      def self.websocket?(request)
        HeaderName.lower(request.header("upgrade").to_s) == "websocket"
      end

      # The WebSocket branch: the RFC 6455 handshake checks (a 400 when one
      # fails: version 13, a 16-byte key, `Connection: upgrade`), then the
      # 101 with the accept key; a bad token or a full process still gets
      # the 101, then the close (1008, 1013), which is what a browser's
      # WebSocket can report. Extensions and subprotocols are not
      # negotiated (permessage-deflate is answered without it).
      def self.upgrade(ctx, wanted, config)
        request = ctx.request
        response = ctx.response
        key = request.header("sec-websocket-key").to_s
        unless request.get? && request.header("sec-websocket-version").to_s == "13" &&
               Stream.base64_key?(key) && Endpoint.upgrade_token?(request.header("connection").to_s)
          Endpoint.plain(response, 400)
          response.set_header("Sec-WebSocket-Version", "13")
          return nil
        end
        problem = wanted.request_problem
        if problem == 400
          Endpoint.plain(response, 400)
          return nil
        end
        close_code = 0
        # A token that did not verify; none at all is fine in mode=json,
        # where the client subscribes with messages.
        close_code = 1008 if problem == 403 && (wanted.request_tokens > 0 || !wanted.request_json)
        hub = Stream.hub
        close_code = 1013 if close_code == 0 && hub.subscriber_count >= config.stream_max_connections
        names = close_code == 0 ? wanted.request_names : Array.new(0) { "" }
        writer = WebSocketWriter.new(hub, names, wanted.request_json, wanted.request_after,
                                     config.stream_ping_interval, config.stream_max_message, close_code,
                                     config.stream_max_connections)
        response.set_header("Upgrade", "websocket")
        response.set_header("Sec-WebSocket-Accept", WebSocket::Frame.accept_key(key))
        response.upgrade!(writer)
        nil
      end

      # Whether a Connection header's comma-separated list holds "upgrade".
      def self.upgrade_token?(value)
        parts = value.split(",")
        i = 0
        while i < parts.size
          return true if HeaderName.lower(parts[i].strip) == "upgrade"

          i += 1
        end
        false
      end

      # An empty-bodied answer: 403, 400, 405 or 503.
      def self.plain(response, status)
        response.status = status
        response.content_type = "text/plain; charset=utf-8"
        response.body = ""
        nil
      end

      # The query: every `s` token (each must verify), `mode`, `after`.
      # A problem status (400, 403) when it is not usable, else 0.
      def self.parse(request)
        names = Array.new(0) { "" }
        json = false
        after = -1
        tokens = 0
        query = request.utf8_query_string
        parts = query.split("&")
        i = 0
        while i < parts.size
          part = parts[i]
          eq = part.byteindex("=")
          key = eq.nil? ? part : part.byteslice(0, eq)
          value = eq.nil? ? "" : Query.decode(part.byteslice(eq + 1, part.bytesize - eq - 1))
          if key == "s"
            tokens += 1
            verified = Stream.verified_names(value)
            return StreamRequest.new(names, json, after, 403, tokens) if verified.empty?

            Endpoint.add_names(names, verified)
          elsif key == "mode"
            if value == "json"
              json = true
            elsif value != "raw"
              return StreamRequest.new(names, json, after, 400, tokens)
            end
          elsif key == "after"
            after = Endpoint.event_id(value)
            return StreamRequest.new(names, json, -1, 400, tokens) if after < 0
          end
          i += 1
        end
        return StreamRequest.new(names, json, after, 403, tokens) if tokens == 0
        return StreamRequest.new(names, json, after, 403, tokens) if names.size > MAX_NAMES * 4

        StreamRequest.new(names, json, after, 0, tokens)
      end

      def self.add_names(names, more)
        i = 0
        while i < more.size
          name = more[i]
          names << name unless Stream.name_in?(names, name)
          i += 1
        end
        nil
      end

      # A message id from text: digits only, at most 18 (spikes/NOTES.md
      # rule 25), else -1.
      def self.event_id(text)
        return -1 if text.empty? || text.bytesize > 18 || !HttpParser.digits?(text)

        text.to_i
      end

      # Last-Event-ID wins over ?after= (an EventSource sends it on every
      # reconnect); a header that is not an id is ignored.
      def self.last_event_id(header, after)
        return after if header.empty?

        id = Endpoint.event_id(header)
        id < 0 ? after : id
      end
    end

    # The SSE session on the connection's thread: subscribe, replay, then
    # wait for messages in slices of at most a second (so a client that
    # closed, a dropped subscriber or a server that is stopping is noticed
    # within one), writing each one, and a `: ping` after ping_interval
    # seconds of silence. A client that vanished without a FIN is noticed
    # when a ping's write fails.
    class SSEWriter < BodyWriter
      SLICE = 1.0

      def initialize(hub, names, json, after, ping_interval, max_connections)
        @max_connections = max_connections
        @hub = hub
        @names = names
        @json = json
        @after = after
        @head = -1
        @ping_interval = ping_interval
      end

      def write_body(sink)
        hub = @hub
        # The limit again, under the hub's lock (Endpoint#call's check is
        # the fast 503; two connections can pass it together): a stream
        # that does not fit ends at once.
        # The head before the subscription (Stream.replay_start).
        @head = Stream.replay_head(@after)
        sub = hub.subscribe_within(@names, @max_connections)
        return nil if sub.nil?

        begin
          sse_session(sink, sub)
        ensure
          hub.unsubscribe(sub)
        end
        nil
      end

      private

      def sse_session(sink, sub)
        # Subscribed first (write_body), then the replay, then the boundary,
        # max(after, the last replayed id) (`after` itself when the replay
        # found nothing): a row broadcast while the replay ran is either in
        # the replay or queued, and skip_through! drops the queued copy of a
        # replayed one.
        last = Stream.replay_start(@after, @head)
        if last >= 0
          # By chunks, each written before the next query; the boundary
          # never passes a row that was not sent.
          cursor = sub.boundary
          while !sink.closed?
            backlog = Stream.replay(@names, last)
            i = 0
            while i < backlog.size
              msg = backlog[i]
              sink.write(sse_event(msg))
              last = msg.message_id
              i += 1
            end
            break if backlog.size < Stream::REPLAY_CHUNK || last >= cursor
          end
          sub.skip_through!(last)
        end
        ping = @ping_interval.to_f
        slice = ping < SLICE ? ping : SLICE
        quiet_since = Clock.monotonic
        while !sink.closed? && !sub.dropped? && Poller.running?
          msg = sub.stream_pop(slice)
          now = Clock.monotonic
          if msg.nil?
            if now - quiet_since >= ping
              sink.write(": ping\n\n")
              quiet_since = now
            end
          else
            sink.write(sse_event(msg))
            quiet_since = now
          end
          break if sink.wait_closed(0)
        end
        nil
      end

      def sse_event(msg)
        id = msg.message_id.to_s
        return SSE.event(msg.message_payload, id: id) unless @json

        SSE.event(Stream.envelope(msg), event: msg.message_stream, id: id)
      end
    end

    # `{"stream":"a","id":12,"data":"..."}`, what mode=json sends.
    def self.envelope(msg)
      JSON.generate({ "stream" => msg.message_stream, "id" => msg.message_id, "data" => msg.message_payload })
    end
  end
end
