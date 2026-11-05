# Cybertrain::Server end to end: a real TCPServer on an ephemeral port, driven
# by TCPSockets from the main thread. Only status lines, headers and bodies are
# printed or compared, never the port.
require "socket"
require "stringio"
require "cybertrain/context_handler"
require "cybertrain/http/server"
require "cybertrain/test"

# Dispatches on the path by hand so this test does not depend on the Router
# (a deviation from the plan's "tiny Router": Task 4 ships in the same wave,
# and a Router bug must not show up as a server failure).
class ServerTestApp < Cybertrain::Middleware
  def call(ctx)
    req = ctx.request
    res = ctx.response
    case req.path
    when "/hello"
      res.content_type = "text/plain"
      res.body = "hi"
    when "/echo"
      res.content_type = req.content_type
      res.body = req.body
    when "/boom"
      raise "kaboom"
    when "/reject"
      # what Query.parse raises past its limits (a bare app: no error pages)
      raise Cybertrain::QueryTooDeep, "nested too deeply (limit 32)"
    when "/json"
      # a StandardError under CRuby, not under Spinel (NOTES rule 33)
      raise JSON::ParserError, "unexpected token"
    when "/deep"
      # JSON::NestingError: what JSON.generate raises past 100 levels, which
      # a parsed document can reach (JSON.parse accepts 200). Under Spinel
      # `rescue JSON::ParserError` does not catch it (NOTES rule 61).
      res.content_type = "application/json"
      res.body = JSON.generate(ServerTestApp.deep(150))
    when "/slow"
      $slow_started = true
      sleep 1
      res.content_type = "text/plain"
      res.body = "slow done"
    else
      res.status = 404
      res.body = "Not Found"
    end
    nil
  end
end

# An Array nested n levels deep, for /deep.
def ServerTestApp.deep(n)
  outer = []
  cur = outer
  i = 0
  while i < n
    inner = []
    cur << inner
    cur = inner
    i += 1
  end
  outer
end

# A handler that never sees a Context or a Middleware: the Server needs only
# an HttpHandler.
class BareHandler < Cybertrain::HttpHandler
  def call(request)
    raise "bare boom" if request.path == "/boom"

    response = Cybertrain::Response.new
    response.content_type = "text/plain"
    response.body = "bare " + request.path
    response
  end
end

# What the test client read off the wire for one response.
class RawResponse
  attr_reader :status_line, :head, :body

  def initialize(status_line, head, body)
    @status_line = status_line
    @head = head
    @body = body
  end

  def header(name)
    wanted = name.downcase + ":"
    @head.split("\r\n").each do |line|
      return line[wanted.size, line.size - wanted.size].strip if line.downcase.start_with?(wanted)
    end
    ""
  end
end

# The main thread shares the scheduler with the server, so the client obeys
# the same rule as the server: wait_readable before every readpartial.
class RawClient
  def initialize(port)
    @sock = TCPSocket.new("127.0.0.1", port)
    @buf = +""
  end

  def send_raw(bytes)
    @sock.write(bytes)
  end

  def get(path, extra = "")
    send_raw("GET #{path} HTTP/1.1\r\nHost: test\r\n#{extra}\r\n")
    read_response(false)
  end

  # Byte offsets throughout: bodies may be multibyte UTF-8.
  def read_response(head_only)
    idx = @buf.byteindex("\r\n\r\n")
    while idx.nil?
      fill!
      idx = @buf.byteindex("\r\n\r\n")
    end
    head = @buf.byteslice(0, idx)
    @buf = @buf.byteslice(idx + 4, @buf.bytesize - idx - 4)
    res = RawResponse.new(head.split("\r\n")[0], head, "")
    length = head_only ? 0 : res.header("content-length").to_i
    fill! while @buf.bytesize < length
    body = @buf.byteslice(0, length)
    @buf = @buf.byteslice(length, @buf.bytesize - length)
    RawResponse.new(res.status_line, head, body)
  end

  # True once the server has closed its end (EOF with nothing left to read).
  def closed_by_server?
    return false unless @buf.empty?
    return false if @sock.wait_readable(5).nil?

    @sock.readpartial(4096)
    false
  rescue EOFError, Errno::ECONNRESET
    true
  end

  # True when nothing (not even EOF) arrives within `seconds`.
  def silent_for?(seconds)
    @buf.empty? && @sock.wait_readable(seconds).nil?
  end

  def close
    @sock.close unless @sock.closed?
  end

  private

  def fill!
    raise IOError, "timed out waiting for the server" if @sock.wait_readable(5).nil?

    @buf << @sock.readpartial(16384)
  end
