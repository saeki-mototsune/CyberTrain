# Cybertrain::HttpClient against real sockets on 127.0.0.1: the framework's
# own Server for ordinary requests, and canned servers (a thread that writes
# fixed bytes) for the framings and failures a well-behaved server never
# sends. Nothing here may hang: every wait the client makes is bounded by
# its timeout, and every wait the canned servers make by wait_readable(5).
# Ports and timings are never printed.
#
# The TLS layer is in the program (cybertrain/net/tls requires Spinel's
# openssl package), so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23). No certificate can be made here (the package
# has no X509), so TLS is tested up to the handshake: against a plain HTTP
# server (the handshake fails) and against a silent one (it times out).
require "socket"
require "stringio"
require "tmpdir"
require "cybertrain/context_handler"
require "cybertrain/http/server"
require "cybertrain/http_client"
require "cybertrain/net/tls"
require "cybertrain/test"
require "cybertrain/test/http_receiver"

class ClientTestApp < Cybertrain::Middleware
  def call(ctx)
    req = ctx.request
    res = ctx.response
    case req.path
    when "/hello"
      res.content_type = "text/plain"
      res.set_header("X-Test", "yes")
      res.body = "hi"
    when "/echo"
      res.content_type = "application/octet-stream"
      res.set_header("X-Method", req.method)
      res.set_header("X-Content-Type", req.header("content-type").to_s)
      res.set_header("X-Token", req.header("x-token").to_s)
      res.set_header("X-Agent", req.header("user-agent").to_s)
      res.set_header("X-Query", req.query_string)
      res.body = req.body
    when "/big"
      res.content_type = "text/plain"
      res.body = "x" * 3000
    when "/probe"
      # Counted: a test that must never reach this server asks for it.
      $probe_hits += 1
      res.content_type = "text/plain"
      res.body = "probed"
    else
      res.status = 404
      res.body = "Not Found"
    end
    nil
  end
end

$log = StringIO.new
$probe_hits = 0
$server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(ClientTestApp.new), port: 0, read_timeout: 2,
                                 logger: Cybertrain::Logger.new($log, :error))
$server.start
$base = "http://127.0.0.1:#{$server.port}"

# What a request ended with: "ok <status>" or the error's kind, and the
# message. The rescue ladder lives in a method that receives the block as a
# Proc (spikes/NOTES.md rule 32) and tells the classes apart by clause
# (rule 47).
class Outcome
  attr_reader :kind, :text

  def initialize(kind, text)
    @kind = kind
    @text = text
  end
end

def outcome(&action)
  begin
    res = action.call
    return Outcome.new("ok #{res.status}", res.body)
  rescue Cybertrain::HttpClient::TooManyRedirectsError => e
    return Outcome.new("too many redirects", e.message)
  rescue Cybertrain::HttpClient::TimeoutError => e
    return Outcome.new("timeout", e.message)
  rescue Cybertrain::HttpClient::RefusedError => e
    return Outcome.new("refused", e.message)
  rescue Cybertrain::HttpClient::TLSError => e
    return Outcome.new("tls", e.message)
  rescue Cybertrain::HttpClient::BlockedAddressError => e
    return Outcome.new("blocked", e.message)
  rescue Cybertrain::HttpClient::TooLargeError => e
    return Outcome.new("too large", e.message)
  rescue Cybertrain::HttpClient::BadResponseError => e
    return Outcome.new("bad response", e.message)
  rescue ArgumentError => e
    return Outcome.new("argument", e.message)
  end
  Outcome.new("none", "")
end

# A server that answers one connection with fixed bytes: it reads the
# request head (bounded waits; only the first bytes unless whole_head),
# then writes each piece, sleeping `gap`
# seconds between pieces, and closes.
class CannedServer
  attr_reader :canned_port

  def initialize(pieces, gap, whole_head = true)
    @listener = TCPServer.new("127.0.0.1", 0)
    @canned_port = @listener.addr[1]
    @pieces = pieces
    @gap = gap
    @whole_head = whole_head
    @received = +""
  end

  def received
    @received
  end

  def start
    listener = @listener
    @thread = Thread.new { serve_one(listener) }
    self
  end

  def url(path)
    "http://127.0.0.1:#{@canned_port}#{path}"
  end

  def serve_one(listener)
    sock = listener.accept
    while @received.index("\r\n\r\n").nil?
      break if sock.wait_readable(5).nil?

      @received << sock.readpartial(16_384)
      break unless @whole_head
    end
    i = 0
    while i < @pieces.size
      sleep(@gap) if i > 0 && @gap > 0
      sock.write(@pieces[i])
      i += 1
    end
    sock.close
    listener.close
    nil
  rescue IOError, SystemCallError
    nil
  end

  def finish
    @thread.join(5)
    nil
  end
end

def canned(response)
  CannedServer.new([response], 0.0).start
end

def private_client(timeout = 2, deadline = 5, max_body = 1_048_576)
  Cybertrain::HttpClient.new(timeout: timeout, deadline: deadline, max_body: max_body, allow_private: true)
end

def elapsed_since(started)
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

def reason_of(ip)
  Cybertrain::Net::Address.blocked_reason(ip)
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# ---- ordinary requests through the framework's own server ------------------

test "GET returns the status, the headers and the body" do
  res = private_client.get("#{$base}/hello")
  assert_equal 200, res.status
  assert res.success?
  assert_equal "hi", res.body
  assert_equal "yes", res.header("X-Test")
  assert_equal "yes", res.headers["x-test"]
  assert_equal "close", res.header("connection")
  assert_nil res.header("x-missing")
end

