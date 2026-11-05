# Streaming responses end to end (docs/design.md D36): a real Server on an
# ephemeral port whose handler answers with a BodyWriter, read by raw
# TCPSockets. The chunked framing, HTTP/1.0's unframed body, HEAD, a writer
# that raises, and Sink#wait_closed noticing a client that closes. Ports
# and timings are never printed.
require "socket"
require "stringio"
require "cybertrain/http/server"
require "cybertrain/test"

# Three chunks, one of them multibyte, one holding a NUL byte.
class ThreeChunks < Cybertrain::BodyWriter
  def write_body(sink)
    sink.write("one")
    sink.write("")
    sink.write("déjà")
    sink.write("a\0b")
    nil
  end
end

class RaisesAfterOne < Cybertrain::BodyWriter
  def write_body(sink)
    sink.write("first")
    raise "writer boom"
  end
end

# What the waiting writer saw: "closed" once wait_closed answered true.
SEEN = Array.new(0) { "" }

class WaitsForClose < Cybertrain::BodyWriter
  def write_body(sink)
    sink.write("waiting")
    tries = 0
    while tries < 50
      if sink.wait_closed(0.2)
        SEEN << "closed"
        return nil
      end
      tries += 1
    end
    SEEN << "timed out"
    nil
  end
end

# Writes 1 MB chunks to a client that never reads, until the sink gives
# up (the server's stream_write_timeout is 1 s here).
BIG = "x" * 1_048_576

class Floods < Cybertrain::BodyWriter
  def write_body(sink)
    n = 0
    while n < 400 && !sink.closed?
      sink.write(BIG)
      n += 1
    end
    SEEN << (sink.closed? ? "write timed out" : "never blocked")
    nil
  end
end

class StreamHandler < Cybertrain::HttpHandler
  def call(request)
    response = Cybertrain::Response.new
    response.content_type = "text/plain"
    case request.path
    when "/three" then response.body_writer = ThreeChunks.new
    when "/raise" then response.body_writer = RaisesAfterOne.new
    when "/wait" then response.body_writer = WaitsForClose.new
    when "/flood" then response.body_writer = Floods.new
    when "/reset"
      response.body_writer = ThreeChunks.new
      response.reset_to(500)
    else response.body = "plain"
    end
    response
  end
end

# Everything the server sends until it closes (bounded waits, rule 20).
def read_all(sock)
  out = +""
  while true
    break if sock.wait_readable(5).nil?

    chunk = read_some(sock)
    break if chunk.empty?

    out << chunk
  end
  out
end

def read_some(sock)
  sock.readpartial(16384)
rescue EOFError, Errno::ECONNRESET
  ""
end

def exchange(port, raw)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write(raw)
  got = read_all(sock)
  sock.close
  got
end

def head_of(raw)
  idx = raw.byteindex("\r\n\r\n")
  idx.nil? ? raw : raw.byteslice(0, idx)
end

def body_of(raw)
  idx = raw.byteindex("\r\n\r\n")
  return "" if idx.nil?

  raw.byteslice(idx + 4, raw.bytesize - idx - 4)
end

def header_lines(raw)
  head_of(raw).split("\r\n")
end

LOG = StringIO.new
SERVER = Cybertrain::Server.new(StreamHandler.new, port: 0, read_timeout: 2, stream_write_timeout: 1,
                                logger: Cybertrain::Logger.new(LOG, :info))
SERVER.start

test "a BodyWriter's chunks go out with chunked framing and the terminator" do
  raw = exchange(SERVER.port, "GET /three HTTP/1.1\r\nHost: t\r\n\r\n")
  lines = header_lines(raw)
  assert_equal "HTTP/1.1 200 OK", lines[0]
  assert_includes lines, "Transfer-Encoding: chunked"
  assert_includes lines, "Connection: close"
  assert_includes lines, "Content-Type: text/plain"
  assert_equal 0, lines.count { |l| l.downcase.start_with?("content-length") }
  expected = +"3\r\none\r\n"
  expected << "6\r\ndéjà\r\n"
  expected << "3\r\na\0b\r\n"
  expected << "0\r\n\r\n"
  assert_equal expected.b, body_of(raw).b
