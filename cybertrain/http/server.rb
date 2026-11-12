require "socket"
require "json"
require "cybertrain/http/parser"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/handler"
require "cybertrain/http/body_writer"
require "cybertrain/http/client_error"
require "cybertrain/logger"

module Cybertrain
  # Raised by Server#start when the listener cannot bind: another process
  # holds the port (EADDRINUSE, or under Spinel a busy privileged port's
  # ECONNREFUSED) or the port is privileged and out of reach (CRuby's EACCES,
  # or under Spinel the same ECONNREFUSED reclassified by bind_listener's
  # privileged_denied? since the exception class alone cannot tell the two
  # apart there) -- its own reason so the operator does not hunt for a
  # process that is not there. With reuse_port a host that does not resolve
  # or is not this machine's is a third reason and a name with several
  # addresses a fourth, both naming the setting; with listen_fd, a
  # descriptor that is not a listening socket is a fifth. The message is what
  # Application#serve prints before exiting.
  class PortInUse < StandardError
    attr_reader :port

    IN_USE = "is already in use (stop the other server or set PORT)"
    PERMISSION_DENIED = "cannot be bound: permission denied (ports below 1024 need root or a capability)"
    REUSE_PORT_HOST = "cannot be bound with reuse_port: the host is not an address of this machine (check CYBERTRAIN_HOST)"
    REUSE_PORT_NAME = "cannot be bound with reuse_port: the host names several addresses (set CYBERTRAIN_HOST to one of them)"
    NOT_LISTENING = "cannot be served: the inherited descriptor is not a listening socket"

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
  #
  # reuse_port: true binds with SO_REUSEPORT, so several processes can listen
  # on one port and, on Linux, the kernel splits connections between them
  # (docs/design.md D35). Off, a second server on the port raises PortInUse.
  class Server
    # One open connection, as the drain sees it: its socket, and whether its
    # thread is waiting for the next request on it (idle). The flag is
    # written by the connection's own thread without a lock (no lock per
    # request, NOTES rule 57); the drain only reads it. A connection it
    # misses is caught on its next pass, and one it reads late is harmless
    # because the drain shuts only the read side.
    class Connection
      attr_reader :sock
      attr_accessor :id, :idle, :streaming

      def initialize(sock)
        @id = 0
        @sock = sock
        @idle = false
        # Set while a BodyWriter runs on it: the drain shuts its read side
        # so the writer sees the end (Sink#closed?) and returns.
        @streaming = false
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
    # next request for up to read_timeout, and the drain ends that wait.
    ACCEPT_POLL = 0.1

    # port is the bound port once #start has run (the ephemeral one with port: 0;
    # the configured one with listen_fd).
    attr_reader :host, :port, :reuse_port

    # listen_fd: a listening descriptor this process inherited (a
    # supervisor's, in development), listened on instead of binding host and
    # port; -1, the default, binds. The HTTP layer takes the number only:
    # deciding whether to use one is the caller's.
    # drain_timeout bounds how long #run and #stop wait for requests in
    # flight; keep it below the process manager's stop timeout (systemd's
    # TimeoutStopSec, 15 s in docs/deploy.md).
    # stream_write_timeout: how long one write of a streaming response may
    # wait for a client that does not read (Sink); Application passes
    # Config#stream_ping_interval.
    def initialize(handler, host: "127.0.0.1", port: 3000, read_timeout: 15, drain_timeout: 10.0,
                   max_head_bytes: 65536, max_body_bytes: 10_485_760, logger: Cybertrain.logger,
                   reuse_port: false,
                   stream_write_timeout: 15, listen_fd: -1)
      @handler = handler
      @listen_fd = listen_fd
      @stream_write_timeout = stream_write_timeout
      @host = host
      @port = port
      @reuse_port = reuse_port
      @reuse_socket = nil
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
    # Raises PortInUse when the port cannot be bound. With listen_fd the
    # inherited listener is already bound and listening, and port stays the
    # configured one.
    def start
      # spikes/NOTES.md rule 22: one worker is faster for an I/O-bound server.
      # It must be set before the first Thread.new starts the scheduler.
      ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
      listener = bind_listener
      if @listen_fd < 0
        listener.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
        @port = listener.addr[1]
      end
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
    # drains, which ends the idle connections. Spinel runs a trap block straight from its C
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
    #
    # An inherited listener is not bound here at all: inherited_listener
    # takes it over by number.
    def bind_listener
      return inherited_listener if @listen_fd >= 0

      @reuse_port ? reuse_port_listener : TCPServer.new(@host, @port)
    rescue Errno::EACCES
      raise PortInUse.new(@host, @port, PortInUse::PERMISSION_DENIED)
    rescue Errno::EADDRINUSE, Errno::ECONNREFUSED
      reason = privileged_denied? ? PortInUse::PERMISSION_DENIED : PortInUse::IN_USE
      raise PortInUse.new(@host, @port, reason)
    end

    def privileged_denied?
      @port < 1024 && Process.uid != 0
    end

    # TCPServer.new has no option for SO_REUSEPORT, which must be set before
    # bind, so the socket is built by hand and handed over by number. The
    # TCPServer then owns the descriptor and accept_loop closes it. The Socket
    # holds the same number: under Spinel and CRuby alike closing it as well
    # (or collecting it with autoclose on) would close whatever has reused
    # the number since, such as a connection, so autoclose goes off and the
    # Socket is only kept alive, never closed.
    def reuse_port_listener
      sock = reuse_port_socket
      sock.autoclose = false
      @reuse_socket = sock
      TCPServer.for_fd(sock.fileno)
    end

    # The descriptor a supervisor handed down, already bound and listening.
    # The same single-owner rule as reuse_port_listener: the TCPServer made
    # here owns the number in this process and accept_loop closes it; the
    # supervisor keeps its own copy open in its own process, so the port
    # stays bound for the next child.
    #
    # A number that is not open, not a socket, or a socket that does not
    # listen is PortInUse::NOT_LISTENING, not an Errno nor an accept loop
    # that fails forever. CRuby's for_fd refuses a non-socket (EBADF);
    # Spinel's refuses a closed number (EBADF) and one its fdopen cannot
    # open read-write (IOError, "fdopen failed": a read-only file, a pipe)
    # but takes any other, so accepting? decides the rest. Until the check
    # passes autoclose is off: a refused number is not this server's, and
    # the collector must not close what something else holds.
    def inherited_listener
      listener = TCPServer.for_fd(@listen_fd)
      listener.autoclose = false
      raise PortInUse.new(@host, @port, PortInUse::NOT_LISTENING) unless accepting?(listener)

      listener.autoclose = true
      listener
    rescue SystemCallError, IOError
      raise PortInUse.new(@host, @port, PortInUse::NOT_LISTENING)
    end

    # Whether the socket listens: SO_ACCEPTCONN is positive only then. A
    # listening socket answers 1 on Linux and the option's own bit (2) on
    # macOS, one that does not listen 0. For a descriptor that is not a
    # socket CRuby raises ENOTSOCK, but Spinel's getsockopt answers -1
    # instead of raising, so "non-zero" would take a read-write file for a
    # listener and accept_loop would fail on it forever. Only a positive
    # answer passes, so any failed read of the option refuses the number:
    # at worst a listener is refused at boot, never a non-listener served.
    def accepting?(listener)
      listener.getsockopt(Socket::SOL_SOCKET, Socket::SO_ACCEPTCONN).int > 0
    end

    # A separate method so its rescue stays away from the raw socket calls'
    # own (EADDRINUSE and EACCES go on to bind_listener). A host without this
    # address, or without IPv6 at all, is the setting's fault, not a busy port.
    def reuse_port_socket
      ip = reuse_port_ip
      family = ip.include?(":") ? Socket::AF_INET6 : Socket::AF_INET
      bind_reuse_port(Socket.new(family, Socket::SOCK_STREAM, 0), Socket.sockaddr_in(@port, ip))
    rescue Errno::EADDRNOTAVAIL, Errno::EAFNOSUPPORT
      raise PortInUse.new(@host, @port, PortInUse::REUSE_PORT_HOST)
    end

    def bind_reuse_port(sock, sockaddr)
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1)
      sock.bind(sockaddr)
      sock.listen(1024)
      sock
    rescue SystemCallError
      sock.close
      raise
    end

    # The one address @host names. A name with several stops the boot: a plain
    # TCPServer takes the first and moves to the next when that one is busy,
    # so whichever this bound, a process without reuse_port would boot on an
    # address left over instead of being refused (design.md D35).
    def reuse_port_ip
      ips = []
      Socket.getaddrinfo(@host, @port, nil, Socket::SOCK_STREAM).each do |_family_name, _port, _name, address, _family, _socktype, _protocol|
        text = address.to_s
        ips << text unless ips.include?(text)
      end
      raise PortInUse.new(@host, @port, PortInUse::REUSE_PORT_HOST) if ips.empty?
      raise PortInUse.new(@host, @port, PortInUse::REUSE_PORT_NAME) if ips.size > 1

      ips[0]
    rescue SocketError
      raise PortInUse.new(@host, @port, PortInUse::REUSE_PORT_HOST)
    end

    # Waits, in ordinary thread context, until every connection has closed
    # or drain_timeout seconds have passed. Whatever is still open then is
    # cut off when the process exits. Each pass shuts the read side of the
    # connections that are waiting for a next request; one busy with a
    # request answers it with Connection: close (respond) and ends.
    def drain
      started = Time.now
      shut_idle_connections
      remaining = open_connections
      while remaining > 0
        if Time.now - started >= @drain_timeout
          @logger.warn("shutting down with #{remaining} connection(s) still open after #{@drain_timeout}s")
          break
        end
        sleep ACCEPT_POLL
        shut_idle_connections
        remaining = open_connections
      end
      nil
    end

    # Ends the wait of every connection whose thread is waiting for its next
    # request and has nothing to read yet, by shutting the socket's read
    # side: the parked wait_readable wakes at once (CRuby and Spinel alike),
    # the read that follows sees EOF, and serve ends quietly and closes the
    # socket itself. Only the read side, because the snapshot can be stale:
    # a connection that left its wait after the snapshot and has already
    # read its next request still writes the whole response (with
    # Connection: close, since the server is stopping) before it ends. A
    # connection whose next request has arrived is left to read it. Every
    # step tolerates the connection's own thread closing the socket first.
    def shut_idle_connections
      idle = []
      @lock.synchronize do
        @connections.each_value { |c| idle << c if c.idle || c.streaming }
      end
      i = 0
      while i < idle.size
        conn = idle[i]
        sock = conn.sock
        begin
          # A streaming response's read side is shut whatever is waiting:
          # its writer looks at Sink#wait_closed (SSE) or reads frames
          # (WebSocket), sees EOF and ends the stream.
          if !sock.closed? && (conn.streaming || (conn.idle && sock.wait_readable(0).nil?))
            sock.shutdown(Socket::SHUT_RD)
          end
        rescue IOError, SystemCallError
          # closed by its own thread, or the peer is already gone
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
        break unless respond(sock, request, conn)
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
      connection_closed(conn)
    end

    # Waits for more of a request head; false once the client has been silent
    # for read_timeout seconds. A connection with nothing buffered is idle
    # between requests: it is marked idle while it waits, in one park for the
    # whole read_timeout, so that the drain can end that wait when the
    # server stops (shut_idle_connections). It used to wait in ACCEPT_POLL slices
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
    # open, which it does not once the server is stopping, nor after a
    # streaming response.
    def respond(sock, request, conn)
      response = handle(request)
      writer = response.body_writer
      return respond_streaming(sock, request, response, writer, conn) unless writer.nil?

      keep_alive = request.keep_alive? && @running
      response.set_header("Connection", keep_alive ? "keep-alive" : "close")
      sock.write(response.to_http(request.head?))
      keep_alive
    end

    # A streaming response (docs/design.md D36): the head with
    # `Transfer-Encoding: chunked` (HTTP/1.1) or no framing (HTTP/1.0, and
    # a 101 upgrade), then the writer on this thread, then the terminating
    # chunk; always false, so serve closes the connection. A HEAD request
    # gets the head only. What the writer raises is logged and ends the
    # connection without the terminator: nothing can be sent at that point.
    def respond_streaming(sock, request, response, writer, conn)
      upgrade = response.upgrade?
      response.set_header("Connection", upgrade ? "Upgrade" : "close")
      if request.head?
        sock.write(response.to_http_head(false))
        return false
      end
      chunked = !upgrade && request.http_version == "HTTP/1.1"
      sock.write(response.to_http_head(chunked))
      sink = Sink.new(sock, chunked, @stream_write_timeout)
      Server.keep_alive_probes(sock)
      conn.streaming = true
      sink.sink_finish if run_writer(writer, sink)
      false
    end

    # TCP keep-alive on a streaming connection, best effort: a peer that
    # vanished without a FIN or RST is then found by the kernel's probes
    # (its timing, not ours), besides a write that times out (Sink).
    # Integer socket options work under Spinel (SO_REUSEADDR above).
    def self.keep_alive_probes(sock)
      sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE, 1)
      nil
    rescue IOError, SystemCallError
      nil
    end

    # The writer with its rescue, in a plain method (spikes/NOTES.md rules
    # 32/45); JSON::NestingError named first (rule 61). False when it raised.
    def run_writer(writer, sink)
      writer.write_body(sink)
      true
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      @logger.error("stream error: #{e.class.name}: #{e.message}")
      sink.sink_close!
      false
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