test "a 404 is a Response, not an error" do
  res = private_client.get("#{$base}/missing")
  assert_equal 404, res.status
  refute res.success?
  assert_equal "Not Found", res.body
end

test "POST sends the body, its type and the caller's headers" do
  body = "café \x00 bytes"
  res = private_client.post("#{$base}/echo?a=1", body, content_type: "text/plain; charset=utf-8",
                                                       headers: { "X-Token" => "t0k3n" })
  assert_equal 200, res.status
  assert_equal body.bytesize, res.body.bytesize
  assert_equal body.bytes, res.body.bytes
  assert_equal "POST", res.header("x-method")
  assert_equal "text/plain; charset=utf-8", res.header("x-content-type")
  assert_equal "t0k3n", res.header("x-token")
  assert_equal "a=1", res.header("x-query")
  assert_equal "cybertrain/#{Cybertrain::VERSION}", res.header("x-agent")
end

test "GET sends no body and keeps the caller's User-Agent" do
  res = private_client.get("#{$base}/echo", headers: { "User-Agent" => "hooks/1" })
  assert_equal "GET", res.header("x-method")
  assert_equal "hooks/1", res.header("x-agent")
  assert_equal "", res.body
end

test "a host name resolves and the address it resolved to is dialled" do
  res = private_client.get("http://localhost:#{$server.port}/hello")
  assert_equal "hi", res.body
end

# How a dial of `endpoint` ended: "connected" or "refused". The rescue is in
# a method of its own (spikes/NOTES.md rule 32).
def dial_kind(endpoint, port)
  label = "127.0.0.1:#{port}"
  timer = Cybertrain::Net::Timer.new(label, 2, 5)
  tcp = Cybertrain::Net::TcpStream.connect_to(endpoint, port, label, timer)
  tcp.stream_close
  "connected"
rescue Cybertrain::Net::ConnectError
  "refused"
end

test "each resolved address is dialled in turn until one connects" do
  # Nothing listens on ::1 at this port (a host without IPv6 cannot even
  # open the socket): the dial moves on to 127.0.0.1, as it does for
  # `localhost` on macOS, where ::1 comes first.
  listening = TCPServer.new("127.0.0.1", 0) # never accept()ed: the kernel completes the handshake
  port = listening.addr[1]
  v6 = Cybertrain::Net.resolve("::1", port, "::1")
  v4 = Cybertrain::Net.resolve("127.0.0.1", port, "127.0.0.1")
  both = Cybertrain::Net::Endpoint.new
  both.offer(v6.endpoint_ip_at(0), v6.endpoint_family_at(0))
  both.offer(v4.endpoint_ip_at(0), v4.endpoint_family_at(0))
  both.offer(v6.endpoint_ip_at(0), v6.endpoint_family_at(0))
  assert_equal 2, both.endpoint_count
  assert_equal "::1", both.endpoint_ip
  assert_equal "connected", dial_kind(both, port)
  # When every address fails, the last one's error is raised.
  assert_equal "refused", dial_kind(v6, port)
  assert_equal "refused", dial_kind(Cybertrain::Net::Endpoint.new, port)
  listening.close
end

test "a Content-Length body larger than max_body is refused before it is read" do
  got = outcome { private_client(2, 5, 1000).get("#{$base}/big") }
  assert_equal "too large", got.kind
  assert_includes got.text, "3000 bytes"
  ok = private_client(2, 5, 3000).get("#{$base}/big")
  assert_equal 3000, ok.body.bytesize
end

# ---- framings, from canned servers ----------------------------------------

test "a chunked body is decoded, extensions and trailers dropped" do
  srv = canned("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n")
  res = private_client.get(srv.url("/chunked"))
  srv.finish
  assert_equal "hello world", res.body
  assert_equal "chunked", res.header("transfer-encoding")
  assert_includes srv.received, "GET /chunked HTTP/1.1\r\n"
  assert_includes srv.received, "Connection: close\r\n"
  assert_includes srv.received, "Host: 127.0.0.1:#{srv.canned_port}\r\n"
end

test "a chunked body that grows past max_body is refused" do
  srv = canned("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n0123456789abcdef\r\n10\r\n0123456789abcdef\r\n0\r\n\r\n")
  got = outcome { private_client(2, 5, 20).get(srv.url("/")) }
  srv.finish
  assert_equal "too large", got.kind
end

test "a body without a length is read to the end of the connection" do
  srv = canned("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nuntil close")
  res = private_client.get(srv.url("/"))
  srv.finish
  assert_equal "until close", res.body
end

test "a body read to the end is capped too" do
  srv = canned("HTTP/1.1 200 OK\r\n\r\n" + ("y" * 500))
  got = outcome { private_client(2, 5, 100).get(srv.url("/")) }
  srv.finish
  assert_equal "too large", got.kind
end

test "a body arriving in pieces is put together" do
  srv = CannedServer.new(["HTTP/1.1 201 Created\r\nContent-", "Length: 10\r\n\r\n01234", "56789"], 0.05).start
  res = private_client.get(srv.url("/"))
  srv.finish
  assert_equal 201, res.status
  assert_equal "0123456789", res.body
end