end

# Set by /slow once the app has the request, so a test can stop the server
# while that request is in flight.
$slow_started = false

# Fails the first accept with EMFILE, as when descriptors run out, then
# accepts normally: the accept loop must log it and keep going.
$accept_failures = 1

class FlakyAcceptServer < Cybertrain::Server
  private

  def accept_client(listener)
    if $accept_failures > 0
      $accept_failures -= 1
      raise Errno::EMFILE, "Too many open files"
    end
    super
  end
end

$log = StringIO.new
$server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, read_timeout: 1,
                                 max_head_bytes: 1024, max_body_bytes: 64,
                                 logger: Cybertrain::Logger.new($log, :info))
$server.start

test "port 0 binds an ephemeral port" do
  assert $server.port > 0
  assert_equal "127.0.0.1", $server.host
end

test "two keep-alive requests on one socket get two responses" do
  c = RawClient.new($server.port)
  first = c.get("/hello")
  second = c.get("/missing")
  assert_equal "HTTP/1.1 200 OK", first.status_line
  assert_equal "hi", first.body
  assert_equal "keep-alive", first.header("connection")
  assert_equal "HTTP/1.1 404 Not Found", second.status_line
  assert_equal "Not Found", second.body
  assert c.silent_for?(0.2)
  c.close
end

test "pipelined requests are answered in order" do
  c = RawClient.new($server.port)
  c.send_raw("GET /hello HTTP/1.1\r\nHost: t\r\n\r\nGET /nope HTTP/1.1\r\nHost: t\r\n\r\n")
  assert_equal "HTTP/1.1 200 OK", c.read_response(false).status_line
  assert_equal "HTTP/1.1 404 Not Found", c.read_response(false).status_line
  c.close
end

test "Connection: close closes the socket after one response" do
  c = RawClient.new($server.port)
  res = c.get("/hello", "Connection: close\r\n")
  assert_equal "hi", res.body
  assert_equal "close", res.header("connection")
  assert c.closed_by_server?
  c.close
end

test "HTTP/1.0 without keep-alive closes after one response" do
  c = RawClient.new($server.port)
  c.send_raw("GET /hello HTTP/1.0\r\n\r\n")
  assert_equal "hi", c.read_response(false).body
  assert c.closed_by_server?
  c.close
end

test "HEAD returns headers with Content-Length and no body" do
  c = RawClient.new($server.port)
  c.send_raw("HEAD /hello HTTP/1.1\r\nHost: t\r\n\r\n")
  res = c.read_response(true)
  assert_equal "HTTP/1.1 200 OK", res.status_line
  assert_equal "2", res.header("content-length")
  assert_equal "", res.body
  # the next response starts right away: no stray body bytes in between
  assert_equal "hi", c.get("/hello").body
  c.close
end

test "every response the server writes carries the security defaults" do
  c = RawClient.new($server.port)
  ok = c.get("/hello")
  assert_equal "nosniff", ok.header("x-content-type-options")
  assert_equal "SAMEORIGIN", ok.header("x-frame-options")
  c.send_raw("HEAD /hello HTTP/1.1\r\nHost: t\r\n\r\n")
  head = c.read_response(true)
  assert_equal "nosniff", head.header("x-content-type-options")
  assert_equal "SAMEORIGIN", head.header("x-frame-options")
  missing = c.get("/nope")
  assert_equal "HTTP/1.1 404 Not Found", missing.status_line
  assert_equal "nosniff", missing.header("x-content-type-options")
  assert_equal "SAMEORIGIN", missing.header("x-frame-options")
  c.close
  # the Server's own answers: 400, 411, 413 (written by reject) and the 500
  # for an exception in the app
  [["NONSENSE\r\n\r\n", "400"],
   ["POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n", "411"],
   ["POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 65\r\n\r\n", "413"]].each do |raw, status|
    r = RawClient.new($server.port)
    r.send_raw(raw)
    res = r.read_response(false)
    assert_includes res.status_line, status
    assert_equal "nosniff", res.header("x-content-type-options")
    assert_equal "SAMEORIGIN", res.header("x-frame-options")
    r.close
  end
  b = RawClient.new($server.port)
  boom = b.get("/boom", "Connection: close\r\n")
  assert_equal "HTTP/1.1 500 Internal Server Error", boom.status_line
  assert_equal "nosniff", boom.header("x-content-type-options")
  assert_equal "SAMEORIGIN", boom.header("x-frame-options")
  b.close
