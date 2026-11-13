require "cybertrain/test"
require "cybertrain/cli/dev_server/holding"
require "socket"

# The page `cybertrain server` answers with while no child can serve
# (cybertrain/cli/dev_server/holding.rb). CRuby only.

Holding = Cybertrain::CLI::DevServer::Holding

def split(response)
  head, body = response.split("\r\n\r\n", 2)
  [head, body]
end

test "the page is a complete 503 response that closes the connection" do
  head, body = split(Holding.page("gen failed", "boom", "a saved change"))
  lines = head.split("\r\n")
  assert_equal "HTTP/1.1 503 Service Unavailable", lines[0]
  assert_includes lines, "Retry-After: 1"
  assert_includes lines, "Connection: close"
  assert_includes lines, "Content-Type: text/html; charset=utf-8"
  assert_includes lines, "Content-Length: #{body.bytesize}"
end

test "the body has the title, the text, what the server waits for, the refresh and --spinel" do
  _head, body = split(Holding.page("the CRuby preview stopped", "SyntaxError: x", "a saved change"))
  assert_includes body, "<title>the CRuby preview stopped</title>"
  assert_includes body, "<h1>the CRuby preview stopped</h1>"
  assert_includes body, "<pre>SyntaxError: x</pre>"
  assert_includes body, "Waiting for: a saved change"
  assert_includes body, "<meta http-equiv=\"refresh\" content=\"2\">"
  assert_includes body, "cybertrain server --spinel runs the compiled loop only."
end

test "the text, the title and the wait are escaped" do
  _head, body = split(Holding.page("<b>", "<script>alert(1)</script> & \"q\"", "<i>"))
  refute body.include?("<script>alert"), "the text is escaped"
  assert_includes body, "&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;"
  assert_includes body, "<h1>&lt;b&gt;</h1>"
  assert_includes body, "Waiting for: &lt;i&gt;"
end

test "Content-Length counts bytes, not characters" do
  head, body = split(Holding.page("état", "café · ünïcode", "a saved change"))
  assert_includes head.split("\r\n"), "Content-Length: #{body.bytesize}"
  refute body.bytesize == body.size, "the body has multibyte characters"
end

# The desk: what the supervisor does with connections while it holds.

def held_exchange
  listener = TCPServer.new("127.0.0.1", 0)
  desk = Holding::Desk.new
  yield listener, desk
ensure
  desk&.close
  listener&.close
end

def read_all(socket, seconds = 2)
  answer = +""
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    IO.select([socket], nil, nil, 0.05)
    chunk = socket.read_nonblock(65_536, exception: false)
    return answer if chunk.nil?

    answer << chunk if chunk.is_a?(String)
    return answer if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end

test "the desk answers a connection once its request head is in, then closes it" do
  held_exchange do |listener, desk|
    page = Holding.page("gen failed", "boom", "a saved change")
    client = TCPSocket.new("127.0.0.1", listener.addr[1])
    client.write("GET / HTTP/1.1\r\nHost: x")
    sleep 0.05
    desk.accept(listener)
    desk.serve(page)
    assert IO.select([client], nil, nil, 0.1).nil?, "no answer before the head is complete"
    client.write("\r\n\r\n")
    sleep 0.05
    desk.serve(page)
    assert_equal page, read_all(client)
    client.close
    sleep 0.05
    desk.drain
    assert_equal [], desk.ios
  end
end

test "flush answers every waiting connection at once, head or not" do
  held_exchange do |listener, desk|
    page = Holding.page("t", "x", "y")
    client = TCPSocket.new("127.0.0.1", listener.addr[1])
    sleep 0.05
    desk.accept(listener)
    desk.serve(page)
    desk.flush(page)
    assert_equal page, read_all(client)
    client.close
  end
end

# A page far larger than the socket's buffers: written as the client takes
# it, over several ticks, never blocking the desk.
BIG_TEXT = "x" * 4_000_000

def small_buffers(listener)
  listener.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDBUF, 4096)
  client = Socket.new(:INET, :STREAM)
  client.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVBUF, 4096)
  client.connect(Socket.sockaddr_in(listener.addr[1], "127.0.0.1"))
  client
end

test "a client that does not read the page does not block the desk, and is closed after the write wait" do
  listener = TCPServer.new("127.0.0.1", 0)
  desk = Holding::Desk.new(0.3)
  client = small_buffers(listener)
  client.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
  sleep 0.05
  page = Holding.page("t", BIG_TEXT, "y")
  desk.accept(listener)
  server = Thread.new { desk.serve(page) }
  unless server.join(2)
    client.close
    server.join
    flunk "serve blocked on a client that does not read"
  end
  assert desk.connections == 1, "the page is still being written"
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
  until desk.connections.zero? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    desk.drain
    sleep 0.02
  end
  assert_equal 0, desk.connections
ensure
  client&.close
  desk&.close
  listener&.close
end

# Nothing reads a connection while its page is being written, so it is not
# one to wake the driver for: a client that pipelines a second request, or
# half-closes, would keep it readable, and the driver would spin until the
# write wait instead of sleeping its tick.
test "a connection whose page is still being written is not in the read set" do
  listener = TCPServer.new("127.0.0.1", 0)
  desk = Holding::Desk.new(0.5)
  client = small_buffers(listener)
  client.write("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET /again HTTP/1.1\r\nHost: x\r\n\r\n")
  client.close_write
  sleep 0.05
  desk.accept(listener)
  desk.serve(Holding.page("t", BIG_TEXT, "y"))
  assert desk.connections == 1, "the page is still being written"
  assert_equal [], desk.ios
  waited = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  IO.select([listener] + desk.ios, nil, nil, 0.1)
  assert Process.clock_gettime(Process::CLOCK_MONOTONIC) - waited >= 0.09, "the select slept its timeout"
ensure
  client&.close
  desk&.close
  listener&.close
end

test "a page larger than the socket's buffers reaches a client that reads it" do
  listener = TCPServer.new("127.0.0.1", 0)
  desk = Holding::Desk.new
  client = small_buffers(listener)
  client.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
  sleep 0.05
  # Many times the buffers, small enough to pass within the write wait.
  page = Holding.page("t", "x" * 400_000, "y")
  reader = Thread.new { client.read }
  desk.accept(listener)
  desk.serve(page)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
  while reader.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    desk.drain
    sleep 0.005
  end
  client.close_write unless reader.join(0)
  assert_equal page.bytesize, reader.value.bytesize
ensure
  client&.close
  desk&.close
  listener&.close
end

Cybertrain::Test.run!