test "interim 1xx responses are skipped" do
  srv = canned("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
  res = private_client.get(srv.url("/"))
  srv.finish
  assert_equal 200, res.status
  assert_equal "ok", res.body
end

test "repeated headers are joined, names lowercased, values trimmed" do
  srv = canned("HTTP/1.1 200 OK\r\nX-A: one\r\nx-a:  two \t\r\nContent-Length: 0\r\n\r\n")
  res = private_client.get(srv.url("/"))
  srv.finish
  assert_equal "one, two", res.header("X-A")
  assert_equal "", res.body
end

test "a 204 has no body" do
  srv = canned("HTTP/1.1 204 No Content\r\n\r\n")
  res = private_client.get(srv.url("/"))
  srv.finish
  assert_equal 204, res.status
  assert_equal "", res.body
end

test "too many or too large headers are refused" do
  many = +"HTTP/1.1 200 OK\r\n"
  i = 0
  while i < 120
    many << "X-H#{i}: v\r\n"
    i += 1
  end
  many << "\r\n"
  srv = canned(many)
  got = outcome { private_client.get(srv.url("/")) }
  srv.finish
  assert_equal "too large", got.kind
  srv2 = canned("HTTP/1.1 200 OK\r\nX-Long: " + ("z" * 9000) + "\r\n\r\n")
  long = outcome { private_client.get(srv2.url("/")) }
  srv2.finish
  assert_equal "too large", long.kind
end

test "responses that are not HTTP/1.1 are bad responses" do
  srv = canned("SSH-2.0-OpenSSH_9.6\r\n")
  got = outcome { private_client.get(srv.url("/")) }
  srv.finish
  assert_equal "bad response", got.kind
  srv2 = canned("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")
  short = outcome { private_client.get(srv2.url("/")) }
  srv2.finish
  assert_equal "bad response", short.kind
  assert_includes short.text, "before the body was complete"
  srv3 = canned("HTTP/1.1 200 OK\r\nContent-Length: 5, 6\r\n\r\nhello!")
  conflicting = outcome { private_client.get(srv3.url("/")) }
  srv3.finish
  assert_equal "bad response", conflicting.kind
  srv4 = canned("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
  chunk = outcome { private_client.get(srv4.url("/")) }
  srv4.finish
  assert_equal "bad response", chunk.kind
end

# ---- bounded waits ---------------------------------------------------------

test "a server that accepts and never answers is a read timeout" do
  silent = TCPServer.new("127.0.0.1", 0) # never accept()ed: the kernel completes the handshake
  port = silent.addr[1]
  started = now
  got = outcome { private_client(0.3, 5).get("http://127.0.0.1:#{port}/secret/path?token=s3cr3t") }
  assert_equal "timeout", got.kind
  assert elapsed_since(started) < 3.0
  assert_includes got.text, "127.0.0.1:#{port}"
  assert_includes got.text, "timed out after 0.3s"
  assert_nil got.text.index("secret")
  assert_nil got.text.index("s3cr3t")
  silent.close
end

test "the deadline bounds a response that trickles in" do
  pieces = Array.new(0) { "" }
  pieces << "HTTP/1.1 200 OK\r\n"
  i = 0
  while i < 30
    pieces << "X-Slow-#{i}: v\r\n"
    i += 1
  end
  srv = CannedServer.new(pieces, 0.1).start
  started = now
  got = outcome { private_client(1, 0.5).get(srv.url("/")) }
  assert_equal "timeout", got.kind
  assert_includes got.text, "0.5s deadline passed"
  assert elapsed_since(started) < 2.0
  srv.finish
end

# A listener whose backlog is full, so that a further connect to it stays
# pending. Linux queues one connection on a backlog of 0 and drops the SYNs
# of the rest; macOS's kernel can queue more than the backlog asks for, or
# answer the overflow with a reset. Up to 1024 non-blocking connects are
# made; the first three and every 32nd are checked for whether they stayed
# pending, and one that was refused is closed (it holds no slot). Running
# out of descriptors (macOS's default limit is 256) ends the filling.
class FullBacklog
  attr_reader :full_port

  def initialize
    @listener = TCPServer.new("127.0.0.1", 0)
    @listener.listen(0)
    @full_port = @listener.addr[1]
    @fillers = Array.new(0) { Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0) }
    @pending = false
  end

  def pending?
    @pending
  end

  def fill
    fill_queue
    self
  rescue SystemCallError
    self
  end

  def fill_queue
    made = 0
    while made < 1024 && !@pending
      s = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
      s.connect_nonblock(Socket.sockaddr_in(@full_port, "127.0.0.1"), exception: false)
      made += 1
      keep = true
      if made < 4 || made % 32 == 0
        if s.wait_writable(0.2).nil?
          @pending = true
        elsif s.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int != 0
          keep = false
        end
      end
      if keep
        @fillers << s
      else
        s.close
      end
    end
    nil
  end

  def close_all
    @fillers.each { |f| f.close unless f.closed? }
    @fillers = Array.new(0) { Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0) }
    @listener.close unless @listener.closed?
    nil
  end
end

test "a connect that never completes times out" do
  backlog = FullBacklog.new.fill
  if backlog.pending?
    assert backlog.pending?, "the backlog never filled"
    url = "http://127.0.0.1:#{backlog.full_port}/hook/abc"
    wait = 0.3
  else
    # No connect stayed pending: a destination that drops the SYN instead,
    # 192.0.2.1 (TEST-NET-1; a documentation address, which allow_private
    # lets through), on a port nothing serves. The fillers go first: they
    # may hold every descriptor the process has.
    backlog.close_all
    assert_equal "documentation", reason_of("192.0.2.1")
    url = "http://192.0.2.1:9/hook/abc"
    wait = 1.0
  end
  started = now
  got = outcome { private_client(wait, 5).get(url) }
  assert_equal "timeout", got.kind
  assert_includes got.text, "connecting timed out"
  assert elapsed_since(started) < 3.0
  backlog.close_all
end