end

test "POST with a Content-Length body is echoed back" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n")
  c.send_raw("{\"a\":\"hello\"}")
  res = c.read_response(false)
  assert_equal "HTTP/1.1 200 OK", res.status_line
  assert_equal "application/json", res.header("content-type")
  assert_equal "{\"a\":\"hello\"}", res.body
  c.close
end

test "malformed request line gets 400 and the connection closes" do
  c = RawClient.new($server.port)
  c.send_raw("NONSENSE\r\n\r\n")
  res = c.read_response(false)
  assert_equal "HTTP/1.1 400 Bad Request", res.status_line
  assert_equal "close", res.header("connection")
  assert c.closed_by_server?
  c.close
end

test "an oversized head gets 400 and the connection closes" do
  c = RawClient.new($server.port)
  c.send_raw("GET /hello HTTP/1.1\r\nX-Big: #{"a" * 2000}\r\n\r\n")
  assert_equal "HTTP/1.1 400 Bad Request", c.read_response(false).status_line
  assert c.closed_by_server?
  c.close
end

test "a body over max_body_bytes gets 413 and the connection closes" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 65\r\n\r\n")
  assert_equal "HTTP/1.1 413 Payload Too Large", c.read_response(false).status_line
  assert c.closed_by_server?
  c.close
end

test "a Content-Length too large for an Integer gets 413" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 99999999999999999999999999\r\n\r\n")
  assert_equal "HTTP/1.1 413 Payload Too Large", c.read_response(false).status_line
  assert c.closed_by_server?
  c.close
end

test "a zero-padded Content-Length is read as its value" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 00000000000000000000000002\r\n\r\nok")
  assert_equal "ok", c.read_response(false).body
  c.close
end

test "a head over max_head_bytes with no blank line yet gets 400" do
  c = RawClient.new($server.port)
  c.send_raw("GET /hello HTTP/1.1\r\nX-Big: #{"a" * 2000}")
  assert_equal "HTTP/1.1 400 Bad Request", c.read_response(false).status_line
  assert c.closed_by_server?
  c.close
end

test "a pipelined multibyte body is framed by bytes, not characters" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\n\r\nh\u00e9llo" \
             "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\n\r\nab")
  first = c.read_response(false)
  second = c.read_response(false)
  assert_equal "HTTP/1.1 200 OK", first.status_line
  # bytes, not String#==: CRuby reads the socket as ASCII-8BIT
  assert_equal "h\u00e9llo".bytes, first.body.bytes
  assert_equal "HTTP/1.1 200 OK", second.status_line
  assert_equal "ab", second.body
  c.close
end

test "a body with NUL bytes is framed by bytes, not cut at the NUL" do
  c = RawClient.new($server.port)
  # One write, so the server's first readpartial already holds body bytes
  # past a NUL (what every gzip upload carries), plus a pipelined request:
  # read in the body loop, the bytes were appended correctly even before the
  # fix in serve (NOTES rule 60); read with the head, they were cut.
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 9\r\n\r\nab\x00cd\x00\x00ef" \
             "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\n\r\nok")
  first = c.read_response(false)
  assert_equal "HTTP/1.1 200 OK", first.status_line
  assert_equal "9", first.header("content-length")
  assert_equal [97, 98, 0, 99, 100, 0, 0, 101, 102], first.body.bytes
  assert_equal "ok", c.read_response(false).body
  c.close
end

test "chunked transfer encoding gets 411 and the connection closes" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n")
  assert_equal "HTTP/1.1 411 Length Required", c.read_response(false).status_line
  assert c.closed_by_server?
  c.close
end

test "an invalid Content-Length gets 400" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 1x\r\n\r\n")
  assert_equal "HTTP/1.1 400 Bad Request", c.read_response(false).status_line
  assert c.closed_by_server?
  c.close
