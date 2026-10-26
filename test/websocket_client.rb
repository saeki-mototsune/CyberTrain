# Cybertrain::WebSocket::Client against Cybertrain::Test::WebSocketReceiver
# on 127.0.0.1: the handshake, frames both ways, control frames, the close
# handshake and the failures a conforming server never sends. Nothing here
# may hang: every wait the client makes is bounded by its timeout or by the
# `wait` given to receive, and every wait the receiver makes by its
# read_timeout and accept_window. Ports and timings are never printed.
#
# The TLS layer is in the program (cybertrain/net/tls requires Spinel's
# openssl package), so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23): script/regen-snapshot test/websocket_client.rb.
require "base64"
require "stringio"
require "cybertrain/websocket/client"
require "cybertrain/net/tls"
require "cybertrain/test/websocket_receiver"
require "cybertrain/test"

Cybertrain.config.http_allow_private = true
# A Logger whose io is only ever nil does not compile under Spinel
# 2026.10.26.7019 once the TLS layer is in the program (Logger#log's
# @io.puts goes through the IO dispatch and is emitted with the wrong
# argument type); test/http_client.rb gives its logger a StringIO the same way.
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

# What an action ended with: "ok" or the error's kind, and the message. The
# rescue ladder lives in a method that receives the block as a Proc
# (spikes/NOTES.md rule 32) and tells the classes apart by clause (rule 47).
class Outcome
  attr_reader :kind, :text

  def initialize(kind, text)
    @kind = kind
    @text = text
  end
end

def ws_outcome(&action)
  begin
    action.call
    return Outcome.new("ok", "")
  rescue Cybertrain::WebSocket::TimeoutError => e
    return Outcome.new("timeout", e.message)
  rescue Cybertrain::WebSocket::RefusedError => e
    return Outcome.new("refused", e.message)
  rescue Cybertrain::WebSocket::TLSError => e
    return Outcome.new("tls", e.message)
  rescue Cybertrain::WebSocket::BlockedAddressError => e
    return Outcome.new("blocked", e.message)
  rescue Cybertrain::WebSocket::HandshakeError => e
    return Outcome.new("handshake", e.message)
  rescue Cybertrain::WebSocket::ProtocolError => e
    return Outcome.new("protocol", e.message)
  rescue Cybertrain::WebSocket::TooLargeError => e
    return Outcome.new("too large", e.message)
  rescue Cybertrain::WebSocket::ClosedError => e
    return Outcome.new("closed", e.message)
  rescue ArgumentError => e
    return Outcome.new("argument", e.message)
  end
  Outcome.new("none", "")
end

# The close code a receive ends with, -1 when it does not raise ClosedError.
def closed_code(ws)
  ws.receive(5)
  -1
rescue Cybertrain::WebSocket::ClosedError => e
  e.close_code
end

def step(kind, data = "")
  Cybertrain::Test::WsStep.new(kind, data)
end

# A started receiver for one connection, playing `steps`.
def receiver_with(steps)
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 5.0, read_timeout: 2.0)
  rx.ws_script(steps)
  rx.start
  rx
end

def connect(url, timeout = 2)
  Cybertrain::WebSocket::Client.connect(url, timeout: timeout)
end

# Connects, waits for one message and closes: what a failure test runs.
def ws_session(url, timeout, max_message = 1_048_576)
  ws = Cybertrain::WebSocket::Client.connect(url, timeout: timeout, max_message: max_message)
  ws.receive(3)
  ws.close
  nil
end

# The close code a recorded close frame carries, -1 for none.
def code_of(frame)
  data = frame.rec_data
  return -1 if frame.rec_opcode != 8 || data.bytesize < 2

  (data.getbyte(0) << 8) | data.getbyte(1)
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

ACCEPT_HEAD = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"

# ---- the handshake and data frames ------------------------------------------

test "connects and exchanges text and binary" do
  rx = receiver_with([step("accept"), step("echo_until_close")])
  ws = connect(rx.url("/"))
  assert ws.ws_open?
  ws.send_text("hi")
  msg = ws.receive(5)
  assert_equal "hi", msg.ws_data
  assert_equal :text, msg.ws_opcode
  ws.send_binary("\x00\x01\xff".b)
  bin = ws.receive(5)
  assert_equal "\x00\x01\xff".b, bin.ws_data
  assert_equal :binary, bin.ws_opcode
  ws.close
  refute ws.ws_open?
  ws.close # twice is safe
  frames = rx.ws_received
  rx.stop
  assert_equal 3, frames.size
  assert_equal 1, frames[0].rec_opcode
  assert_equal 2, frames[1].rec_opcode
  assert_equal 8, frames[frames.size - 1].rec_opcode
  assert_equal 1000, code_of(frames[frames.size - 1])