test "a closed port is refused" do
  gone = TCPServer.new("127.0.0.1", 0)
  port = gone.addr[1]
  gone.close
  got = outcome { private_client.get("http://127.0.0.1:#{port}/hook/abc") }
  assert_equal "refused", got.kind
  assert_includes got.text, "connection refused"
  assert_nil got.text.index("hook")
  # Nothing listens on ::1 here; a host without IPv6 cannot even open the
  # socket. Refused either way.
  assert_equal "refused", outcome { private_client.get("http://[::1]:#{port}/") }.kind
end

test "a name that does not resolve is refused" do
  got = outcome { private_client.get("http://no-such-host.invalid/hook/abc") }
  assert_equal "refused", got.kind
  assert_includes got.text, "could not resolve"
end

test "every error is a HttpClient::Error" do
  gone = TCPServer.new("127.0.0.1", 0)
  port = gone.addr[1]
  gone.close
  caught = "none"
  begin
    private_client.get("http://127.0.0.1:#{port}/")
  rescue Cybertrain::HttpClient::Error => e
    caught = e.class.name.to_s
  end
  assert_includes caught, "RefusedError"
end

# ---- non-public destinations -----------------------------------------------

test "loopback and private destinations are refused by default" do
  client = Cybertrain::HttpClient.new(timeout: 1, deadline: 2)
  refute client.allow_private
  got = outcome { client.get("#{$base}/hello/secret-token") }
  assert_equal "blocked", got.kind
  assert_includes got.text, "loopback"
  assert_includes got.text, "127.0.0.1"
  assert_nil got.text.index("secret-token")
  assert_equal "blocked", outcome { client.get("http://localhost:#{$server.port}/") }.kind
  assert_equal "blocked", outcome { client.get("http://169.254.169.254/latest/meta-data/") }.kind
  assert_equal "blocked", outcome { client.post("http://10.1.2.3/x", "{}") }.kind
  assert_equal "blocked", outcome { client.get("http://[::1]:#{$server.port}/") }.kind
  assert_equal "blocked", outcome { client.get("http://0.0.0.0:#{$server.port}/") }.kind
end

test "the inet_aton spellings of a loopback address never reach it" do
  # "127.1", "0x7f.0.0.1", "0177.0.0.1" and "2130706433" are what inet_aton
  # reads as 127.0.0.1. Net::Address takes only the dotted quad and needs no
  # more: the policy is decided on the address getaddrinfo answers. What it
  # answers is the C library's: glibc reads these spellings as 127.0.0.1,
  # so they are refused as loopback. macOS's resolver does not read them as
  # inet_aton does: "127.1" and "0x7f.0.0.1" are names to it, handed to DNS,
  # where they do not resolve or run past the deadline (and a resolver with
  # a search domain could answer any address for them), and "0177.0.0.1" is
  # read with its leading zero as decimal, an address that is not loopback,
  # which the client may dial as it may any public address. So the
  # assertion is the policy's own claim, made where it can be seen: the
  # server on 127.0.0.1 counts the requests to /probe, and the count does
  # not move. When the spelling was refused, the message names the policy;
  # whatever happened, it never repeats the path.
  client = Cybertrain::HttpClient.new(timeout: 1, deadline: 2)
  hits = $probe_hits
  short = outcome { client.get("http://127.1:#{$server.port}/probe") }
  assert_equal hits, $probe_hits
  if short.kind == "blocked"
    assert_includes short.text, "refusing to connect to"
  else
    assert_nil short.text.index("/probe")
  end
  outcome { client.get("http://0x7f.0.0.1:#{$server.port}/probe") }
  assert_equal hits, $probe_hits
  outcome { client.get("http://0177.0.0.1:#{$server.port}/probe") }
  assert_equal hits, $probe_hits
  outcome { client.get("http://2130706433:#{$server.port}/probe") }
  assert_equal hits, $probe_hits
  assert_equal "not an IP address", reason_of("127.1")
  assert_equal "not an IP address", reason_of("2130706433")
end

test "Config#http_allow_private is the default for allow_private" do
  assert_equal false, Cybertrain.config.http_allow_private
  Cybertrain.config.http_allow_private = true
  client = Cybertrain::HttpClient.new(timeout: 2, deadline: 5)
  Cybertrain.config.http_allow_private = false
  assert client.allow_private
  assert_equal "hi", client.get("#{$base}/hello").body
end

test "address classification" do

  assert_equal "", reason_of("93.184.216.34")
  assert_equal "", reason_of("8.8.8.8")
  assert_equal "", reason_of("2606:2800:220:1:248:1893:25c8:1946")
  assert Cybertrain::Net::Address.public?("1.1.1.1")
  assert_equal "loopback", reason_of("127.0.0.1")
  assert_equal "loopback", reason_of("127.255.0.9")
  assert_equal "loopback", reason_of("::1")
  assert_equal "private", reason_of("10.0.0.1")
  assert_equal "private", reason_of("172.16.0.1")
  assert_equal "private", reason_of("172.31.255.255")
  assert_equal "", reason_of("172.32.0.1")
  assert_equal "private", reason_of("192.168.1.1")
  assert_equal "private", reason_of("fd12:3456::1")
  assert_equal "private", reason_of("fc00::")
  assert_equal "link-local", reason_of("169.254.169.254")
  assert_equal "link-local", reason_of("fe80::1%eth0")
  assert_equal "link-local", reason_of("febf::1")
  assert_equal "unspecified", reason_of("0.0.0.0")
  assert_equal "unspecified", reason_of("0.1.2.3")
  assert_equal "unspecified", reason_of("::")
  assert_equal "multicast", reason_of("224.0.0.1")
  assert_equal "multicast", reason_of("ff02::1")
  assert_equal "broadcast", reason_of("255.255.255.255")
  assert_equal "reserved", reason_of("240.0.0.1")
  assert_equal "shared address space", reason_of("100.64.0.1")
  assert_equal "shared address space", reason_of("100.127.255.255")
  assert_equal "", reason_of("100.128.0.1")
  assert_equal "documentation", reason_of("192.0.2.10")
  assert_equal "documentation", reason_of("2001:db8::1")
  assert_equal "loopback", reason_of("::ffff:127.0.0.1")
  assert_equal "private", reason_of("::ffff:10.0.0.1")
  assert_equal "loopback", reason_of("::ffff:7f00:1")
  assert_equal "", reason_of("::ffff:8.8.8.8")
  assert_equal "link-local", reason_of("64:ff9b::169.254.169.254")
  assert_equal "private", reason_of("2002:c0a8:0101::1")
  assert_equal "not an IP address", reason_of("example.com")
  assert_equal "not an IP address", reason_of("1.2.3")
  assert_equal "not an IP address", reason_of("1.2.3.256")
  assert_equal "not an IP address", reason_of("01.2.3.4")
  assert_equal "not an IP address", reason_of("1:2:3:4:5:6:7:8:9")
  assert_equal "not an IP address", reason_of("1::2::3")
  assert_equal "not an IP address", reason_of("")
  assert_equal [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 10, 0, 0, 1], Cybertrain::Net::Address.parse_ipv6("::ffff:10.0.0.1")
  assert_equal [32, 1, 13, 184, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1], Cybertrain::Net::Address.parse_ipv6("2001:db8::1")
