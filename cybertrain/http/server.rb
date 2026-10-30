require "socket"
require "json"
require "cybertrain/http/parser"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/handler"
require "cybertrain/http/client_error"
require "cybertrain/logger"

module Cybertrain
  # Raised by Server#start when the listener cannot bind: another process
  # holds the port (EADDRINUSE, or under Spinel a busy privileged port's
  # ECONNREFUSED) or the port is privileged and out of reach (CRuby's EACCES,
  # or under Spinel the same ECONNREFUSED reclassified by bind_listener's
  # privileged_denied? since the exception class alone cannot tell the two
  # apart there) -- its own reason so the operator does not hunt for a
  # process that is not there. The message is what Application#serve prints
  # before exiting.
  class PortInUse < StandardError
    attr_reader :port

    IN_USE = "is already in use (stop the other server or set PORT)"
    PERMISSION_DENIED = "cannot be bound: permission denied (ports below 1024 need root or a capability)"

    def initialize(host, port, reason = IN_USE)
      super("port #{port} on #{host} #{reason}")
      @port = port
    end
  end

  # A pure-Ruby HTTP/1.1 server: one TCPServer, one green thread per
  # connection, keep-alive and pipelining, and an HttpHandler that turns each
  # Request into a Response. The framework's handler is ContextHandler, which
  # wraps a Middleware stack (usually an App); the HTTP layer itself does not
  # depend on it.
  #
  #   server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(app), port: 3000)
  #   server.run   # blocks until server.stop, then drains open connections
  #
  # Graceful shutdown (docs/design.md D14): #request_stop (the TERM trap) or
  # #stop closes the listener; requests already being processed get their
  # response (with Connection: close), idle keep-alive connections are
  # closed, and #run returns once every connection is gone or drain_timeout
  # seconds have passed.
  class Server
    # One open connection, as the drain sees it: its socket, and whether its
    # thread is waiting for the next request on it (idle). The flag is
    # written by the connection's own thread without a lock; the drain only
    # reads it, and a connection it misses or reads late still ends by
    # read_timeout or the next drain pass.
    class Connection
      attr_reader :sock
      attr_accessor :id, :idle

      def initialize(sock)
        @id = 0
        @sock = sock
        @idle = false
      end
    end

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
    # How often the accept loop and the drain check whether #stop was
    # called. An idle keep-alive connection does not poll: it waits for its
    # next request for up to read_timeout, and the drain closes it.
    ACCEPT_POLL = 0.1

    # port is the bound port once #start has run (the ephemeral one with port: 0).
    attr_reader :host, :port

    # drain_timeout bounds how long #run and #stop wait for requests in
    # flight; keep it below the process manager's stop timeout (systemd's
    # TimeoutStopSec, 15 s in docs/deploy.md).
    def initialize(handler, host: "127.0.0.1", port: 3000, read_timeout: 15, drain_timeout: 10.0,
                   max_head_bytes: 65536, max_body_bytes: 10_485_760, logger: Cybertrain.logger)
      @handler = handler
      @host = host
      @port = port
      @read_timeout = read_timeout
      @drain_timeout = drain_timeout
      @max_head_bytes = max_head_bytes
      @max_body_bytes = max_body_bytes
      @logger = logger
      @running = false
      @accept_thread = nil
      # Connections accepted and not yet closed. Counted under @lock: with
      # SPINEL_WORKERS > 1 connection threads run in parallel. @lock is taken
      # when a connection opens and closes, never per request (NOTES rule 57).
      @lock = Mutex.new
      @open_count = 0
      @connections = {}   # Connection#id => Connection, for the drain
      @next_connection_id = 0
    end

    # Binds, listens and spawns the accept thread; returns once listening.
    # Raises PortInUse when the port cannot be bound.
    def start
      # spikes/NOTES.md rule 22: one worker is faster for an I/O-bound server.
      # It must be set before the first Thread.new starts the scheduler.
      ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
      listener = bind_listener
      listener.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      @port = listener.addr[1]
      @running = true
      @accept_thread = spawn_acceptor(listener)
      nil
    end

    # Starts the server and blocks until #stop or #request_stop is called
    # and the open connections have drained.
    def run
      start
      wait
    end

    # Blocks until #stop or #request_stop is called and the open
    # connections have drained; #start must have run (Application starts
    # first so a bind failure surfaces before the boot banner).
    def wait
      thread = @accept_thread
      thread.join unless thread.nil?
      drain
      nil
    end

    # Stops accepting: the accept thread notices within ACCEPT_POLL seconds
    # and closes the listener. Returns once the connections still open have
    # finished their current request (at most drain_timeout seconds).
    def stop
      request_stop
      thread = @accept_thread
      thread.join unless thread.nil?
      drain
      nil
    end

    # Connections accepted and not yet closed.
    def open_connections
      count = 0
      @lock.synchronize { count = @open_count }
      count
    end

    # What a signal handler may call: only clears the flag the accept loop
    # polls, so #run stops accepting within ACCEPT_POLL seconds and then
    # drains, which closes the idle connections. Spinel runs a trap block straight from its C
    # signal handler, where #stop's Thread#join, the drain's sleep and the
    # Mutex are not async-signal-safe.
    def request_stop
      @running = false
      nil
    end

    private

    # The bind failures a busy or privileged port produces, turned into one
    # PortInUse whose message names the host, the port and the reason.
    #
    # CRuby raises Errno::EACCES for a privileged port bound without root, so
    # that rescue is kept. Spinel's TCPServer.new instead raises the same
    # Errno::ECONNREFUSED a busy port would (a compiled binary really run on
    # PORT=80 as a non-root user printed the "already in use" message), so the
    # exception class cannot tell the two apart there. privileged_denied?
    # decides from context instead: a port below 1024 refused to a non-root
    # process is a permission problem, not a competing listener, because the
    # kernel checks the capability before it checks whether the port is free.
    def bind_listener
      TCPServer.new(@host, @port)
    rescue Errno::EACCES
      raise PortInUse.new(@host, @port, PortInUse::PERMISSION_DENIED)
    rescue Errno::EADDRINUSE, Errno::ECONNREFUSED
      reason = privileged_denied? ? PortInUse::PERMISSION_DENIED : PortInUse::IN_USE
      raise PortInUse.new(@host, @port, reason)
    end

    def privileged_denied?
      @port < 1024 && Process.uid != 0
    end

    # Waits, in ordinary thread context, until every connection has closed
    # or drain_timeout seconds have passed. Whatever is still open then is
    # cut off when the process exits. Each pass closes the connections that
    # are waiting for a next request; one busy with a request answers it
    # with Connection: close (respond) and ends.
    def drain
      started = Time.now
      close_idle_connections
      remaining = open_connections
      while remaining > 0
        if Time.now - started >= @drain_timeout
          @logger.warn("shutting down with #{remaining} connection(s) still open after #{@drain_timeout}s")
          break
        end
        sleep ACCEPT_POLL
        close_idle_connections
        remaining = open_connections
      end
      nil
    end

    # Closes every connection whose thread is waiting for its next request
    # and has nothing to read yet. Spinel wakes a thread parked in
    # wait_readable on a socket another thread closes, with IOError ("stream
    # closed in another thread", as CRuby does), and serve ends quietly on
    # IOError. A connection whose next request has already arrived is left
    # to read it: it sees the stop, answers with Connection: close and ends.
    def close_idle_connections
      idle = []
      @lock.synchronize do
        @connections.each_value { |c| idle << c if c.idle }
      end
      i = 0
      while i < idle.size
        sock = idle[i].sock
        if !sock.closed? && sock.wait_readable(0).nil?
          begin
            sock.close
          rescue IOError
            # its own thread closed it first
          end
        end
        i += 1
      end
      nil
    end

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
    # Counted here, on the accept thread, so that once #run has joined it
    # the drain sees every connection; serve's ensure uncounts it.
    def spawn_connection(sock)
      conn = Connection.new(sock)
      @lock.synchronize do
        @open_count += 1
        @next_connection_id += 1
        conn.id = @next_connection_id
        @connections[conn.id] = conn
      end
      spawn_serve(sock, conn)
    end

    # A method of its own, so the block captures the two parameters (rule 21).
    def spawn_serve(sock, conn)
      Thread.new { serve(sock, conn) }
    end

    def connection_closed(conn)
      @lock.synchronize do
        @open_count -= 1
        @connections.delete(conn.id)
      end
      nil
    end

    # One connection: read a head, read its body, run the app, write the
    # response, and loop while the client keeps the connection alive.
    # Every readpartial is preceded by wait_readable (NOTES rule 20); a nil
    # wait means the client has been silent for read_timeout seconds.
    # Once the server is stopping, a connection idle between requests closes
    # (head_readable?) and a response ends the loop (respond answers
    # Connection: close).
    #
    # `while true` rather than `loop do`: inside a `loop` block Spinel drops
    # the ivars of a raised exception (Rejected#status reads 0) and skips
    # the value expression of `return value`.
    #
    # All framing is in bytes (byteindex/byteslice): Spinel slices a String
    # holding non-ASCII bytes by character, so `buf[i, n]` would take too many
    # bytes after a UTF-8 body and shift the next pipelined request.
    def serve(sock, conn)
      remote_addr = sock.peeraddr[3].to_s
      buf = +""
      while true
        idx = buf.byteindex(HttpParser::HEAD_END)
        while idx.nil?
          raise Rejected.new(400) if buf.bytesize > @max_head_bytes
          return unless head_readable?(sock, buf.empty?, conn)

          buf << sock.readpartial(READ_CHUNK)
          idx = buf.byteindex(HttpParser::HEAD_END)
        end
        raise Rejected.new(400) if idx > @max_head_bytes

        head = HttpParser.parse_head(buf.byteslice(0, idx))
        # Appended, not assigned (NOTES rule 60): `rest` is appended to in the
        # body loop below, which makes Spinel compile it as a growable buffer,
        # and a String ASSIGNED to such a buffer is copied with strlen, so the
        # body was cut at its first NUL byte (every gzip upload has one) and
        # the loop waited for bytes that had already arrived. `<<` copies by
        # the byte length.
        rest = +""
        rest << buf.byteslice(idx + 4, buf.bytesize - idx - 4)

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
      begin
        sock.close unless sock.closed?
      rescue IOError
        # the drain closed it between the check and the close
      end
      connection_closed(conn)
    end

    # Waits for more of a request head; false once the client has been silent
    # for read_timeout seconds. A connection with nothing buffered is idle
    # between requests: it is marked idle while it waits, in one park for the
    # whole read_timeout, so that the drain can close it when the server
    # stops (close_idle_connections). It used to wait in ACCEPT_POLL slices
    # to notice the stop itself, which cost a timer and a scheduler turn per
    # idle connection ten times a second (spinel-feedback.md, 4).
    def head_readable?(sock, idle, conn)
      return !sock.wait_readable(@read_timeout).nil? unless idle

      # marked first, then the flag read: a stop requested before the mark
      # is seen here, and one requested after it finds the mark
      conn.idle = true
      ready = @running && !sock.wait_readable(@read_timeout).nil?
      conn.idle = false
      ready
    end

    # Runs the app and writes its response; true when the connection stays
    # open, which it does not once the server is stopping.
    def respond(sock, request)
      response = handle(request)
      keep_alive = request.keep_alive? && @running
      response.set_header("Connection", keep_alive ? "keep-alive" : "close")
      sock.write(response.to_http(request.head?))
      keep_alive
    end

    # The handler's Response, or the error response for what it raised.
    def handle(request)
      @handler.call(request)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      # JSON::ParserError is not a StandardError under Spinel (NOTES rule
      # 33); named here so an action's bad JSON.parse is a 500 and not the
      # end of the connection thread. SystemStackError / NoMemoryError are
      # not named: nothing proves Spinel's exception table has them (a
      # stack overflow is a SIGSEGV there anyway); the depth limits in Query
      # and the template Interpreter are the guard against those.
      # ClientError maps and logs (a client's fault is its 4xx at info);
      # ErrorPages and Dev::ErrorPage ask it too, this is the bare-app path.
      error_response(ClientError.classify(e, @logger))
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
      response.reset_to(status)
      response
    end

    # Content-Length as an Integer: 0 when absent, -1 when it is not a plain
    # decimal number (including duplicated headers joined as "5, 5").
    # More than 18 significant digits is reported as just over max_body_bytes
    # (so 413) without calling to_i: Spinel's String#to_i raises RangeError
    # past 2**63-1 instead of saturating or promoting to Bignum.
    def body_length(value)
      return 0 if value.nil?
      return -1 if value.empty? || !HttpParser.digits?(value)

      first = 0
      first += 1 while first < value.bytesize - 1 && value.getbyte(first) == 48
      digits = value.bytesize - first
      return @max_body_bytes + 1 if digits > 18

      value.byteslice(first, digits).to_i
    end
  end
end