end

test "duplicate Content-Length headers get 400 and close the connection" do
  c = RawClient.new($server.port)
  c.send_raw("POST /echo HTTP/1.1\r\nContent-Length: 1\r\ncontent-length: 1\r\n\r\nx")
  assert_equal "HTTP/1.1 400 Bad Request", c.read_response(false).status_line
  assert c.closed_by_server?
  c.close
end

test "an exception in the app gets 500 and the connection stays usable" do
  c = RawClient.new($server.port)
  res = c.get("/boom")
  assert_equal "HTTP/1.1 500 Internal Server Error", res.status_line
  assert_equal "Internal Server Error", res.body
  assert_includes $log.string, "[ERROR] RuntimeError: kaboom"
  assert_equal "hi", c.get("/hello").body
  c.close
end

test "parameters past Query's limits get 400, not 500, and the connection stays usable" do
  c = RawClient.new($server.port)
  res = c.get("/reject")
  assert_equal "HTTP/1.1 400 Bad Request", res.status_line
  assert_equal "Bad Request", res.body
  assert_includes $log.string, "rejected request (400 Bad Request): nested too deeply (limit 32)"
  refute $log.string.include?("QueryTooDeep: nested"), "a rejected request is not an error-level log line"
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
end

test "a JSON::NestingError in the app gets 500, the connection is closed and the server keeps serving" do
  c = RawClient.new($server.port)
  res = c.get("/deep")
  assert_equal "HTTP/1.1 500 Internal Server Error", res.status_line
  assert_includes $log.string, "NestingError: nesting of 100 is too deep"
  c.close
  c2 = RawClient.new($server.port)
  assert_equal "hi", c2.get("/hello", "Connection: close\r\n").body
  c2.close
end

test "a JSON::ParserError in the app gets 500 and the server keeps serving" do
  c = RawClient.new($server.port)
  res = c.get("/json")
  assert_equal "HTTP/1.1 500 Internal Server Error", res.status_line
  # Spinel's class names carry no namespace ("ParserError"), CRuby's do.
  assert_includes $log.string, "ParserError: unexpected token"
  c.close
  c2 = RawClient.new($server.port)
  assert_equal "hi", c2.get("/hello", "Connection: close\r\n").body
  c2.close
end

test "an idle keep-alive connection is closed after read_timeout" do
  c = RawClient.new($server.port)
  assert_equal "hi", c.get("/hello").body
  assert c.closed_by_server?
  c.close
end

test "a failed accept is logged and the server keeps accepting" do
  server = FlakyAcceptServer.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  server.start
  c = RawClient.new(server.port)
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
  assert_includes $log.string, "[ERROR] accept failed: Errno::EMFILE"
  assert_equal 0, $accept_failures
  c = RawClient.new(server.port)
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
  server.stop
end

test "stop makes the port refuse connections" do
  port = $server.port
  $server.stop
  refused = false
  begin
    TCPSocket.new("127.0.0.1", port).close
  rescue Errno::ECONNREFUSED
    refused = true
  end
  assert refused, "expected the connection to be refused after stop"
end

test "serves a bare HttpHandler with no Context or Middleware involved" do
  server = Cybertrain::Server.new(BareHandler.new, port: 0, logger: Cybertrain::Logger.new($log, :info))
  server.start
  c = RawClient.new(server.port)
  assert_equal "bare /x", c.get("/x", "Connection: close\r\n").body
  c.close
  c = RawClient.new(server.port)
  assert_equal "HTTP/1.1 500 Internal Server Error", c.get("/boom", "Connection: close\r\n").status_line
  c.close
  server.stop
end

test "run serves until stop is called" do
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  runner = Thread.new { server.run }
  sleep 0.01 while server.port == 0
  c = RawClient.new(server.port)
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
  assert runner.alive?
  server.stop
  runner.join
  refute runner.alive?
end

test "request_stop (what the TERM trap calls) makes run return without joining" do
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  runner = Thread.new { server.run }
  sleep 0.01 while server.port == 0
  port = server.port
  c = RawClient.new(port)
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
  server.request_stop
  runner.join
  refute runner.alive?
  refused = false
  begin
    TCPSocket.new("127.0.0.1", port).close
  rescue Errno::ECONNREFUSED
    refused = true
  end
  assert refused, "expected the connection to be refused after request_stop"