end

test "the handshake sends the required headers" do
  rx = receiver_with([step("accept"), step("echo_until_close")])
  ws = Cybertrain::WebSocket::Client.connect(rx.url("/feed?x=1"), headers: { "Authorization" => "Bearer t" }, timeout: 2)
  assert_includes ws.ws_label, "127.0.0.1:"
  ws.close
  heads = rx.ws_request_headers(0)
  target = rx.ws_request_target(0)
  rx.stop
  assert_equal "websocket", heads["upgrade"].to_s
  assert_equal "upgrade", heads["connection"].to_s.downcase
  assert_equal "13", heads["sec-websocket-version"].to_s
  key = heads["sec-websocket-key"].to_s
  assert_equal 24, key.bytesize
  assert_equal 16, Base64.strict_decode64(key).bytesize
  assert heads["user-agent"].to_s.start_with?("cybertrain/")
  assert_equal "Bearer t", heads["authorization"].to_s
  assert_includes heads["host"].to_s, "127.0.0.1:"
  assert_equal "/feed?x=1", target
end

test "client frames are masked" do
  rx = receiver_with([step("accept"), step("echo_until_close")])
  ws = connect(rx.url("/"))
  ws.send_text("a")
  ws.send_binary("b")
  ws.send_ping("c")
  ws.receive(5)
  ws.receive(5)
  ws.close
  frames = rx.ws_received
  rx.stop
  assert_equal 4, frames.size
  i = 0
  while i < frames.size
    assert frames[i].rec_masked
    i += 1
  end
  assert_equal 9, frames[2].rec_opcode
  assert_equal "c", frames[2].rec_data
end

test "a wrong Sec-WebSocket-Accept is a HandshakeError" do
  rx = receiver_with([step("reply_raw", "#{ACCEPT_HEAD}Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n\r\n")])
  got = ws_outcome { connect(rx.url("/")) }
  rx.stop
  assert_equal "handshake", got.kind
  assert_includes got.text, "Sec-WebSocket-Accept"
  assert_includes got.text, "127.0.0.1:#{rx.port}"
end

test "a 200 is a HandshakeError naming the status" do
  rx = receiver_with([step("reply_raw", "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")])
  got = ws_outcome { connect(rx.url("/")) }
  rx.stop
  assert_equal "handshake", got.kind
  assert_includes got.text, "200"
end

test "an extension in the answer is a HandshakeError" do
  rx = receiver_with([step("reply_raw", "#{ACCEPT_HEAD}Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n")])
  got = ws_outcome { connect(rx.url("/")) }
  rx.stop
  assert_equal "handshake", got.kind
  assert_includes got.text, "extension"
end

test "a subprotocol in the answer is a HandshakeError" do
  rx = receiver_with([step("reply_raw", "#{ACCEPT_HEAD}Sec-WebSocket-Accept: {accept}\r\nSec-WebSocket-Protocol: chat\r\n\r\n")])
  got = ws_outcome { connect(rx.url("/")) }
  rx.stop
  assert_equal "handshake", got.kind
  assert_includes got.text, "subprotocol"
end

test "the {accept} placeholder answers a valid handshake" do
  rx = receiver_with([step("reply_raw", "#{ACCEPT_HEAD}Sec-WebSocket-Accept: {accept}\r\n\r\n"), step("echo_until_close")])
  got = ws_outcome { connect(rx.url("/")).close }
  frames = rx.ws_received
  rx.stop
  assert_equal "ok", got.kind
  assert_equal 1, frames.size
  assert_equal 1000, code_of(frames[0])
end

test "a silent handshake times out" do
  rx = receiver_with([step("silent", "3")])
  started = now
  got = ws_outcome { connect(rx.url("/"), 1) }
  rx.stop
  assert_equal "timeout", got.kind
  assert now - started < 2.5
end

test "a frame sent with the 101 is not lost" do
  rx = receiver_with([step("send_with_101", "early")])
  ws = connect(rx.url("/"))
  msg = ws.receive(5)
  ws.close
  rx.stop
  assert_equal "early", msg.ws_data
end