end

test "HTTP/1.0 gets the body unframed and the connection closes" do
  raw = exchange(SERVER.port, "GET /three HTTP/1.0\r\n\r\n")
  lines = header_lines(raw)
  assert_includes lines, "Connection: close"
  assert_equal 0, lines.count { |l| l.downcase.start_with?("transfer-encoding") }
  assert_equal "onedéjàa\0b".b, body_of(raw).b
end

test "HEAD gets the head only" do
  raw = exchange(SERVER.port, "HEAD /three HTTP/1.1\r\nHost: t\r\n\r\n")
  assert_equal "HTTP/1.1 200 OK", header_lines(raw)[0]
  assert_equal "", body_of(raw)
end

test "a writer that raises ends the connection and is logged" do
  raw = exchange(SERVER.port, "GET /raise HTTP/1.1\r\nHost: t\r\n\r\n")
  assert_equal "5\r\nfirst\r\n", body_of(raw)
  assert_includes LOG.string, "[ERROR] stream error: RuntimeError: writer boom"
  again = exchange(SERVER.port, "GET /plain HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  assert_equal "plain", body_of(again)
end

test "Sink#wait_closed answers true once the client closes" do
  sock = TCPSocket.new("127.0.0.1", SERVER.port)
  sock.write("GET /wait HTTP/1.1\r\nHost: t\r\n\r\n")
  got = +""
  while got.byteindex("waiting").nil?
    break if sock.wait_readable(5).nil?

    got << read_some(sock)
  end
  sock.close
  tries = 0
  while SEEN.empty? && tries < 100
    sleep 0.05
    tries += 1
  end
  assert_equal ["closed"], SEEN
end

test "an error reset after a BodyWriter was set is an ordinary response" do
  raw = exchange(SERVER.port, "GET /reset HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  lines = header_lines(raw)
  assert_equal "HTTP/1.1 500 Internal Server Error", lines[0]
  assert_includes lines, "Content-Length: 21"
  assert_equal 0, lines.count { |l| l.downcase.start_with?("transfer-encoding") }
  assert_equal "Internal Server Error", body_of(raw)
end

test "a body or a redirect set after a BodyWriter replaces the stream" do
  rendered = Cybertrain::Response.new
  rendered.body_writer = ThreeChunks.new
  rendered.body = "rendered"
  assert_equal false, rendered.streaming?
  assert_includes rendered.to_http, "Content-Length: 8\r\n"
  redirected = Cybertrain::Response.new
  redirected.body_writer = ThreeChunks.new
  redirected.redirect("/next", 303)
  assert_equal false, redirected.streaming?
  refused = Cybertrain::Response.new
  refused.body_writer = ThreeChunks.new
  raised = false
  begin
    refused.redirect("/next\r\nX: y", 303)
  rescue ArgumentError
    raised = true
  end
  assert_equal true, raised
  assert_equal true, refused.streaming?
end

test "a client that never reads ends the stream when a write times out" do
  SEEN.pop until SEEN.empty?
  sock = TCPSocket.new("127.0.0.1", SERVER.port)
  sock.write("GET /flood HTTP/1.1\r\nHost: t\r\n\r\n")
  tries = 0
  while SEEN.empty? && tries < 300
    sleep 0.05
    tries += 1
  end
  sock.close
  assert_equal ["write timed out"], SEEN
end

test "the connection count returns to zero" do
  tries = 0
  while SERVER.open_connections > 0 && tries < 100
    sleep 0.05
    tries += 1
  end
  assert_equal 0, SERVER.open_connections
  SERVER.stop
end

Cybertrain::Test.run!