end

# The client side of a graceful-shutdown test: the port refuses connections.
def port_refused?(port)
  TCPSocket.new("127.0.0.1", port).close
  false
rescue Errno::ECONNREFUSED
  true
end

test "request_stop waits for a request in flight and answers it completely" do
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  runner = Thread.new { server.run }
  sleep 0.01 while server.port == 0
  port = server.port
  c = RawClient.new(port)
  $slow_started = false
  c.send_raw("GET /slow HTTP/1.1\r\nHost: t\r\n\r\n")
  sleep 0.01 until $slow_started
  server.request_stop
  sleep 0.3
  # the listener is closed, but run is still draining the slow request
  assert port_refused?(port), "expected the connection to be refused while draining"
  assert runner.alive?
  assert_equal 1, server.open_connections
  res = c.read_response(false)
  assert_equal "HTTP/1.1 200 OK", res.status_line
  assert_equal "slow done", res.body
  assert_equal "close", res.header("connection")
  assert c.closed_by_server?
  c.close
  runner.join
  refute runner.alive?
  assert_equal 0, server.open_connections
end

test "an idle keep-alive connection does not hold up shutdown" do
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, read_timeout: 5, drain_timeout: 5.0,
                                                     logger: Cybertrain::Logger.new($log, :info))
  runner = Thread.new { server.run }
  sleep 0.01 while server.port == 0
  c = RawClient.new(server.port)
  assert_equal "keep-alive", c.get("/hello").header("connection")
  started = Time.now
  server.request_stop
  runner.join
  elapsed = Time.now - started
  assert elapsed < 1.0, "run took #{elapsed}s to return with one idle connection"
  assert c.closed_by_server?
  assert_equal 0, server.open_connections
  c.close
end

test "many idle keep-alive connections are closed by the drain, not waited out" do
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, read_timeout: 30, drain_timeout: 5.0,
                                                     logger: Cybertrain::Logger.new($log, :info))
  runner = Thread.new { server.run }
  sleep 0.01 while server.port == 0
  clients = []
  i = 0
  while i < 20
    c = RawClient.new(server.port)
    assert_equal "keep-alive", c.get("/hello").header("connection")
    clients << c
    i += 1
  end
  assert_equal 20, server.open_connections
  started = Time.now
  server.request_stop
  runner.join
  elapsed = Time.now - started
  assert elapsed < 1.0, "run took #{elapsed}s to return with 20 idle connections"
  assert_equal 0, server.open_connections
  i = 0
  while i < clients.size
    assert clients[i].closed_by_server?
    clients[i].close
    i += 1
  end
end

test "drain_timeout bounds the wait for a request that takes too long" do
  log = StringIO.new
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, drain_timeout: 0.3,
                                                     logger: Cybertrain::Logger.new(log, :info))
  runner = Thread.new { server.run }
  sleep 0.01 while server.port == 0
  c = RawClient.new(server.port)
  $slow_started = false
  c.send_raw("GET /slow HTTP/1.1\r\nHost: t\r\n\r\n")
  sleep 0.01 until $slow_started
  started = Time.now
  server.request_stop
  runner.join
  elapsed = Time.now - started
  assert elapsed < 0.9, "run took #{elapsed}s with drain_timeout 0.3"
  assert_includes log.string, "[WARN] shutting down with 1 connection(s) still open"
  # the request still completes on its own thread; wait for it so its
  # response does not outlive the test
  assert_equal "slow done", c.read_response(false).body
  c.close
end

test "start raises Cybertrain::PortInUse when the port is already bound" do
  first = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  first.start
  port = first.port
  second = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: port, logger: Cybertrain::Logger.new($log, :info))
  message = assert_raises("Cybertrain::PortInUse") { second.start }
  assert_equal "port #{port} on 127.0.0.1 is already in use (stop the other server or set PORT)", message
  assert_equal port, second.port
  # the first server is unaffected
  c = RawClient.new(port)
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
  first.stop
end

test "PortInUse names the reason the port could not be bound" do
  denied = Cybertrain::PortInUse.new("127.0.0.1", 80, Cybertrain::PortInUse::PERMISSION_DENIED)
  assert_equal "port 80 on 127.0.0.1 cannot be bound: permission denied (ports below 1024 need root or a capability)", denied.message
  assert_equal 80, denied.port
  busy = Cybertrain::PortInUse.new("127.0.0.1", 3000)
  assert_equal "port 3000 on 127.0.0.1 is already in use (stop the other server or set PORT)", busy.message
