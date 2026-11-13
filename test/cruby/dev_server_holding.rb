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

Cybertrain::Test.run!