test "receive resumes a frame split across waits" do
  rx = receiver_with([step("accept"), step("split_frame", "whole message"), step("expect")])
  ws = connect(rx.url("/"))
  assert_nil ws.receive(0.1)
  assert ws.ws_open?
  msg = ws.receive(5)
  ws.close
  rx.stop
  assert_equal "whole message", msg.ws_data
end

test "receive returns nil when nothing arrives" do
  rx = receiver_with([step("accept"), step("echo_until_close")])
  ws = connect(rx.url("/"))
  before = ws.last_activity_at
  assert_nil ws.receive(0.2)
  assert ws.ws_open?
  assert_equal before, ws.last_activity_at
  ws.send_text("still")
  msg = ws.receive(5)
  ws.close
  rx.stop
  assert_equal "still", msg.ws_data
end

# ---- control frames and the close handshake ---------------------------------

test "a ping is answered with a pong carrying its payload" do
  ping = Cybertrain::WebSocket::Frame.encode(9, "p1", "")
  rx = receiver_with([step("accept"), step("send_raw", ping), step("expect"), step("silent", "1")])
  ws = connect(rx.url("/"))
  before = ws.last_activity_at
  assert_nil ws.receive(0.5)
  assert ws.last_activity_at > before
  frames = rx.ws_received
  ws.close
  rx.stop
  assert_equal 1, frames.size
  assert_equal 10, frames[0].rec_opcode
  assert_equal "p1", frames[0].rec_data
  assert frames[0].rec_masked
end

test "a stream of pongs cannot keep receive past its wait" do
  pong = Cybertrain::WebSocket::Frame.encode(10, "", "")
  pongs = String.new
  i = 0
  while i < 20_000
    pongs << pong
    i += 1
  end
  rx = receiver_with([step("accept"), step("send_raw", pongs), step("send_text", "after"), step("echo_until_close")])
  ws = connect(rx.url("/"))
  # Everything is sent before the client reads, so no read has to wait:
  # only the check after each control frame ends even a wait of 0 (without
  # it, receive reads all 20000 pongs and answers "after").
  sleep(0.3)
  started = now
  got = ws.receive(0)
  elapsed = now - started
  msg = ws.receive(5)
  ws.close
  rx.stop
  assert_nil got
  assert elapsed < 1.0
  assert_equal "after", msg.ws_data
end

test "a close from the server is a ClosedError with its code" do
  rx = receiver_with([step("accept"), step("close", "1001")])
  ws = connect(rx.url("/"))
  got = ws_outcome { ws.receive(5) }
  frames = rx.ws_received
  rx.stop
  assert_equal "closed", got.kind
  assert_includes got.text, "(1001)"
  refute ws.ws_open?
  assert_equal 1, frames.size
  assert_equal 8, frames[0].rec_opcode
  assert_equal 1001, code_of(frames[0])
  again = ws_outcome { ws.send_text("late") }
  assert_equal "closed", again.kind
end

test "an application close code is passed on" do
  rx = receiver_with([step("accept"), step("close", "4000")])
  ws = connect(rx.url("/"))
  assert_equal 4000, closed_code(ws)
  rx.stop
end

test "a dropped connection is a ClosedError 1006" do
  rx = receiver_with([step("accept"), step("drop")])
  ws = connect(rx.url("/"))
  assert_equal 1006, closed_code(ws)
  refute ws.ws_open?
  rx.stop
end

# ---- what the client refuses -------------------------------------------------

test "max_message is enforced before reading the payload" do
  rx = receiver_with([step("accept"), step("send_text", "x" * 11), step("expect")])
  ws = Cybertrain::WebSocket::Client.connect(rx.url("/"), timeout: 2, max_message: 10)
  got = ws_outcome { ws.receive(5) }
  frames = rx.ws_received
  rx.stop
  assert_equal "too large", got.kind
  refute ws.ws_open?
  assert_equal 1, frames.size
  assert_equal 1009, code_of(frames[0])
end

test "a reserved close code from the server is a ProtocolError" do
  rx = receiver_with([step("accept"), step("close", "1004")])
  ws = connect(rx.url("/"))
  got = ws_outcome { ws.receive(5) }
  frames = rx.ws_received
  rx.stop
  assert_equal "protocol", got.kind
  assert_includes got.text, "invalid close code 1004"
  refute ws.ws_open?
  assert_equal 1, frames.size
  assert_equal 1002, code_of(frames[0])
end

