# Cybertrain::Server end to end: a real TCPServer on an ephemeral port, driven
# by TCPSockets from the main thread. Only status lines, headers and bodies are
# printed or compared, never the port.
require "socket"
require "stringio"
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
    else
      res.status = 404
      res.body = "Not Found"
    end
    nil
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
$server = Cybertrain::Server.new(ServerTestApp.new, port: 0, read_timeout: 1,
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

test "an exception in the app gets 500 and the connection stays usable" do
  c = RawClient.new($server.port)
  res = c.get("/boom")
  assert_equal "HTTP/1.1 500 Internal Server Error", res.status_line
  assert_equal "Internal Server Error", res.body
  assert_includes $log.string, "[ERROR] RuntimeError: kaboom"
  assert_equal "hi", c.get("/hello").body
  c.close
end

test "an idle keep-alive connection is closed after read_timeout" do
  c = RawClient.new($server.port)
  assert_equal "hi", c.get("/hello").body
  assert c.closed_by_server?
  c.close
end

test "a failed accept is logged and the server keeps accepting" do
  server = FlakyAcceptServer.new(ServerTestApp.new, port: 0, logger: Cybertrain::Logger.new($log, :info))
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

test "run serves until stop is called" do
  server = Cybertrain::Server.new(ServerTestApp.new, port: 0, logger: Cybertrain::Logger.new($log, :info))
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

Cybertrain::Test.run!
