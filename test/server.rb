# Cybertrain::Server (spinel-http's SpinelHttp::Server) end to end with
# cybertrain around it: ContextHandler, RequestId, the Logger's scopes and
# the error reporter. The server's own cases are spinel-http's (its
# test/server.rb). A real TCPServer on an ephemeral port, driven by
# TCPSockets from the main thread. Only status lines, headers and bodies are
# printed or compared, never the port.
require "socket"
require "stringio"
require "cybertrain/context_handler"
require "cybertrain/http/server"
require "cybertrain/middleware/request_id"
require "cybertrain/test"
require_relative "support/log_capture"

# Dispatches on the path by hand so this test does not depend on the Router
# (a Router bug must not show up as a server failure).
class ServerTestApp < Cybertrain::Middleware
  def call(ctx)
    req = ctx.request
    res = ctx.response
    case req.path
    when "/hello"
      res.content_type = "text/plain"
      res.body = "hi"
    when "/boom"
      raise "kaboom"
    when "/reject"
      # what Query.parse raises past its limits (a bare app: no error pages)
      raise Cybertrain::QueryTooDeep, "nested too deeply (limit 32)"
    when "/stream"
      res.body_writer = LoggingWriter.new(false)
    when "/stream_boom"
      res.body_writer = LoggingWriter.new(true)
    when "/stream_gone"
      res.body_writer = GoneWriter.new(req.query_string)
    when "/upgrade_boom"
      res.set_header("Upgrade", "websocket")
      res.upgrade!(BrokenUpgrade.new)
    when "/upgrade"
      # A 101 answer, as the WebSocket handshake gives one.
      res.set_header("Upgrade", "websocket")
      res.upgrade!(LoggingWriter.new(false))
    else
      res.status = 404
      res.body = "Not Found"
    end
    nil
  end
end

# The log the streaming writer and its server write into, and the request
# id the writer saw on its thread's Scope while it wrote.
$stream_log = StringIO.new
$stream_logger = Cybertrain::Logger.new($stream_log, :info)
$stream_seen = ""

# A streamed body (/stream, /stream_boom) that logs a line and reads the
# thread's Scope while the Server writes it, after the stack has returned.
class LoggingWriter < Cybertrain::BodyWriter
  def initialize(fail)
    @fail = fail
  end

  def write_body(sink)
    $stream_logger.info("streaming")
    $stream_seen = Cybertrain::Logger.current_scope.scope_request_id
    raise "stream broke" if @fail

    sink.write("streamed")
    nil
  end
end

# An upgraded connection (/upgrade_boom) whose writer raises.
class BrokenUpgrade < Cybertrain::BodyWriter
  def write_body(sink)
    raise ArgumentError, "upgrade broke"
  end
end

# A streamed body (/stream_gone?<n>) whose client went away: it raises
# what a write or read on a closed peer raises (n: 0 EPIPE, 1 ECONNRESET,
# 2 EOFError, 3 IOError), which is logged and not reported.
class GoneWriter < Cybertrain::BodyWriter
  def initialize(which)
    @which = which
  end

  def write_body(sink)
    raise Errno::EPIPE, "gone" if @which == "0"
    raise Errno::ECONNRESET, "gone" if @which == "1"
    raise EOFError, "gone" if @which == "2"

    raise IOError, "gone"
  end
end

# What the reporter delivered while a test of streams ran (a constant:
# NOTES rule 64).
def blank_event
  Cybertrain::ErrorEvent.new("", "", "", "", "", "", "", "", false, Cybertrain::ErrorReporter.empty_context,
                             Array.new(0) { "" }, Time.at(0).utc)
end

STREAM_EVENTS = Array.new(0) { blank_event }

class StreamEvents < Cybertrain::ErrorSubscriber
  def report(event)
    STREAM_EVENTS << event
    nil
  end
end

Cybertrain.error.subscribe(StreamEvents.new)

# The events delivered so far whose message is `message`.
def stream_events(message)
  Cybertrain.error.drain_reports(2.0)
  found = Array.new(0) { blank_event }
  STREAM_EVENTS.each { |ev| found << ev if ev.error_message == message }
  found
end

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
  def initialize(port, host = "127.0.0.1")
    @sock = TCPSocket.new(host, port)
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

  # Everything the server sends until it closes the connection.
  def read_to_close
    loop do
      break if @sock.wait_readable(5).nil?

      begin
        @buf << @sock.readpartial(16384)
      rescue EOFError, Errno::ECONNRESET
        break
      end
    end
    @buf
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

# Whether the connection thread was back on Logger::NO_SCOPE once a
# streamed or upgraded writer had run, one entry per writer.
$after_writer_no_scope = Array.new(0) { false }

