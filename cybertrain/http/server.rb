require "socket"
require "cybertrain/http/parser"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/context"
require "cybertrain/middleware"
require "cybertrain/logger"

module Cybertrain
  # A pure-Ruby HTTP/1.1 server: one TCPServer, one green thread per
  # connection, keep-alive and pipelining, and a Middleware (usually an App)
  # that turns each Context into a Response.
  #
  #   server = Cybertrain::Server.new(app, port: 3000)
  #   server.run   # blocks until server.stop
  class Server
    # Raised while reading a request the server refuses to process; serve
    # answers with this status and closes the connection.
    class Rejected < StandardError
      attr_reader :reject_status

      def initialize(status)
        super("rejected with #{status}")
        @reject_status = status
      end
    end

    READ_CHUNK = 16384
    # How often the accept loop checks whether #stop was called.
    ACCEPT_POLL = 0.1

    # port is the bound port once #start has run (the ephemeral one with port: 0).
    attr_reader :host, :port

    def initialize(app, host: "127.0.0.1", port: 3000, read_timeout: 15,
                   max_head_bytes: 65536, max_body_bytes: 10_485_760, logger: Cybertrain.logger)
      @app = app
      @host = host
      @port = port
      @read_timeout = read_timeout
      @max_head_bytes = max_head_bytes
      @max_body_bytes = max_body_bytes
      @logger = logger
      @running = false
      @accept_thread = nil
    end

    # Binds, listens and spawns the accept thread; returns once listening.
    def start
      # spikes/NOTES.md rule 22: one worker is faster for an I/O-bound server.
      # It must be set before the first Thread.new starts the scheduler.
      ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
      listener = TCPServer.new(@host, @port)
      listener.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      @port = listener.addr[1]
      @running = true
      @accept_thread = spawn_acceptor(listener)
      nil
    end

    # Starts the server and blocks until #stop is called.
    def run
      start
      thread = @accept_thread
      thread.join unless thread.nil?
      nil
    end

    # Stops accepting: the accept thread notices within ACCEPT_POLL seconds
    # and closes the listener. Connections already open finish on their own.
    def stop
      @running = false
      thread = @accept_thread
      thread.join unless thread.nil?
      nil
    end

    private

    def spawn_acceptor(listener)
      Thread.new { accept_loop(listener) }
    end

    # A timed wait_readable instead of a bare accept, so #stop does not
    # depend on closing a descriptor another thread is blocked on.
    #
    # A failed accept (EMFILE when descriptors run out, ECONNABORTED when a
    # client resets before we accept it) is logged and retried after a short
    # back-off; only #stop or a closed listener ends the loop.
    def accept_loop(listener)
      while @running && !listener.closed?
        begin
          spawn_connection(accept_client(listener)) unless listener.wait_readable(ACCEPT_POLL).nil?
        rescue StandardError => e
          unless listener.closed?
            @logger.error("accept failed: #{e.class.name}: #{e.message}")
            sleep ACCEPT_POLL
          end
        end
      end
    ensure
      listener.close unless listener.closed?
    end

    def accept_client(listener)
      listener.accept
    end

    # NOTES rule 21: the socket must reach the thread through this method's
    # parameter, never as a Thread.new argument (it would lose its type).
    def spawn_connection(sock)
      Thread.new { serve(sock) }
    end

    # One connection: read a head, read its body, run the app, write the
    # response, and loop while the client keeps the connection alive.
    # Every readpartial is preceded by wait_readable (NOTES rule 20); a nil
    # wait means the client has been silent for read_timeout seconds.
    #
    # `while true` rather than `loop do`: inside a `loop` block Spinel drops
    # the ivars of a raised exception (Rejected#status reads 0) and skips
    # the value expression of `return value`.
    #
    # All framing is in bytes (byteindex/byteslice): Spinel slices a String
    # holding non-ASCII bytes by character, so `buf[i, n]` would take too many
    # bytes after a UTF-8 body and shift the next pipelined request.
    def serve(sock)
      remote_addr = sock.peeraddr[3].to_s
      buf = +""
      while true
        idx = buf.byteindex(HttpParser::HEAD_END)
        while idx.nil?
          raise Rejected.new(400) if buf.bytesize > @max_head_bytes
          return if sock.wait_readable(@read_timeout).nil?

          buf << sock.readpartial(READ_CHUNK)
          idx = buf.byteindex(HttpParser::HEAD_END)
        end
        raise Rejected.new(400) if idx > @max_head_bytes

        head = HttpParser.parse_head(buf.byteslice(0, idx))
        rest = buf.byteslice(idx + 4, buf.bytesize - idx - 4)

        raise Rejected.new(411) if !head.headers["transfer-encoding"].nil?

        length = body_length(head.headers["content-length"])
        raise Rejected.new(400) if length < 0
        raise Rejected.new(413) if length > @max_body_bytes

        while rest.bytesize < length
          return if sock.wait_readable(@read_timeout).nil?

          rest << sock.readpartial(READ_CHUNK)
        end
        body = rest.byteslice(0, length)
        buf = rest.byteslice(length, rest.bytesize - length)

        request = Request.new(head.method, head.target, head.headers, body, remote_addr, head.http_version)
        break unless respond(sock, request)
      end
    rescue Rejected => e
      reject(sock, e.reject_status)
    rescue HttpParser::ParseError
      reject(sock, 400)
    rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
      # the client went away; nothing to answer
    rescue StandardError => e
      @logger.error("connection error: #{e.class.name}: #{e.message}")
    ensure
      sock.close unless sock.closed?
    end

    # Runs the app and writes its response; true when the connection stays open.
    def respond(sock, request)
      ctx = Context.new(request)
      response = ctx.response
      begin
        @app.call(ctx)
      rescue StandardError => e
        @logger.error("#{e.class.name}: #{e.message}")
        response = error_response(500)
      end
      keep_alive = request.keep_alive?
      response.set_header("Connection", keep_alive ? "keep-alive" : "close")
      sock.write(response.to_http(request.head?))
      keep_alive
    end

    # Writes an error response; serve closes the socket afterwards.
    def reject(sock, status)
      response = error_response(status)
      response.set_header("Connection", "close")
      begin
        sock.write(response.to_http)
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        # the client is already gone
      end
      nil
    end

    def error_response(status)
      response = Response.new
      response.status = status
      response.content_type = "text/plain"
      response.body = response.status_text
      response
    end

    # Content-Length as an Integer: 0 when absent, -1 when it is not a plain
    # decimal number (including duplicated headers joined as "5, 5").
    # More than 18 significant digits is reported as just over max_body_bytes
    # (so 413) without calling to_i: Spinel's String#to_i raises RangeError
    # past 2**63-1 instead of saturating or promoting to Bignum.
    def body_length(value)
      return 0 if value.nil?
      return -1 if value.empty? || !value.bytes.all? { |b| b >= 48 && b <= 57 }

      first = 0
      first += 1 while first < value.bytesize - 1 && value.getbyte(first) == 48
      digits = value.bytesize - first
      return @max_body_bytes + 1 if digits > 18

      value.byteslice(first, digits).to_i
    end
  end
end