end

# ---- what the client refuses to send --------------------------------------

test "URLs the client does not take, without repeating them" do
  c = private_client
  assert_equal "argument", outcome { c.get("ftp://example.com/secret") }.kind
  assert_equal "argument", outcome { c.get("example.com/secret") }.kind
  userinfo = outcome { c.get("https://user:pass@example.com/secret") }
  assert_equal "argument", userinfo.kind
  assert_nil userinfo.text.index("pass")
  assert_equal "argument", outcome { c.get("http://example.com/a b") }.kind
  assert_equal "argument", outcome { c.get("http://example.com/a\r\nX-Evil: 1") }.kind
  assert_equal "argument", outcome { c.get("http://example.com:0/") }.kind
  assert_equal "argument", outcome { c.get("http://example.com:65536/") }.kind
  assert_equal "argument", outcome { c.get("http://example.com:80a/") }.kind
  assert_equal "argument", outcome { c.get("http:///nohost") }.kind
  assert_equal "argument", outcome { c.get("http://[::1/") }.kind
  bad = outcome { c.get("http://exa mple.com/secret?k=v") }
  assert_nil bad.text.index("secret")
end

test "URLs are split into host, port and request target" do
  t = Cybertrain::HttpClient.parse_url("HTTPS://Hooks.Example.COM/services/T0/B1/xyz?a=1#frag")
  assert t.target_tls
  assert_equal "hooks.example.com", t.target_host
  assert_equal 443, t.target_port
  assert_equal "/services/T0/B1/xyz?a=1", t.request_target
  assert_equal "hooks.example.com", t.host_header
  assert_equal "hooks.example.com:443", t.target_label
  u = Cybertrain::HttpClient.parse_url("http://[2001:db8::1]:8080?q=1")
  refute u.target_tls
  assert_equal "2001:db8::1", u.target_host
  assert_equal 8080, u.target_port
  assert_equal "/?q=1", u.request_target
  assert_equal "[2001:db8::1]:8080", u.host_header
  assert_equal "[2001:db8::1]:8080", u.target_label
  v = Cybertrain::HttpClient.parse_url("http://example.com")
  assert_equal "/", v.request_target
  assert_equal 80, v.target_port
end

test "headers the client owns or cannot send are refused" do
  c = private_client
  assert_equal "argument", outcome { c.get("#{$base}/echo", headers: { "Host" => "evil" }) }.kind
  assert_equal "argument", outcome { c.get("#{$base}/echo", headers: { "Content-Length" => "5" }) }.kind
  assert_equal "argument", outcome { c.get("#{$base}/echo", headers: { "X-A" => "a\r\nX-B: b" }) }.kind
  assert_equal "argument", outcome { c.get("#{$base}/echo", headers: { "Bad Name" => "v" }) }.kind
  assert_equal "argument", outcome { c.post("#{$base}/echo", "", headers: { "content-type" => "text/plain" }) }.kind
end

test "timeouts must be positive" do
  assert_equal "argument", outcome { Cybertrain::HttpClient.new(timeout: 0) }.kind
end

# ---- TLS, up to the handshake ----------------------------------------------

test "https to a server that does not speak TLS fails the handshake" do
  # What a plain HTTP server answers a ClientHello with, at once.
  srv = CannedServer.new(["HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"], 0.0, false).start
  got = outcome { private_client.get("https://127.0.0.1:#{srv.canned_port}/hook/secret") }
  srv.finish
  assert_equal "tls", got.kind
  assert_includes got.text, "TLS handshake failed"
  assert_includes got.text, "127.0.0.1:#{srv.canned_port}"
  assert_nil got.text.index("secret")
end

# Accepts one connection and holds it without writing a byte until
# `release` (at most 5 s): a TLS client waits for a ServerHello that never
# comes. The same on every platform, unlike a connection left in the
# listen queue.
class HoldingServer
  attr_reader :holding_port

  def initialize
    @listener = TCPServer.new("127.0.0.1", 0)
    @holding_port = @listener.addr[1]
    @released = false
  end

  def start
    listener = @listener
    @thread = Thread.new { hold_one(listener) }
    self
  end

  def hold_one(listener)
    sock = listener.accept
    waited = 0
    while !@released && waited < 50
      sleep(0.1)
      waited += 1
    end
    sock.close
    listener.close
    nil
  rescue IOError, SystemCallError
    nil
  end

  def release
    @released = true
    @thread.join(5)
    nil
  end