class ScopeAfterWriterServer < Cybertrain::Server
  private

  def run_writer_scoped(writer, sink, scope)
    ok = super
    $after_writer_no_scope << Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
    ok
  end
end

$log = StringIO.new
$server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, read_timeout: 1,
                                 max_head_bytes: 1024, max_body_bytes: 64,
                                 logger: Cybertrain::Logger.new($log, :info))
$server.start

# ---- protocol boundaries the server takes a position on (docs/http-contract.md) ----

test "HTTP/1.1 without a Host header is served: the host is HostAuthorization's to check" do
  c = RawClient.new($server.port)
  c.send_raw("GET /hello HTTP/1.1\r\n\r\n")
  assert_equal "hi", c.read_response(false).body
  c.close
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

test "the bare path's 500 carries the id a RequestId set; a handler without one sends none" do
  app = Cybertrain::RequestId.new(ServerTestApp.new, [:request_id])
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(app), port: 0, logger: Cybertrain::Logger.new($log, :info))
  server.start
  c = RawClient.new(server.port)
  ok = c.get("/hello")
  assert_equal "hi", ok.body
  assert LogCapture.uuid?(ok.header("x-request-id")), ok.head
  boom = c.get("/boom", "Connection: close\r\n")
  assert_equal "HTTP/1.1 500 Internal Server Error", boom.status_line
  assert LogCapture.uuid?(boom.header("x-request-id")), boom.head
  refute boom.header("x-request-id") == ok.header("x-request-id")
  c.close
  server.stop
  bare = Cybertrain::Server.new(BareHandler.new, port: 0, logger: Cybertrain::Logger.new($log, :info))
  bare.start
  c = RawClient.new(bare.port)
  res = c.get("/boom", "Connection: close\r\n")
  assert_equal "HTTP/1.1 500 Internal Server Error", res.status_line
  assert_equal "", res.header("x-request-id")
  c.close
  bare.stop
end

# Records, before the stack below it runs, whether the connection thread
# is on Logger::NO_SCOPE: outside RequestId, so it sees what the previous
# request on the same keep-alive connection left behind.
$probe_no_scope = Array.new(0) { false }

class ScopeProbe < Cybertrain::Middleware
  def call(ctx)
    $probe_no_scope << Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
    nxt = @app
    nxt.call(ctx) unless nxt.nil?
    nil
  end
end

# Runs the block with JSON log lines on, and text lines back after it,
# also when it raises.
def server_json_lines
  Cybertrain::Logger.json_lines = true
  yield
  nil
ensure
  Cybertrain::Logger.json_lines = false
end

# A 500 and a 4xx on the bare path (no ErrorPages, no Dev::ErrorPage),
# then a request on the same connection, through ScopeProbe; answers the
# log and the two ids.
def bare_path_lines
  log = StringIO.new
  $probe_no_scope = Array.new(0) { false }
  app = ScopeProbe.new(Cybertrain::RequestId.new(ServerTestApp.new, [:request_id]))
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(app), port: 0, logger: Cybertrain::Logger.new(log, :info))
  server.start
  c = RawClient.new(server.port)
  boom = c.get("/boom")
  assert_equal "HTTP/1.1 500 Internal Server Error", boom.status_line
  rejected = c.get("/reject")
  assert_equal "HTTP/1.1 400 Bad Request", rejected.status_line
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
  server.stop
  [log.string, boom.header("x-request-id"), rejected.header("x-request-id")]
end

test "the bare path's 500 and 4xx lines carry the request's id; the thread is back on NO_SCOPE after each" do
  log, boom_id, rejected_id = bare_path_lines
  assert LogCapture.uuid?(boom_id), log
  assert LogCapture.uuid?(rejected_id), log
  assert_includes log, " ERROR [#{boom_id}] RuntimeError: kaboom\n"
  assert_includes log, " INFO [#{rejected_id}] rejected request (400 Bad Request): nested too deeply (limit 32)\n"
  assert_equal [true, true, true], $probe_no_scope
  json = ""
  server_json_lines { json = bare_path_lines[0] }
  assert_includes json, "\"level\":\"ERROR\",\"request_id\":\""
  error_line = ""
  reject_line = ""
  json.split("\n").each do |l|
    error_line = l if l.include?("kaboom")
    reject_line = l if l.include?("rejected request")
  end
  assert error_line.include?("\"request_id\":\""), json
  assert reject_line.include?("\"request_id\":\""), json
  assert_equal [true, true, true], $probe_no_scope
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

