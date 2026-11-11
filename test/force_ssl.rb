# Config#force_ssl (spec C-11, plan decision 21): SslRedirect sends http
# to https (301 for GET and HEAD, 307 otherwise) with the path and query
# kept and the host taken from a valid Host only; an https request (by
# X-Forwarded-Proto) gets Strict-Transport-Security; the health path is
# never redirected; cookies are Secure. With CYBERTRAIN_HOSTS the host
# check sits outside the redirect. Through a booted Application and
# Cybertrain::Test::Client.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "stringio"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"
require "cybertrain/test/client"

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)
ENV.delete("CYBERTRAIN_HOSTS")
ENV.delete("CYBERTRAIN_FORCE_SSL")

def build_config(hosts)
  ENV["CYBERTRAIN_FORCE_SSL"] = "1"
  ENV["CYBERTRAIN_HOSTS"] = hosts
  c = Cybertrain::Config.new
  ENV.delete("CYBERTRAIN_FORCE_SSL")
  ENV.delete("CYBERTRAIN_HOSTS")
  c.env = "test"
  c.session_secure = false
  c.database_path = ":memory:"
  c.pool_size = 1
  c.secret_key_base = "force-ssl-test-secret"
  c.log_level = :none
  c
end

class PagesController < Cybertrain::Controller
  def index
    session[:seen] = "1"
    render plain: "home"
  end

  def create
    render plain: "created"
  end
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/a", "a") { |ctx| PagesController.new(ctx).process(:index) { |c| c.index } }
ROUTER.post("/a", "a_create") { |ctx| PagesController.new(ctx).process(:create) { |c| c.create } }

def build_app(config)
  Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args, options) { "/" }, config: config)
end

CONFIG = build_config("")
APP = build_app(CONFIG)
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)
HTTPS = { "host" => "example.com", "x-forwarded-proto" => "https" }
HSTS = "max-age=63072000; includeSubDomains"

def stack_names(app)
  names = Array.new(0) { "" }
  node = app.stack
  until node.nil?
    names << node.class.name
    node = node.app
  end
  names
end

def get(path, host)
  CLIENT.get(path, { "host" => host })
end

test "force_ssl redirects http and sends HSTS" do
  moved = get("/a?b=1", "example.com")
  assert_equal 301, moved.status
  assert_equal "https://example.com/a?b=1", moved.header("Location").to_s
  assert_nil moved.header("Strict-Transport-Security")
  assert moved.cookies.empty?
  posted = CLIENT.post("/a", { "x" => "1" }, { "host" => "example.com" })
  assert_equal 307, posted.status
  assert_equal "https://example.com/a", posted.header("Location").to_s
  head = CLIENT.request("HEAD", "/a", "", { "host" => "example.com" })
  assert_equal 301, head.status
  secure = CLIENT.get("/a", HTTPS)
  assert_equal 200, secure.status
  assert_equal "home", secure.body
  assert_equal HSTS, secure.header("Strict-Transport-Security").to_s
  up = get("/up", "example.com")
  assert_equal 200, up.status
  assert_equal "ok", up.body
  assert_nil up.header("Strict-Transport-Security")
  assert_equal HSTS, CLIENT.get("/up", HTTPS).header("Strict-Transport-Security").to_s
  # an https 404 carries HSTS too; a POST to /up over http is redirected
  assert_equal HSTS, CLIENT.get("/nowhere", HTTPS).header("Strict-Transport-Security").to_s
  assert_equal 307, CLIENT.post("/up", {}, { "host" => "example.com" }).status
end

test "the X-Forwarded-Proto value is compared as a word" do
  assert_equal 200, CLIENT.get("/a", { "host" => "example.com", "x-forwarded-proto" => " HTTPS " }).status
  assert_equal 301, CLIENT.get("/a", { "host" => "example.com", "x-forwarded-proto" => "http" }).status
  assert_equal 301, CLIENT.get("/a", { "host" => "example.com", "x-forwarded-proto" => "https, http" }).status
  assert_equal 301, CLIENT.get("/a", { "host" => "example.com", "x-forwarded-proto" => "httpsx" }).status
end

test "the redirect keeps a port other than 80 and 443, lowercases the host, and never follows a bad Host" do
  assert_equal "https://example.com:8443/a", get("/a", "Example.COM:8443").header("Location").to_s
  assert_equal "https://example.com/a", get("/a", "example.com:80").header("Location").to_s
  assert_equal "https://example.com/a", get("/a", "example.com:443").header("Location").to_s
  assert_equal "https://[::1]:3000/a", get("/a", "[::1]:3000").header("Location").to_s
  assert_equal "https://10.0.0.7/a", get("/a", "10.0.0.7").header("Location").to_s
  # the path is kept as sent: a leading // cannot change the host
  assert_equal "https://example.com//evil.example/x", get("//evil.example/x", "example.com").header("Location").to_s
  ["", "evil.example/x", "evil.example@x", "user@evil.example", "evil.example:", "evil.example:99999",
   "evil.example:80:80", "evil.example:8a", "evil example", "evil.example\\x", "*.example", "[::1", "[::1]x",
   "https://evil.example", "evil.example#x", "evil.example?x", ".evil.example"].each do |host|
    bad = get("/a", host)
    assert_equal 400, bad.status
    assert_equal "Bad Request", bad.body
    assert_nil bad.header("Location")
  end
end

test "cookies are Secure under force_ssl" do
  res = Cybertrain::Test::Client.new(APP).get("/a", HTTPS)
  cookie = res.cookies.first.to_s
  assert_includes cookie, "_cybertrain_session="
  assert_includes cookie, "; Secure"
end

test "the stack: the host check outside the redirect, both off without their settings" do
  assert_equal ["Cybertrain::SslRedirect", "Cybertrain::Stream::Endpoint", "Cybertrain::HealthCheck", "Cybertrain::Static",
                "Cybertrain::MethodOverride", "Cybertrain::SessionStore", "Cybertrain::CsrfProtection", "Cybertrain::Router"],
               stack_names(APP)
  hosted = build_app(build_config("app.example"))
  assert_equal ["Cybertrain::HostAuthorization", "Cybertrain::SslRedirect", "Cybertrain::Stream::Endpoint", "Cybertrain::HealthCheck",
                "Cybertrain::Static", "Cybertrain::MethodOverride", "Cybertrain::SessionStore", "Cybertrain::CsrfProtection",
                "Cybertrain::Router"], stack_names(hosted)
  client = Cybertrain::Test::Client.new(hosted)
  # a refused Host is never redirected; an accepted one is, to itself
  assert_equal 403, client.get("/a", { "host" => "evil.example" }).status
  assert_equal "https://app.example/a", client.get("/a", { "host" => "app.example" }).header("Location").to_s
  assert_equal 200, client.get("/up", { "host" => "10.0.0.7" }).status
  plain = build_config("")
  plain.force_ssl = false
  assert_equal ["Cybertrain::Stream::Endpoint", "Cybertrain::HealthCheck", "Cybertrain::Static", "Cybertrain::MethodOverride",
                "Cybertrain::SessionStore", "Cybertrain::CsrfProtection", "Cybertrain::Router"], stack_names(build_app(plain))
end

Cybertrain::Test.run!