end

test "a TLS handshake that gets no answer times out" do
  holder = HoldingServer.new.start
  started = now
  got = outcome { private_client(0.3, 5).get("https://127.0.0.1:#{holder.holding_port}/") }
  holder.release
  assert_equal "timeout", got.kind
  assert_includes got.text, "in the TLS handshake timed out"
  assert elapsed_since(started) < 3.0
end

test "the TLS connector is installed by requiring cybertrain/net/tls" do
  assert_includes Cybertrain::Net.tls_connector.class.name.to_s, "OpenSSLConnector"
end

test "without cybertrain/net/tls, https says what to require" do
  label = "127.0.0.1:#{$server.port}"
  timer = Cybertrain::Net::Timer.new(label, 2, 5)
  endpoint = Cybertrain::Net.resolve("127.0.0.1", $server.port, label)
  tcp = Cybertrain::Net::TcpStream.connect_to(endpoint, $server.port, label, timer)
  message = ""
  begin
    Cybertrain::Net::TlsConnector.new.tls_wrap(tcp, "127.0.0.1", timer)
  rescue Cybertrain::Net::TlsError => e
    message = e.message
  end
  assert_includes message, "require \"cybertrain/net/tls\""
  assert tcp.tcp_socket.closed?
end

# ---- every verb, streamed bodies, files, redirects, JSON -------------------

TMP = Dir.mktmpdir("cybertrain-http-client")

at_exit do
  Dir.children(TMP).each { |child| File.delete("#{TMP}/#{child}") }
  Dir.rmdir(TMP)
end

def receiver(max = 1)
  Cybertrain::Test::HttpReceiver.new(max: max)
end

def redirecting_client(redirects)
  Cybertrain::HttpClient.new(timeout: 2, deadline: 5, allow_private: true, redirects: redirects)
end

test "request sends PUT, PATCH, DELETE and HEAD" do
  rx = receiver(4)
  rx.respond_with(status: 200, body: "answer")
  rx.start
  c = private_client
  put = c.request("PUT", rx.url("/items/1"), body: "{\"a\":1}", content_type: "application/json")
  patch = c.request("PATCH", rx.url("/items/1?x=2"), body: "p")
  deleted = c.request("DELETE", rx.url("/items/1"))
  head = c.request("HEAD", rx.url("/items/1"))
  reqs = rx.received_requests(4)
  rx.stop
  # Content-Type accompanies a body only.
  bodiless = receiver
  bodiless.start
  c.request("DELETE", bodiless.url("/items/2"), content_type: "application/json")
  gone = bodiless.received_request
  bodiless.stop
  assert_equal "DELETE", gone.http_method
  assert_equal "", gone.http_header("Content-Type")
  assert_equal "", gone.http_header("Content-Length")
  assert_equal 4, reqs.size
  assert_equal "PUT", reqs[0].http_method
  assert_equal "{\"a\":1}", reqs[0].http_body
  assert_equal "application/json", reqs[0].http_header("Content-Type")
  assert_equal "7", reqs[0].http_header("Content-Length")
  assert_equal "PATCH", reqs[1].http_method
  assert_equal "/items/1?x=2", reqs[1].http_target
  assert_equal "p", reqs[1].http_body
  assert_equal "", reqs[1].http_header("Content-Type")
  assert_equal "DELETE", reqs[2].http_method
  assert_equal "", reqs[2].http_body
  assert_equal "HEAD", reqs[3].http_method
  assert_equal "answer", put.body
  assert_equal "answer", patch.body
  assert_equal 200, deleted.status
  assert_equal 200, head.status
  assert_equal "", head.body
  assert_equal "6", head.header("content-length")
  assert_equal 0, put.bytes_written
  trace = outcome { c.request("TRACE", "http://example.com/") }
  assert_equal "argument", trace.kind
  assert_includes trace.text, "TRACE"
  assert_equal "argument", outcome { c.request("GET", "http://example.com/", body: "x") }.kind
end

test "the block form yields chunks and leaves body empty; max_body does not apply" do
  mib = "z" * 1_048_576
  rx = receiver
  rx.respond_with(status: 200, chunks: [mib, mib, mib])
  rx.start
  sizes = Array.new(0) { 0 }
  res = private_client(2, 10, 1_048_576).get(rx.url("/stream")) { |chunk| sizes << chunk.bytesize }
  rx.stop
  assert_equal 200, res.status
  assert_equal "", res.body
  assert_equal 3, sizes.size
  assert_equal 3 * 1_048_576, sizes.sum
  assert_equal 0, res.bytes_written
  # By length, past max_body as well, through request.
  rx2 = receiver
  rx2.respond_with(status: 200, body: "q" * 5000)
  rx2.start
  total = Array.new(0) { 0 }
  res2 = private_client(2, 5, 100).request("GET", rx2.url("/len")) { |chunk| total << chunk.bytesize }
  rx2.stop
  assert_equal "", res2.body
  assert_equal 5000, total.sum
end

class StreamStop < StandardError
end

# How a streamed GET whose block raises on the first chunk ended: the
# exception's class name and message. The rescue is in a method of its own
# (rule 32).
def stopped_stream(client, url)
  client.get(url) do |chunk|
    raise StreamStop, "stopped at #{chunk.bytesize} bytes" if chunk.bytesize > 0
    nil
  end
  Outcome.new("none", "")
rescue StreamStop => e
  Outcome.new(e.class.name.to_s, e.message)
rescue Cybertrain::HttpClient::Error => e
  Outcome.new("client error", e.message)