end

# Exercises the real, compiled bind path (not a hand-built PortInUse): under
# Spinel, TCPServer.new on port 80 without root raises Errno::ECONNREFUSED,
# the same exception a busy port raises, so this is the only way to catch a
# regression where bind_listener's privileged_denied? stops reclassifying it
# and the operator sees "already in use" for a port that was never in use.
#
# spin test captures the program's stdout AND stderr (2>&1) and diffs them
# against the snapshot, so a skip line on either stream breaks the run. The
# two skip branches (root, or port 80 already taken) therefore write their
# reason to $log (the test's StringIO) and make two placeholder assertions,
# the number the real path makes, so the "N tests, M assertions" summary is
# byte-identical on every path.
test "starting a server on port 80 as non-root reports permission denied" do
  if Process.uid == 0
    $log.puts "skip: port 80 permission test needs a non-root user (running as root)"
    assert_equal 0, Process.uid
    # what Server#privileged_denied? computes for root: not a permission problem
    assert_equal false, (80 < 1024 && Process.uid != 0)
  else
    listening = true
    begin
      probe = TCPSocket.new("127.0.0.1", 80)
      probe.close
    rescue StandardError
      listening = false
    end
    if listening
      $log.puts "skip: port 80 permission test needs the port free (something is already listening on 80)"
      assert listening, "probe connected to 127.0.0.1:80"
      assert_equal 0, $log.string.index("skip: port 80 permission test needs the port free").to_i
    else
      priv_server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), host: "127.0.0.1", port: 80,
                                                               logger: Cybertrain::Logger.new($log, :info))
      message = assert_raises("Cybertrain::PortInUse") { priv_server.start }
      assert_equal "port 80 on 127.0.0.1 cannot be bound: permission denied (ports below 1024 need root or a capability)", message
    end
  end
end

# Answers with its tag and counts what it answered, so a test can tell which
# of two servers on one port took a connection.
class TaggedHandler < Cybertrain::HttpHandler
  attr_reader :hits

  def initialize(tag)
    @tag = tag
    @hits = 0
  end

  def call(request)
    @hits += 1
    response = Cybertrain::Response.new
    response.content_type = "text/plain"
    response.body = @tag
    response
  end
end

def reuse_port_server(handler, host, port)
  Cybertrain::Server.new(handler, host: host, port: port, reuse_port: true, logger: Cybertrain::Logger.new($log, :info))
end

def reuse_port_get(port)
  c = RawClient.new(port)
  res = c.get("/", "Connection: close\r\n")
  c.close
  res
end

# The kernel's split is Linux's: macOS binds both and gives every connection
# to one of them, so there the test only asserts that one answered (the same
# number of assertions on either path, for the snapshot). The throughput is
# measured in docs/design.md D35.
test "reuse_port lets two servers bind one port and both answer" do
  first = TaggedHandler.new("first")
  second = TaggedHandler.new("second")
  a = reuse_port_server(first, "127.0.0.1", 0)
  a.start
  b = reuse_port_server(second, "127.0.0.1", a.port)
  b.start
  assert_equal a.port, b.port
  assert a.reuse_port
  assert_equal "HTTP/1.1 200 OK", reuse_port_get(a.port).status_line
  i = 0
  while i < 500 && (first.hits == 0 || second.hits == 0)
    reuse_port_get(a.port)
    i += 1
  end
  if RUBY_PLATFORM.include?("linux")
    assert first.hits > 0 && second.hits > 0, "first #{first.hits}, second #{second.hits} after #{i} connections"
  else
    assert first.hits + second.hits > 0
  end
  # one of them stopping leaves the other on the port
  b.stop
  assert_equal "first", reuse_port_get(a.port).body
  a.stop
end

# In a method of its own so the Server is garbage by the time the test runs
# the collector.
def reuse_port_started_and_stopped
  server = reuse_port_server(TaggedHandler.new("a"), "127.0.0.1", 0)
  server.start
  server.stop
  server.port
end

