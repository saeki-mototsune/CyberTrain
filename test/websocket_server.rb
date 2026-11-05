# The WebSocket side of the stream endpoint (docs/design.md D35), end to
# end: a real Server on an ephemeral port running Stream::Endpoint, the
# framework's own WebSocket::Client connecting to it. The handshake, the
# JSON envelope and raw payloads, subscribe / unsubscribe messages, ping and
# pong both ways, close 1008 for a bad token, 1009 for a message too large,
# 1000 when the server stops, 400 for a wrong version, and the connection
# count. The whole framework is in the program (NOTES rule 41); SQLite
# through FFI, so the snapshot comes from the compiled binary. Ports, ids
# and timings are never printed.
require "socket"
require "stringio"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/websocket/client"
require "cybertrain/test"

DB = Cybertrain::DB
Stream = Cybertrain::Stream
WS = Cybertrain::WebSocket

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
CONFIG = Cybertrain.config
CONFIG.secret_key_base = "w" * 64
CONFIG.stream_ping_interval = 1
CONFIG.stream_poll_ms = 20
CONFIG.http_allow_private = true
DB.connect(":memory:")
Stream.install!

class Fallback < Cybertrain::Middleware
  def call(ctx)
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

def token(name)
  list = Array.new(0) { "" }
  list << name
  Stream.sign(list)
end

def ws_url(query)
  "ws://127.0.0.1:#{SERVER.port}/cybertrain/stream?#{query}"
end

def connect(query)
  WS::Client.connect(ws_url(query), timeout: 2)
end

def subscribers_reach(n, seconds = 3.0)
  deadline = Time.now.to_f + seconds
  while Stream.hub.subscriber_count != n
    return false if Time.now.to_f >= deadline

    sleep 0.02
  end
  true
end

# The next text message's data, "" when none comes within `wait`.
def next_text(ws, wait = 3.0)
  deadline = Time.now.to_f + wait
  while Time.now.to_f < deadline
    msg = ws.receive(deadline - Time.now.to_f)
    return msg.ws_data if !msg.nil? && msg.ws_opcode == :text
  end
  ""
end

# The close code a receive ends with, -1 when none.
def closed_code(ws)
  3.times { ws.receive(2) }
  -1
rescue Cybertrain::WebSocket::ClosedError => e
  e.close_code
end

# A raw handshake, for what WebSocket::Client never sends.
def raw_status(headers)
  sock = TCPSocket.new("127.0.0.1", SERVER.port)
  sock.write("GET /cybertrain/stream?s=#{token("a")} HTTP/1.1\r\nHost: t\r\n#{headers}\r\n")
  line = ""
  line = sock.gets.to_s.strip unless sock.wait_readable(3).nil?
  sock.close
  line
end

test "the handshake succeeds and a broadcast arrives as the JSON envelope" do
  ws = connect("s=#{token("a")}&mode=json")
  assert ws.ws_open?
  assert subscribers_reach(1)
  id = Stream.broadcast("a", "hello")
  assert_equal "{\"stream\":\"a\",\"id\":#{id},\"data\":\"hello\"}", next_text(ws)
  ws.close
  assert subscribers_reach(0)
end

test "?after= above the head still gets the next broadcast" do
  ws = connect("s=#{token("h")}&after=999999")
  assert subscribers_reach(1)
  Stream.broadcast("h", "next")
  assert_equal "next", next_text(ws)
  ws.close
  assert subscribers_reach(0)
end

test "?after= below the head replays what was missed, then goes on live" do
  first = Stream.broadcast("past", "p1")
  Stream.broadcast("past", "p2")
  ws = connect("s=#{token("past")}&after=#{first - 1}")
  assert_equal "p1", next_text(ws)
  assert_equal "p2", next_text(ws)
  assert subscribers_reach(1)
  Stream.broadcast("past", "p3")
  assert_equal "p3", next_text(ws)
  ws.close
  assert subscribers_reach(0)
end

test "a token signed with another secret is closed with 1008" do
  CONFIG.secret_key_base = "q" * 64
  foreign = token("a")
  CONFIG.secret_key_base = "w" * 64
  ws = connect("s=#{foreign}")
  assert_equal 1008, closed_code(ws)
  assert subscribers_reach(0)
end

test "a connection that listens to nothing is closed with 1008 after the ping interval" do
  ws = connect("mode=json")
  assert_equal 1008, closed_code(ws)
  assert subscribers_reach(0)