end

test "an exception raised in the streamed block propagates unchanged" do
  piece = "s" * 65_536
  rx = receiver
  rx.respond_with(status: 200, chunks: [piece, piece, piece, piece])
  rx.start
  stopped = stopped_stream(private_client, rx.url("/stream"))
  rx.stop
  assert_includes stopped.kind, "StreamStop"
  assert_equal "stopped at 65536 bytes", stopped.text
  # The client is usable afterwards (the stream was closed by exchange's
  # ensure; the receiver's API cannot show its side of the close).
  rx2 = receiver
  rx2.respond_with(status: 200, body: "after")
  rx2.start
  after = private_client.get(rx2.url("/"))
  rx2.stop
  assert_equal "after", after.body
end

test "get_to_file writes the body through a .part file" do
  path = "#{TMP}/download.bin"
  rx = receiver
  rx.respond_with(status: 200, body: "w" * 5000)
  rx.start
  res = private_client(2, 5, 100).get_to_file(rx.url("/file"), path, headers: { "X-Token" => "t" })
  req = rx.received_request
  rx.stop
  assert_equal 200, res.status
  assert_equal "", res.body
  assert_equal 5000, res.bytes_written
  assert_equal 5000, File.size(path)
  refute File.exist?("#{path}.part")
  assert_equal "t", req.http_header("X-Token")
  rx2 = receiver
  rx2.respond_with(status: 200, chunks: ["ab", "cd", "ef"])
  rx2.start
  res2 = private_client.get_to_file(rx2.url("/file"), path)
  rx2.stop
  assert_equal 6, res2.bytes_written
  assert_equal "abcdef", File.read(path)
  # A body cut short: the error is raised, the .part is gone and the file
  # already at `path` is untouched.
  srv = canned("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort")
  got = outcome { private_client.get_to_file(srv.url("/"), path) }
  srv.finish
  assert_equal "bad response", got.kind
  refute File.exist?("#{path}.part")
  assert_equal "abcdef", File.read(path)
  # A 404 page never reaches the disk: counted, not written, and the file
  # already at `path` is untouched.
  rx3 = receiver
  rx3.respond_with(status: 404, body: "Not Found here")
  rx3.start
  missing = private_client.get_to_file(rx3.url("/gone"), path)
  rx3.stop
  assert_equal 404, missing.status
  assert_equal "", missing.body
  assert_equal 14, missing.bytes_written
  refute File.exist?("#{path}.part")
  assert_equal "abcdef", File.read(path)
end

test "redirects: follows 302 then 301 to GET, keeps 307 as POST with the body, and stops at the limit" do
  c3 = receiver
  c3.respond_with(status: 200, body: "landed")
  c3.start
  b2 = receiver
  b2.respond_with(status: 301, redirect_to: c3.url("/c"))
  b2.start
  a1 = receiver
  a1.respond_with(status: 302, redirect_to: b2.url("/b?k=1"))
  a1.start
  res = redirecting_client(3).post(a1.url("/a"), "{\"n\":1}", headers: { "X-Token" => "t", "Authorization" => "Bearer s" })
  first = a1.received_request
  second = b2.received_request
  third = c3.received_request
  a1.stop
  b2.stop
  c3.stop
  assert_equal 200, res.status
  assert_equal "landed", res.body
  assert_equal "POST", first.http_method
  assert_equal "{\"n\":1}", first.http_body
  assert_equal "GET", second.http_method
  assert_equal "/b?k=1", second.http_target
  assert_equal "", second.http_body
  assert_equal "", second.http_header("Content-Type")
  assert_equal "", second.http_header("Content-Length")
  assert_equal "t", second.http_header("X-Token")
  # Another origin (another port): the credentials stay behind.
  assert_equal "Bearer s", first.http_header("Authorization")
  assert_equal "", second.http_header("Authorization")
  assert_equal "GET", third.http_method
  assert_equal "/c", third.http_target

  e5 = receiver
  e5.respond_with(status: 201, body: "kept")
  e5.start
  d4 = receiver
  d4.respond_with(status: 307, redirect_to: e5.url("/e"))
  d4.start
  kept = redirecting_client(1).post(d4.url("/d"), "{\"n\":2}")
  fifth = e5.received_request
  d4.stop
  e5.stop
  assert_equal 201, kept.status
  assert_equal "POST", fifth.http_method
  assert_equal "{\"n\":2}", fifth.http_body
  assert_equal "application/json", fifth.http_header("Content-Type")

  s7 = receiver
  s7.respond_with(status: 200, body: "seen")
  s7.start
  s6 = receiver
  s6.respond_with(status: 303, redirect_to: s7.url("/s"))
  s6.start
  seen = redirecting_client(1).request("PUT", s6.url("/p"), body: "data", content_type: "text/plain")
  seventh = s7.received_request
  s6.stop
  s7.stop
  assert_equal "seen", seen.body
  assert_equal "GET", seventh.http_method
  assert_equal "", seventh.http_body

  f8 = receiver
  f8.start
  g9 = receiver
  g9.respond_with(status: 302, redirect_to: f8.url("/f"))
  g9.start
  h10 = receiver
  h10.respond_with(status: 302, redirect_to: g9.url("/g"))
  h10.start
  limited = outcome { redirecting_client(1).get(h10.url("/h/secret")) }
  h10.stop
  g9.stop
  f8.stop
  assert_equal "too many redirects", limited.kind
  assert_includes limited.text, "1 redirect"
  assert_includes limited.text, "127.0.0.1:#{g9.port}"
  assert_nil limited.text.index("secret")
  assert_equal 0, f8.received_requests(0, 0.1).size

  # redirects: 0 (the default) returns the 3xx; a 3xx without Location is
  # returned as is.
  r11 = receiver(2)
  r11.respond_with(status: 302, redirect_to: "/elsewhere")
  r11.start
  plain = private_client.get(r11.url("/"))
  assert_equal 302, plain.status
  assert_equal "/elsewhere", plain.header("location")
  r11.respond_with(status: 302, body: "no location")
  bare = redirecting_client(2).get(r11.url("/"))
  r11.stop
  assert_equal 302, bare.status
  assert_equal "no location", bare.body