test "reuse_port survives stop: the port binds again and the collector leaves the number alone" do
  port = reuse_port_started_and_stopped
  # The stopped listener's number is free now, so these take it. A second
  # close of that number, now or by the collector, would end this pipe.
  r, w = IO.pipe
  GC.start
  w.write("alive")
  assert_equal "alive", r.readpartial(16)
  w.close
  r.close
  b = reuse_port_server(TaggedHandler.new("b"), "127.0.0.1", port)
  b.start
  res = reuse_port_get(port)
  assert_equal "HTTP/1.1 200 OK", res.status_line
  assert_equal "b", res.body
  b.stop
  # a plain server takes the port once the reuse_port ones are gone
  plain = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: port, logger: Cybertrain::Logger.new($log, :info))
  plain.start
  plain.stop
end

test "a plain listener on the port still raises PortInUse for reuse_port" do
  plain = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  plain.start
  port = plain.port
  blocked = reuse_port_server(TaggedHandler.new("blocked"), "127.0.0.1", port)
  message = assert_raises("Cybertrain::PortInUse") { blocked.start }
  assert_equal "port #{port} on 127.0.0.1 #{Cybertrain::PortInUse::IN_USE}", message
  plain.stop
end

test "a reuse_port listener on the port still raises PortInUse for a plain server" do
  held = reuse_port_server(TaggedHandler.new("held"), "127.0.0.1", 0)
  held.start
  port = held.port
  plain = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: port, logger: Cybertrain::Logger.new($log, :info))
  message = assert_raises("Cybertrain::PortInUse") { plain.start }
  assert_equal "port #{port} on 127.0.0.1 #{Cybertrain::PortInUse::IN_USE}", message
  held.stop
end

def localhost_addresses
  addresses = []
  Socket.getaddrinfo("localhost", 0, nil, Socket::SOCK_STREAM).each do |_family_name, _port, _name, address, _family, _socktype, _protocol|
    text = address.to_s
    addresses << text unless addresses.include?(text)
  end
  addresses
end

# A plain TCPServer takes the first address of such a name and moves to the
# next when that one is busy, so processes on it would not refuse each other.
# localhost has both families on macOS and in the Linux container, not
# everywhere: with only one it binds (the same number of assertions on either
# path, for the snapshot).
test "reuse_port stops on a name with several addresses and binds a name with one" do
  server = reuse_port_server(TaggedHandler.new("named"), "localhost", 0)
  if localhost_addresses.size > 1
    message = assert_raises("Cybertrain::PortInUse") { server.start }
    assert_equal "port 0 on localhost #{Cybertrain::PortInUse::REUSE_PORT_NAME}", message
    assert_includes message, "reuse_port"
  else
    server.start
    assert server.reuse_port
    assert server.port > 0
    assert_equal "named", reuse_port_get(server.port).body
    server.stop
  end
end

# Whether the machine has ::1 at all varies (a container often does not):
# what must not happen is a bind to some other address.
def ipv6_reuse_port_outcome
  server = reuse_port_server(TaggedHandler.new("six"), "::1", 0)
  server.start
  sock = TCPSocket.new("::1", server.port)
  sock.close
  server.stop
  "answered"
rescue Cybertrain::PortInUse => e
  e.message
end

test "reuse_port on an IPv6 literal binds it or says why not" do
  outcome = ipv6_reuse_port_outcome
  assert outcome == "answered" || outcome.include?("reuse_port"), outcome
end

test "reuse_port on a host that does not resolve stops with a message naming the setting" do
  server = reuse_port_server(TaggedHandler.new("nowhere"), "no-such-host.invalid", 3000)
  message = assert_raises("Cybertrain::PortInUse") { server.start }
  assert_equal "port 3000 on no-such-host.invalid #{Cybertrain::PortInUse::REUSE_PORT_HOST}", message
  assert_includes message, "reuse_port"
end

test "reuse_port on an address this machine does not have stops with the same message" do
  server = reuse_port_server(TaggedHandler.new("elsewhere"), "192.0.2.1", 3000)
  message = assert_raises("Cybertrain::PortInUse") { server.start }
  assert_equal "port 3000 on 192.0.2.1 #{Cybertrain::PortInUse::REUSE_PORT_HOST}", message
end

test "reuse_port is off unless asked for" do
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  refute server.reuse_port
end

Cybertrain::Test.run!
