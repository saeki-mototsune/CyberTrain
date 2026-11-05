# The SSE side of the stream endpoint end to end (docs/design.md D35): a
# real Server on an ephemeral port running Stream::Endpoint in front of a
# fallback middleware, the poller running, raw TCPSocket clients. Live
# delivery, mode=json, Last-Event-ID replay, 403 for a bad or foreign token,
# 503 past stream_max_connections, a client that goes away while idle, the
# `: ping`, Controller#stream, Test::Client#get_stream, stream_path "" and
# the template helpers (turbo_stream_from, signed_stream_name,
# stream_source_path). The whole framework is in the program (NOTES rule
# 41); SQLite through FFI, so the snapshot comes from the compiled binary.
# Ports, ids and timings are never printed.
require "socket"
require "stringio"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"
require "cybertrain/test/client"

DB = Cybertrain::DB
Stream = Cybertrain::Stream

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
CONFIG = Cybertrain.config
CONFIG.secret_key_base = "e" * 64
CONFIG.stream_ping_interval = 1
CONFIG.stream_poll_ms = 20
DB.connect(":memory:")
Stream.install!

class LiveController < Cybertrain::Controller
  def live
    stream do |out|
      out.write(Cybertrain::SSE.event("hi"))
      out.write(Cybertrain::SSE.event("bye"))
    end
  end
end

class Fallback < Cybertrain::Middleware
  def call(ctx)
    if ctx.request.path == "/live"
      LiveController.new(ctx).process(:live) { |c| c.live }
      return nil
    end
    ctx.response.status = 404
    ctx.response.body = "nope"
    nil
  end
end

STACK = Stream::Endpoint.new(Fallback.new, CONFIG)
SERVER = Cybertrain::Server.new(Cybertrain::ContextHandler.new(STACK), port: 0, read_timeout: 2, drain_timeout: 3.0,
                                logger: Cybertrain::Logger.new(LOG, :info))
# As Application#serve does: the poller before the listener.
Stream::Poller.start!(CONFIG)
SERVER.start

# A raw client; every read is bounded (wait_readable first, rule 20).
class RawStream
  def initialize(port, request)
    @sock = TCPSocket.new("127.0.0.1", port)
    @sock.write(request)
    @buf = +""
    @eof = false
  end

  # True once `needle` has arrived, false after `seconds` or at EOF.
  def wait_for(needle, seconds = 3.0)
    deadline = Time.now.to_f + seconds
    while @buf.byteindex(needle).nil?
      return false if @eof

      left = deadline - Time.now.to_f
      return false if left <= 0
      return false if @sock.wait_readable(left).nil?

      fill
    end
    true
  end

  # Reads until the server closes (at most `seconds`).
  def read_to_end(seconds = 3.0)
    deadline = Time.now.to_f + seconds
    until @eof
      left = deadline - Time.now.to_f
      break if left <= 0
      break if @sock.wait_readable(left).nil?

      fill
    end
    @eof
  end

  def text
    @buf
  end

  def head
    idx = @buf.byteindex("\r\n\r\n")
    idx.nil? ? "" : @buf.byteslice(0, idx)
  end

  def count(needle)
    n = 0
    from = 0
    while true
      at = @buf.byteindex(needle, from)
      break if at.nil?

      n += 1
      from = at + needle.bytesize
    end
    n
  end

  def close
    @sock.close unless @sock.closed?
  end

  private

  def fill
    chunk = read_some
    if chunk.empty?
      @eof = true
    else
      @buf << chunk
    end
    nil
  end

  def read_some
    @sock.readpartial(16384)
  rescue EOFError, Errno::ECONNRESET
    ""
  end
end

def sse(query, extra = "")
  RawStream.new(SERVER.port, "GET /cybertrain/stream?#{query} HTTP/1.1\r\nHost: t\r\nAccept: text/event-stream\r\n#{extra}\r\n")
end