test "a masked server frame is a ProtocolError" do
  masked = Cybertrain::WebSocket::Frame.encode(1, "m", "abcd")
  rx = receiver_with([step("accept"), step("send_raw", masked), step("expect")])
  ws = connect(rx.url("/"))
  got = ws_outcome { ws.receive(5) }
  frames = rx.ws_received
  rx.stop
  assert_equal "protocol", got.kind
  assert_includes got.text, "masked"
  refute ws.ws_open?
  assert_equal 1, frames.size
  assert_equal 1002, code_of(frames[0])
end

test "private addresses are refused unless allowed" do
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 1.0, read_timeout: 1.0)
  rx.start
  got = ws_outcome { Cybertrain::WebSocket::Client.connect(rx.url("/"), timeout: 2, allow_private: false) }
  rx.stop
  assert_equal "blocked", got.kind
  assert_includes got.text, "http_allow_private"
end

test "errors never contain the path or the query" do
  texts = Array.new(0) { "" }
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 1.0, read_timeout: 1.0)
  rx.start
  texts << ws_outcome { Cybertrain::WebSocket::Client.connect(rx.url("/secret?token=abc"), timeout: 2, allow_private: false) }.text
  rx.stop
  scripts = [
    [step("reply_raw", "#{ACCEPT_HEAD}Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n\r\n")],
    [step("reply_raw", "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")],
    [step("silent", "3")],
    [step("accept"), step("close", "1001")],
    [step("accept"), step("drop")],
    [step("accept"), step("send_text", "x" * 2000)],
    [step("accept"), step("send_raw", Cybertrain::WebSocket::Frame.encode(1, "m", "abcd"))]
  ]
  kinds = Array.new(0) { "" }
  i = 0
  while i < scripts.size
    srx = receiver_with(scripts[i])
    got = ws_outcome { ws_session(srx.url("/secret?token=abc"), 1, 100) }
    srx.stop
    kinds << got.kind
    texts << got.text
    i += 1
  end
  assert_equal ["handshake", "handshake", "timeout", "closed", "closed", "too large", "protocol"], kinds
  assert_equal 8, texts.size
  i = 0
  while i < texts.size
    assert_includes texts[i], "127.0.0.1:"
    assert_nil texts[i].index("secret")
    assert_nil texts[i].index("token")
    i += 1
  end
end

test "reserved headers are refused" do
  own_key = ws_outcome { Cybertrain::WebSocket::Client.connect("ws://127.0.0.1:9/", headers: { "Sec-WebSocket-Key" => "x" }) }
  assert_equal "argument", own_key.kind
  assert_equal "header Sec-WebSocket-Key is set by the client itself", own_key.text
  proto = ws_outcome { Cybertrain::WebSocket::Client.connect("ws://127.0.0.1:9/", headers: { "sec-websocket-protocol" => "chat" }) }
  assert_equal "argument", proto.kind
  upgrade = ws_outcome { Cybertrain::WebSocket::Client.connect("ws://127.0.0.1:9/", headers: { "Upgrade" => "h2c" }) }
  assert_equal "argument", upgrade.kind
  assert_equal "header Upgrade is set by the client itself", upgrade.text
  crlf = ws_outcome { Cybertrain::WebSocket::Client.connect("ws://127.0.0.1:9/", headers: { "X-A" => "a\r\nb" }) }
  assert_equal "argument", crlf.kind
end

test "a non-ws URL is refused" do
  got = ws_outcome { Cybertrain::WebSocket::Client.connect("http://127.0.0.1:9/secret") }
  assert_equal "argument", got.kind
  assert_equal "only ws:// and wss:// URLs are supported", got.text
end

test "a ping payload longer than 125 bytes is refused" do
  rx = receiver_with([step("accept"), step("echo_until_close")])
  ws = connect(rx.url("/"))
  got = ws_outcome { ws.send_ping("p" * 126) }
  ws.close
  rx.stop
  assert_equal "argument", got.kind
end

# ---- TLS, up to the handshake -----------------------------------------------

test "wss to a plain server fails the handshake" do
  # What a plain HTTP server answers a ClientHello with, at once.
  rx = receiver_with([step("reply_raw", "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")])
  got = ws_outcome { connect("wss://127.0.0.1:#{rx.port}/secret") }
  rx.stop
  assert_equal "tls", got.kind
  assert_includes got.text, "TLS handshake failed"
  assert_nil got.text.index("secret")
end

Cybertrain::Test.run!