end

test "subscribe messages are capped at 64 names" do
  ws = connect("mode=json")
  4.times do |t|
    names = Array.new(0) { "" }
    16.times { |i| names << "t#{t}n#{i}" }
    ws.send_text("{\"subscribe\":\"#{Stream.sign(names)}\"}")
    assert next_text(ws).start_with?("{\"subscribed\":")
  end
  ws.send_text("{\"subscribe\":\"#{token("extra")}\"}")
  assert_equal "{\"error\":\"too many streams\"}", next_text(ws)
  ws.close
  assert subscribers_reach(0)
end

test "mode=raw delivers the payload as it is" do
  ws = connect("s=#{token("a")}")
  assert subscribers_reach(1)
  Stream.broadcast("a", "<turbo-stream action=\"refresh\"></turbo-stream>")
  assert_equal "<turbo-stream action=\"refresh\"></turbo-stream>", next_text(ws)
  ws.close
  assert subscribers_reach(0)
end

test "subscribe and unsubscribe messages change the streams" do
  ws = connect("s=#{token("a")}&mode=json")
  assert subscribers_reach(1)
  ws.send_text("{\"subscribe\":\"#{token("b")}\"}")
  assert_equal "{\"subscribed\":[\"a\",\"b\"]}", next_text(ws)
  id = Stream.broadcast("b", "to b")
  assert_equal "{\"stream\":\"b\",\"id\":#{id},\"data\":\"to b\"}", next_text(ws)
  ws.send_text("{\"unsubscribe\":\"#{token("a")}\"}")
  assert_equal "{\"unsubscribed\":[\"a\"]}", next_text(ws)
  ws.send_text("{\"subscribe\":\"#{token("c")}x\"}")
  assert_equal "{\"error\":\"bad token\"}", next_text(ws)
  ws.send_text("not json")
  assert_equal "{\"error\":\"bad message\"}", next_text(ws)
  Stream.broadcast("a", "gone")
  last = Stream.broadcast("b", "still")
  assert_equal "{\"stream\":\"b\",\"id\":#{last},\"data\":\"still\"}", next_text(ws)
  ws.close
  assert subscribers_reach(0)
end

test "mode=json without a token waits for subscribe messages" do
  ws = connect("mode=json")
  ws.send_text("{\"subscribe\":\"#{token("late")}\"}")
  assert_equal "{\"subscribed\":[\"late\"]}", next_text(ws)
  ws.close
  assert subscribers_reach(0)
end

test "a client ping is answered with a pong" do
  CONFIG.stream_ping_interval = 15
  ws = connect("s=#{token("a")}")
  CONFIG.stream_ping_interval = 1
  before = ws.last_activity_at
  sleep 0.05
  ws.send_ping("hi")
  assert_nil ws.receive(1)
  assert ws.last_activity_at > before
  ws.close
  assert subscribers_reach(0)
end

test "the server pings after the ping interval" do
  ws = connect("s=#{token("quiet")}")
  before = ws.last_activity_at
  assert_nil ws.receive(2.5)
  assert ws.last_activity_at > before
  ws.close
  assert subscribers_reach(0)
end

test "a bad token is closed with 1008 after the handshake" do
  ws = connect("s=#{token("a")}x")
  assert_equal 1008, closed_code(ws)
  assert subscribers_reach(0)
end

test "a message above stream_max_message is closed with 1009" do
  ws = connect("s=#{token("a")}&mode=json")
  ws.send_text("x" * 70_000)
  assert_equal 1009, closed_code(ws)
  assert subscribers_reach(0)
end

test "a wrong WebSocket version is a 400" do
  key = "dGhlIHNhbXBsZSBub25jZQ=="
  assert_equal "HTTP/1.1 400 Bad Request",
               raw_status("Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 8\r\n")
  assert_equal "HTTP/1.1 101 Switching Protocols",
               raw_status("Upgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n")
  assert subscribers_reach(0)
end

test "stopping the server closes the WebSocket with 1000" do
  ws = connect("s=#{token("a")}")
  assert subscribers_reach(1)
  SERVER.stop
  assert_equal 1000, closed_code(ws)
  assert subscribers_reach(0)
  assert_equal 0, SERVER.open_connections
  Stream::Poller.stop!
end

Cybertrain::Test.run!