def plain_get(path)
  c = RawStream.new(SERVER.port, "GET #{path} HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  c.read_to_end
  c.close
  c
end

# Waits until the hub has `n` subscribers; true when it got there.
def subscribers_reach(n, seconds = 3.0)
  deadline = Time.now.to_f + seconds
  while Stream.hub.subscriber_count != n
    return false if Time.now.to_f >= deadline

    sleep 0.02
  end
  true
end

def occurrences(text, needle)
  n = 0
  from = 0
  while true
    at = text.byteindex(needle, from)
    break if at.nil?

    n += 1
    from = at + needle.bytesize
  end
  n
end

def token(*names)
  list = Array.new(0) { "" }
  names.each { |n| list << n }
  Stream.sign(list)
end

def head_lines(c)
  c.head.split("\r\n")
end

test "a GET with a token is an event stream that delivers a broadcast" do
  c = sse("s=#{token("a")}")
  assert c.wait_for("\r\n\r\n")
  lines = head_lines(c)
  assert_equal "HTTP/1.1 200 OK", lines[0]
  assert_includes lines, "Content-Type: text/event-stream"
  assert_includes lines, "Cache-Control: no-store"
  assert_includes lines, "X-Accel-Buffering: no"
  assert_includes lines, "Transfer-Encoding: chunked"
  assert subscribers_reach(1)
  id = Stream.broadcast("a", "hello")
  assert c.wait_for("id: #{id}\ndata: hello\n\n")
  c.close
  assert subscribers_reach(0)
end

# Restarts the poller with another interval (its first tick is at once).
def restart_poller(poll_ms)
  Stream::Poller.stop!
  sleep 0.05
  CONFIG.stream_poll_ms = poll_ms
  Stream::Poller.start!(CONFIG)
  sleep 0.05
  nil
end

test "a fresh connection gets what was not yet polled when it connected, not what was" do
  Stream.broadcast("f", "old")
  # polled (every 20 ms) before the connection subscribes
  sleep 0.3
  # a slow poller, so the next row is still unpolled when the client connects
  restart_poller(2000)
  Stream.broadcast("f", "pending")
  c = sse("s=#{token("f")}")
  assert subscribers_reach(1)
  Stream.broadcast("f", "new")
  assert c.wait_for("data: new\n\n", 4.0)
  assert_equal 1, c.count("data: pending\n")
  assert_equal 0, c.count("data: old")
  assert c.text.byteindex("data: pending").to_i < c.text.byteindex("data: new").to_i
  c.close
  assert subscribers_reach(0)
  restart_poller(20)
end

test "mode=json names the stream and sends the envelope" do
  c = sse("s=#{token("a", "b")}&mode=json")
  assert subscribers_reach(1)
  id = Stream.broadcast("b", "x\"y")
  assert c.wait_for("event: b\nid: #{id}\ndata: {\"stream\":\"b\",\"id\":#{id},\"data\":\"x\\\"y\"}\n\n")
  c.close
  assert subscribers_reach(0)
end

test "Last-Event-ID replays the backlog once, then goes on live" do
  first = Stream.broadcast("r", "r1")
  Stream.broadcast("other", "nope")
  second = Stream.broadcast("r", "r2")
  c = sse("s=#{token("r")}", "Last-Event-ID: 0\r\n")
  assert c.wait_for("id: #{second}\ndata: r2\n\n")
  assert subscribers_reach(1)
  third = Stream.broadcast("r", "r3")
  assert c.wait_for("id: #{third}\ndata: r3\n\n")
  sleep 0.1
  assert_equal 1, c.count("data: r1\n")
  assert_equal 1, c.count("data: r2\n")
  assert_equal 1, c.count("data: r3\n")
  assert_equal 0, c.count("data: nope")
  r1 = c.text.byteindex("id: #{first}\n").to_i
  r2 = c.text.byteindex("id: #{second}\n").to_i
  assert r1 < r2
  c.close
  assert subscribers_reach(0)
end

test "a Last-Event-ID above the head still gets the next broadcast" do
  c = sse("s=#{token("h")}", "Last-Event-ID: 999999\r\n")
  assert subscribers_reach(1)
  id = Stream.broadcast("h", "next")
  assert c.wait_for("id: #{id}\ndata: next\n\n")
  c.close
  assert subscribers_reach(0)
end

test "a bad, foreign or missing token is a 403 with no body" do
  good = token("a")
  bad = plain_get("/cybertrain/stream?s=#{good}x")
  assert_equal "HTTP/1.1 403 Forbidden", head_lines(bad)[0]
  assert_includes head_lines(bad), "Content-Length: 0"
  CONFIG.secret_key_base = "z" * 64
  foreign = token("a")
  CONFIG.secret_key_base = "e" * 64
  assert_equal "HTTP/1.1 403 Forbidden", head_lines(plain_get("/cybertrain/stream?s=#{foreign}"))[0]
  assert_equal "HTTP/1.1 403 Forbidden", head_lines(plain_get("/cybertrain/stream"))[0]
  assert_equal "HTTP/1.1 400 Bad Request", head_lines(plain_get("/cybertrain/stream?s=#{good}&mode=xml"))[0]
  assert_equal 0, Stream.hub.subscriber_count
end

test "past stream_max_connections the answer is 503" do
  CONFIG.stream_max_connections = 1
  c = sse("s=#{token("a")}")
  assert subscribers_reach(1)
  busy = plain_get("/cybertrain/stream?s=#{token("a")}")
  assert_equal "HTTP/1.1 503 Service Unavailable", head_lines(busy)[0]
  CONFIG.stream_max_connections = 1000
  c.close
  assert subscribers_reach(0)
end

test "without the poller the endpoint answers 503" do
  Stream::Poller.stop!
  sleep 0.1
  res = plain_get("/cybertrain/stream?s=#{token("a")}")
  assert_equal "HTTP/1.1 503 Service Unavailable", head_lines(res)[0]
  assert res.text.end_with?("\r\n\r\nstream poller is not running")
  assert Stream::Poller.start!(CONFIG)
  c = sse("s=#{token("a")}")
  assert subscribers_reach(1)
  c.close
  assert subscribers_reach(0)
end

test "a client that goes away while idle is noticed within the ping interval" do
  c = sse("s=#{token("idle")}")
  assert subscribers_reach(1)
  c.close
  assert subscribers_reach(0, 2.5)
end

test "a ping comment goes out after the interval" do
  c = sse("s=#{token("quiet")}")
  assert c.wait_for(": ping\n\n", 3.0)
  c.close
  assert subscribers_reach(0)
end

test "Controller#stream writes its block's chunks" do
  c = plain_get("/live")
  assert_equal "HTTP/1.1 200 OK", head_lines(c)[0]
  assert_includes head_lines(c), "Content-Type: text/event-stream"
  assert_includes c.text, "a\r\ndata: hi\n\n\r\n"
  assert_includes c.text, "b\r\ndata: bye\n\n\r\n0\r\n\r\n"
end

test "Test::Client#get_stream runs the writer in memory" do
  Stream.broadcast("g", "g1")
  Stream.broadcast("g", "g2")
  client = Cybertrain::Test::Client.new(STACK)
  res = client.get_stream("/cybertrain/stream?s=#{token("g")}", events: 2, headers: { "last-event-id" => "0" })
  assert_equal 200, res.status
  assert_includes res.body, "data: g1\n\n"
  assert_includes res.body, "data: g2\n\n"
  assert_equal 0, Stream.hub.subscriber_count
  live = client.get_stream("/live", events: 5)
  assert_equal "data: hi\n\ndata: bye\n\n", live.body
end

test "a backlog longer than one replay chunk arrives whole and once" do
  first = 0
  450.times do |i|
    id = Stream.broadcast("long", "l#{i}")
    first = id if i == 0
    Stream.broadcast("other", "o#{i}")
  end
  client = Cybertrain::Test::Client.new(STACK)
  res = client.get_stream("/cybertrain/stream?s=#{token("long")}", events: 450, timeout: 5,
                                                                    headers: { "last-event-id" => (first - 1).to_s })
  text = res.body
  seen = 0
  450.times { |i| seen += 1 unless text.byteindex("data: l#{i}\n\n").nil? }
  assert_equal 450, seen
  assert_equal 450, occurrences(text, "data: l")
  assert_equal 0, occurrences(text, "data: o")
end

test "the request log writes the stream tokens as [FILTERED]" do
  io = StringIO.new
  logged = Cybertrain::RequestLogger.new(STACK, Cybertrain::Logger.new(io), "/cybertrain/stream")
  tok = token("a")
  Cybertrain::Test::Client.new(logged).get("/cybertrain/stream?s=#{tok}&mode=raw&s=#{tok}")
  Cybertrain::Test::Client.new(logged).get("/elsewhere?s=kept")
  assert_includes io.string, "\"/cybertrain/stream?s=[FILTERED]&mode=raw&s=[FILTERED]\""
  assert_includes io.string, "\"/elsewhere?s=kept\""
  assert_nil io.string.index(tok)
end

test "stream_path \"\" leaves the endpoint out of the stack; stream_error checks the keys" do
  c = Cybertrain::Config.new
  c.env = "test"
  c.secret_key_base = "e" * 64
  c.stream_path = ""
  app = Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/" }, config: c)
  res = Cybertrain::Test::Client.new(app).get("/cybertrain/stream?s=#{token("a")}")
  assert_equal 404, res.status
  assert_equal "", c.stream_error
  c.stream_path = "stream"
  assert_includes c.stream_error, "stream_path must start with"
  c.stream_path = "/up"
  assert_includes c.stream_error, "must differ from health_path"
  c.stream_path = "/cybertrain/stream"
  c.stream_poll_ms = 5
  assert_includes c.stream_error, "stream_poll_ms must be at least 10"
  fresh = Cybertrain::Config.new
  assert_equal "/cybertrain/stream", fresh.stream_path
  assert_equal 100, fresh.stream_poll_ms
  assert_equal 60, fresh.stream_retention
  assert_equal 15, fresh.stream_ping_interval
  assert_equal 1000, fresh.stream_max_connections
  assert_equal 65536, fresh.stream_max_message
  assert_equal 1000, fresh.stream_max_backlog
end

# --- the template helpers ----------------------------------------------------

class Article < Cybertrain::Model
  def self.table_name = "articles"
  def model_name = "Article"
end

def article(id)
  a = Article.new
  a.set_id(id)
  a
end

def helpers_env
  env = {}
  env["__template_dir"] = "articles"
  env["article"] = article(1)
  env
end

def render_with(helpers, src)
  template = Cybertrain::Template::Template.parse(src, "articles/inline")
  Cybertrain::Template::Interpreter.new(helpers).render(template, helpers_env)
end

def request_controller
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/articles/1", { "host" => "example.test" }, ""))
  Cybertrain::Controller.new(ctx)
end

# The token in `src="...?s=TOKEN"` (up to the closing quote or `&amp;`).
def token_in(html)
  from = html.byteindex("?s=").to_i + 3
  stop = html.byteindex("&", from)
  stop = html.byteindex("\"", from) if stop.nil?
  stop = html.bytesize if stop.nil?
  html.byteslice(from, stop - from)
end

test "turbo_stream_from renders a source whose token names the streams" do
  html = render_with(Cybertrain::Template::Helpers.new(nil), "<%= turbo_stream_from 'alerts', article %>")
  assert html.start_with?("<turbo-stream-source src=\"/cybertrain/stream?s=")
  assert html.end_with?("\"></turbo-stream-source>")
  assert_equal ["alerts", "articles:1"], Stream.verify(token_in(html))
end

test "turbo_stream_from ws: true builds a ws:// URL from the request" do
  html = render_with(Cybertrain::Template::Helpers.new(request_controller), "<%= turbo_stream_from 'alerts', ws: true %>")
  assert html.start_with?("<turbo-stream-source src=\"ws://example.test/cybertrain/stream?s=")
  assert_equal ["alerts"], Stream.verify(token_in(html))
  # OutsideRequest reaches the caller by class (not relocated into a
  # Template::RuntimeError), as every helper that needs a request raises it.
  message = assert_raises("Cybertrain::Views::OutsideRequest") do
    render_with(Cybertrain::Template::Helpers.new(nil), "<%= turbo_stream_from 'alerts', ws: true %>")
  end
  assert_includes message, "turbo_stream_from ws: true needs a request"
end

test "signed_stream_name and stream_source_path" do
  helpers = Cybertrain::Template::Helpers.new(nil)
  name = render_with(helpers, "<%= signed_stream_name 'alerts', article %>")
  assert_equal ["alerts", "articles:1"], Stream.verify(name)
  path = render_with(helpers, "<%= stream_source_path 'alerts' %>")
  assert path.start_with?("/cybertrain/stream?s=")
  assert path.end_with?("&amp;mode=json")
  assert_equal ["alerts"], Stream.verify(token_in(path))
  raw = render_with(helpers, "<%= stream_source_path 'alerts', mode: 'raw' %>")
  assert raw.end_with?("&amp;mode=raw")
end

test "stopping the server ends an open stream" do
  c = sse("s=#{token("a")}")
  assert subscribers_reach(1)
  SERVER.stop
  assert c.read_to_end(3.0)
  assert c.text.end_with?("0\r\n\r\n")
  assert_equal 0, SERVER.open_connections
  assert_equal 0, Stream.hub.subscriber_count
  Stream::Poller.stop!
  c.close
end

Cybertrain::Test.run!