test "a streamed body is written under the request's Scope, the server's stream error line included" do
  app = Cybertrain::RequestId.new(ServerTestApp.new, [:request_id])
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(app), port: 0, logger: $stream_logger)
  server.start
  c = RawClient.new(server.port)
  c.send_raw("GET /stream HTTP/1.1\r\nHost: t\r\n\r\n")
  raw = c.read_to_close
  c.close
  id = RawResponse.new("", raw, "").header("x-request-id")
  assert LogCapture.uuid?(id), raw
  assert_includes raw, "streamed"
  assert_equal id, $stream_seen
  assert_equal 1, LogCapture.count($stream_log.string, "INFO", "streaming\n")
  assert_includes $stream_log.string, " INFO [#{id}] streaming\n"
  c = RawClient.new(server.port)
  c.send_raw("GET /stream_boom HTTP/1.1\r\nHost: t\r\n\r\n")
  raw = c.read_to_close
  c.close
  boom_id = RawResponse.new("", raw, "").header("x-request-id")
  assert LogCapture.uuid?(boom_id), raw
  refute boom_id == id
  assert_equal boom_id, $stream_seen
  assert_includes $stream_log.string, " ERROR [#{boom_id}] stream error: RuntimeError: stream broke\n"
  server.stop
  # Reported once, with the request's id, `where` saying it was a stream.
  events = stream_events("stream broke")
  assert_equal 1, events.size
  ev = events[0]
  assert_equal ["RuntimeError", "request (stream)", boom_id, "GET", "/stream_boom", "false"],
               [ev.error_class, ev.error_where, ev.error_request_id, ev.error_request_method, ev.error_request_path,
                ev.error_handled.to_s]
end

test "an upgraded connection's writer that raises is reported once, with the request's id" do
  app = Cybertrain::RequestId.new(ServerTestApp.new, [:request_id])
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(app), port: 0, logger: $stream_logger)
  server.start
  c = RawClient.new(server.port)
  c.send_raw("GET /upgrade_boom HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
  raw = c.read_to_close
  c.close
  server.stop
  assert raw.start_with?("HTTP/1.1 101 "), raw
  id = RawResponse.new("", raw, "").header("x-request-id")
  assert_includes $stream_log.string, " ERROR [#{id}] stream error: ArgumentError: upgrade broke\n"
  events = stream_events("upgrade broke")
  assert_equal 1, events.size
  assert_equal ["ArgumentError", "request (stream)", id], [events[0].error_class, events[0].error_where, events[0].error_request_id]
end

test "a streamed body whose client went away is logged and not reported" do
  app = Cybertrain::RequestId.new(ServerTestApp.new, [:request_id])
  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(app), port: 0, logger: $stream_logger)
  server.start
  ["0", "1", "2", "3"].each do |which|
    c = RawClient.new(server.port)
    c.send_raw("GET /stream_gone?#{which} HTTP/1.1\r\nHost: t\r\n\r\n")
    c.read_to_close
    c.close
  end
  server.stop
  ["Errno::EPIPE", "Errno::ECONNRESET", "EOFError", "IOError"].each do |name|
    assert_includes $stream_log.string, " stream error: #{name}: "
  end
  Cybertrain.error.drain_reports(2.0)
  gone = Array.new(0) { blank_event }
  STREAM_EVENTS.each { |ev| gone << ev if ev.error_request_path == "/stream_gone" }
  assert_equal 0, gone.size
end

test "an upgraded (101) connection behind RequestId: the id echoed, the writer under the request's Scope, NO_SCOPE after" do
  $after_writer_no_scope = Array.new(0) { false }
  $stream_seen = ""
  app = Cybertrain::RequestId.new(ServerTestApp.new, [:request_id])
  server = ScopeAfterWriterServer.new(Cybertrain::ContextHandler.new(app), port: 0, logger: $stream_logger)
  server.start
  c = RawClient.new(server.port)
  c.send_raw("GET /upgrade HTTP/1.1\r\nHost: t\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
  raw = c.read_to_close
  c.close
  server.stop
  assert raw.start_with?("HTTP/1.1 101 "), raw
  id = RawResponse.new("", raw, "").header("x-request-id")
  assert LogCapture.uuid?(id), raw
  assert_equal id, $stream_seen
  assert_includes $stream_log.string, " INFO [#{id}] streaming\n"
  assert_equal [true], $after_writer_no_scope
end

test "start raises Cybertrain::PortInUse when the port is already bound" do
  first = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: 0, logger: Cybertrain::Logger.new($log, :info))
  first.start
  port = first.port
  second = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ServerTestApp.new), port: port, logger: Cybertrain::Logger.new($log, :info))
  message = assert_raises("Cybertrain::PortInUse") { second.start }
  assert_equal "port #{port} on 127.0.0.1 is already in use", message
  assert_equal port, second.port
  # the first server is unaffected
  c = RawClient.new(port)
  assert_equal "hi", c.get("/hello", "Connection: close\r\n").body
  c.close
  first.stop
end

Cybertrain::Test.run!
