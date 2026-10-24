require "cybertrain/middleware/host_authorization"
require "cybertrain/test"

class ProtectedApp < Cybertrain::Middleware
  def call(ctx)
    ctx.response.body = "private data"
    ctx.response.add_cookie("session=private")
    nil
  end
end

def guarded_request(headers, hosts = ["localhost", "127.0.0.1", "[::1]"])
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", headers, ""))
  Cybertrain::HostAuthorization.new(ProtectedApp.new, hosts).call(ctx)
  ctx.response
end

test "explicit loopback hosts accept case differences and numeric ports" do
  ["localhost", "LOCALHOST:3000", "127.0.0.1", "127.0.0.1:4000", "[::1]", "[::1]:3000"].each do |host|
    res = guarded_request({ "Host" => host })
    assert_equal 200, res.status
    assert_equal "private data", res.body
  end
end

test "untrusted and misleading authorities cannot reach the app or its cookies" do
  ["rebind.example", "localhost.evil", "localhost.evil:3000", "evil.localhost", "127.0.0.1.evil",
   "localhost@evil", "evil@localhost", "http://localhost", "localhost/evil", "localhost#evil",
   "localhost:3000.evil", "localhost:evil", "localhost:", "localhost:65536", "localhost:000000",
   "localhost:3000:4000", "localhost, evil", "localhost, localhost", " localhost", "localhost ",
   "[::1].evil", "[::1]:3000.evil", "::1", "0.0.0.0", "127.0.0.2", "", "localhost\x00.evil"].each do |host|
    res = guarded_request({ "host" => host })
    assert_equal 403, res.status
    assert_equal "Blocked host", res.body
    assert res.cookies.empty?
  end
end

test "missing Host fails closed even with trusted forwarding headers" do
  res = guarded_request({ "x-forwarded-host" => "localhost", "forwarded" => "host=localhost" })
  assert_equal 403, res.status
  assert res.cookies.empty?
  assert_equal 403, guarded_request({ "host" => "evil", "x-forwarded-host" => "localhost" }).status
end

test "duplicate Host headers joined by the parser are rejected" do
  head = Cybertrain::HttpParser.parse_head("GET / HTTP/1.1\r\nHost: localhost\r\nHost: evil")
  assert_equal 403, guarded_request(head.headers).status
end

test "forwarding hostnames require exact configuration without wildcards" do
  hosts = ["localhost", "Preview.Example"]
  assert_equal 200, guarded_request({ "host" => "preview.example:3000" }, hosts).status
  assert_equal 403, guarded_request({ "host" => "other.example" }, hosts).status
  assert_equal 403, guarded_request({ "host" => "preview.example.evil" }, hosts).status
  assert_equal 403, guarded_request({ "host" => "sub.preview.example" }, hosts).status
  assert_equal 403, guarded_request({ "host" => "preview.example" }, ["*.example"]).status
end

test "empty allowlists and empty entries deny requests" do
  assert_equal 403, guarded_request({ "host" => "localhost" }, Array.new(0) { "" }).status
  assert_equal 403, guarded_request({ "host" => ":3000" }, [""]).status
end

Cybertrain::Test.run!