end

test "redirects: relative Location and a loop" do
  rel = receiver(2)
  rel.respond_with(status: 302, redirect_to: "/other?q=1")
  rel.start
  looped = outcome { redirecting_client(1).get(rel.url("/start/here")) }
  reqs = rel.received_requests(2)
  rel.stop
  assert_equal "too many redirects", looped.kind
  assert_equal 2, reqs.size
  assert_equal "/start/here", reqs[0].http_target
  assert_equal "/other?q=1", reqs[1].http_target

  ping = receiver(2)
  pong = receiver(2)
  ping.start
  pong.start
  ping.respond_with(status: 301, redirect_to: pong.url("/pong"))
  pong.respond_with(status: 308, redirect_to: ping.url("/ping"))
  both = outcome { redirecting_client(3).get(ping.url("/ping")) }
  pings = ping.received_requests(2)
  pongs = pong.received_requests(2)
  ping.stop
  pong.stop
  assert_equal "too many redirects", both.kind
  assert_includes both.text, "3 redirects"
  assert_equal 2, pings.size
  assert_equal 2, pongs.size

  # The deadline covers every hop: a first hop that takes 0.6 s leaves 0.4 s
  # of a 1 s deadline to a second that never answers.
  holder = HoldingServer.new.start
  slow = CannedServer.new(["HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:#{holder.holding_port}/x\r\n",
                           "Content-Length: 0\r\n\r\n"], 0.6).start
  started = now
  late = outcome { Cybertrain::HttpClient.new(timeout: 2, deadline: 1, allow_private: true, redirects: 2).get(slow.url("/")) }
  waited = elapsed_since(started)
  slow.finish
  holder.release
  assert_equal "timeout", late.kind
  assert_includes late.text, "deadline passed"
  assert waited < 1.4, "the second hop had a deadline of its own"

  h = Cybertrain::HttpClient
  assert_equal "http://h:1/c", h.resolve_location("http://h:1/a/b?x=1#f", "/c")
  assert_equal "http://h/a/c", h.resolve_location("http://h/a/b", "c")
  assert_equal "http://h/c", h.resolve_location("http://h/a/b", "../c")
  assert_equal "http://h/a/d", h.resolve_location("http://h/a/b", "./c/../d")
  assert_equal "http://h/a/b?y=2", h.resolve_location("http://h/a/b?x", "?y=2")
  assert_equal "https://o/p", h.resolve_location("http://h/a", "https://o/p#frag")
  assert_equal "https://o/p", h.resolve_location("https://h/a", "//o/p")
  assert_equal "http://h/c", h.resolve_location("http://h", "c")
  assert_equal "http://h/c", h.resolve_location("http://h?x=1", "c")
  assert_equal "http://h/x/", h.resolve_location("http://h/x/y", ".")
end

# How following `location` from `current` ended: the next URL, or the
# error's kind and message. The rescue is in a method of its own (rule 32).
def hop_outcome(current, location)
  Outcome.new("ok", Cybertrain::HttpClient.next_hop(current, location))
rescue Cybertrain::HttpClient::BlockedAddressError => e
  Outcome.new("blocked", e.message)
rescue Cybertrain::HttpClient::BadResponseError => e
  Outcome.new("bad response", e.message)
end

test "a redirect from https to http is refused" do
  down = hop_outcome("https://secure.example.com/a/secret", "http://plain.example.com:8080/b?token=s3cr3t")
  assert_equal "blocked", down.kind
  assert_includes down.text, "plain.example.com:8080"
  assert_includes down.text, "https to http"
  assert_nil down.text.index("secret")
  assert_nil down.text.index("token")
  up = hop_outcome("http://plain.example.com/a", "https://secure.example.com/b")
  assert_equal "ok", up.kind
  assert_equal "https://secure.example.com/b", up.text
  same = hop_outcome("https://secure.example.com/a", "/b")
  assert_equal "https://secure.example.com/b", same.text
  odd = hop_outcome("https://secure.example.com/a", "ftp://files.example.com/secret")
  assert_equal "bad response", odd.kind
  assert_nil odd.text.index("secret")
end

test "json_hash and json_array parse the body and answer {} / [] otherwise" do
  rx = receiver(3)
  rx.respond_with(status: 200, body: "{\"a\":1,\"b\":[1,2],\"c\":\"x\"}")
  rx.start
  obj = private_client.get(rx.url("/obj"))
  rx.respond_with(status: 200, body: "[1,\"two\",{\"k\":3}]")
  arr = private_client.get(rx.url("/arr"))
  rx.respond_with(status: 200, body: "not json")
  text = private_client.get(rx.url("/text"))
  rx.stop
  doc = obj.json_hash
  assert_equal 3, doc.size
  assert_equal 1, doc["a"]
  assert_equal "x", doc["c"]
  assert_equal 0, obj.json_array.size
  list = arr.json_array
  assert_equal 3, list.size
  assert_equal "two", list[1]
  assert_equal 0, arr.json_hash.size
  assert_equal 0, text.json_hash.size
  assert_equal 0, text.json_array.size
end

Cybertrain::Test.run!
