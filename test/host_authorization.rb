require "cybertrain/middleware/host_authorization"
require "cybertrain/config"
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

# A request through HostAuthorization built the way Application#build_stack
# builds it from `config` (checked_hosts, the health path exempt).
def config_request(config, method, path, host)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new(method, path, { "host" => host }, ""))
  inner = ProtectedApp.new
  if config.host_check?
    Cybertrain::HostAuthorization.new(inner, config.checked_hosts, config.health_path).call(ctx)
  else
    inner.call(ctx)
  end
  ctx.response
end

def config_in(env, hosts)
  ENV["CYBERTRAIN_ENV"] = env
  ENV["CYBERTRAIN_HOSTS"] = hosts
  ENV.delete("CYBERTRAIN_ALLOWED_HOSTS")
  ENV.delete("CYBERTRAIN_HEALTH_PATH")
  c = Cybertrain::Config.new
  ENV.delete("CYBERTRAIN_HOSTS")
  ENV.delete("CYBERTRAIN_ENV")
  c
end

test "CYBERTRAIN_HOSTS turns the check on outside development; the health path is exempt" do
  prod = config_in("production", " app.example, ,API.example ")
  assert_equal ["app.example", "API.example"], prod.hosts_from_env
  assert_equal ["localhost", "127.0.0.1", "[::1]", "app.example", "API.example"], prod.allowed_hosts
  assert prod.host_check?
  assert_equal "", prod.security_error
  ok = config_request(prod, "GET", "/", "app.example")
  assert_equal 200, ok.status
  assert_equal "private data", ok.body
  assert_equal 200, config_request(prod, "GET", "/", "APP.EXAMPLE:443").status
  assert_equal 200, config_request(prod, "GET", "/", "api.example").status
  blocked = config_request(prod, "GET", "/", "evil.example")
  assert_equal 403, blocked.status
  assert_equal "Blocked host", blocked.body
  assert blocked.cookies.empty?
  assert_equal 403, config_request(prod, "GET", "/", "app.example.evil").status
  assert_equal 403, config_request(prod, "GET", "/", "").status
  # the health probe, by IP or any name, reaches the app; nothing else does
  assert_equal 200, config_request(prod, "GET", "/up", "evil.example").status
  assert_equal 200, config_request(prod, "HEAD", "/up", "10.0.0.7:3000").status
  assert_equal 403, config_request(prod, "POST", "/up", "evil.example").status
  assert_equal 403, config_request(prod, "GET", "/up/", "evil.example").status
  assert_equal 403, config_request(prod, "GET", "/upx", "evil.example").status
  # production and test without CYBERTRAIN_HOSTS: no check, as in Rails
  open = config_in("production", "")
  assert open.hosts_from_env.empty?
  refute open.host_check?
  assert_equal 200, config_request(open, "GET", "/", "evil.example").status
  refute config_in("test", "").host_check?
  assert config_in("test", "app.example").host_check?
  # development keeps checking every path but /up, with or without the variable
  dev = config_in("development", "")
  assert dev.host_check?
  assert_equal 403, config_request(dev, "GET", "/", "evil.example").status
  assert_equal 200, config_request(dev, "GET", "/", "localhost:3000").status
  assert_equal 200, config_request(dev, "GET", "/up", "evil.example").status
  dev_named = config_in("development", "preview.example")
  assert_equal 200, config_request(dev_named, "GET", "/", "preview.example").status
  # an entry config/app.rb adds to hosts_from_env is checked too
  added = config_in("production", "app.example")
  added.hosts_from_env << "late.example"
  assert_equal 200, config_request(added, "GET", "/", "late.example").status
  # an empty health path exempts nothing
  closed = config_in("production", "app.example")
  closed.health_path = ""
  assert_equal 403, config_request(closed, "GET", "/up", "evil.example").status
end

test "a CYBERTRAIN_HOSTS entry that is not a host name stops the boot" do
  ["https://x", "app.example/admin", "*.example", "app.example:8080", "user@app.example", ".example",
   "example.", "-x.example", "a b", "[::1", "[zz]"].each do |entry|
    expected = "CYBERTRAIN_HOSTS: #{entry.inspect} is not a host name (no scheme, path or wildcard)"
    assert_equal expected, config_in("production", "app.example,#{entry}").security_error
  end
  assert_equal "", config_in("production", "app.example,[::1],10.0.0.7,xn--bcher-kva.example").security_error
end

Cybertrain::Test.run!
