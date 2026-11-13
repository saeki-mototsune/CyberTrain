# Cybertrain::RequestId (spec section 12.2, plan D6 and D8): every
# request's id, generated or taken from a trusted proxy, echoed in
# X-Request-Id (error answers included), read as request.request_id and
# carried by every line logged while the request runs; c.log_tags orders
# the request's tags; the controller action is the request's `where`.
#
# The core alone (`require "cybertrain/core"`): the request id is core.
# A booted Application links SQLite through FFI, so this program runs
# compiled only (spikes/NOTES.md rule 23). No regexp beyond the trivial
# (pre-flight ruling G5): the UUID's shape is read byte by byte
# (LogCapture.uuid?).
require "stringio"
require "cybertrain/core"
require "cybertrain/application"
require "cybertrain/middleware/request_id"
require "cybertrain/dev/error_page"
require "cybertrain/test"
require "cybertrain/test/client"
require_relative "support/log_capture"

# What the actions log stays out of the snapshot unless a test captures it.
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

class ThingsController < Cybertrain::Controller
  def show
    Cybertrain.logger.info("in action")
    render plain: request.request_id
  end

  def boom
    raise RuntimeError, "boom"
  end

  def bad
    render plain: params.require(:thing).to_s
  end

  def scope_where
    render plain: Cybertrain::Logger.current_scope.scope_where
  end
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/things/show", "things_show") { |ctx| ThingsController.new(ctx).process(:show) { |c| c.show } }
ROUTER.get("/things/boom", "things_boom") { |ctx| ThingsController.new(ctx).process(:boom) { |c| c.boom } }
ROUTER.get("/things/bad", "things_bad") { |ctx| ThingsController.new(ctx).process(:bad) { |c| c.bad } }
ROUTER.get("/things/scope_where", "things_scope_where") do |ctx|
  ThingsController.new(ctx).process(:scope_where) { |c| c.scope_where }
end

Cybertrain.configure do |c|
  c.env = "test"
  c.database_path = ":memory:"
  c.pool_size = 1
  c.secret_key_base = "request-id-secret"
  c.log_level = :info
  c.port = 0
end

APP = Cybertrain::Application.new(router: ROUTER, url_resolver: ->(n, a, o) { "/" })
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

def client
  CLIENT
end

# A test-environment Config of its own, so a test can change it.
def config_for(env)
  c = Cybertrain::Config.new
  c.env = env
  c.secret_key_base = "request-id-secret"
  c.static_files = false
  c.csrf = false
  c
end

def app_for(config)
  Cybertrain::Application.new(router: ROUTER, url_resolver: ->(n, a, o) { "/" }, config: config)
end

# The last response a helper below got inside capture_log.
$last = Cybertrain::Response.new

def last_response
  $last
end

# GETs `path` from a fresh app over `config`, built inside capture_log so
# its RequestLogger writes into the capture (pre-flight ruling B5); answers
# what was logged, the time dropped from each line.
def logged_lines(config, path)
  log = capture_log { $last = Cybertrain::Test::Client.new(app_for(config)).get(path) }
  out = Array.new(0) { "" }
  log.split("\n").each { |line| out << line.byteslice(25, line.bytesize - 25).to_s }
  out
end

# Runs the block with Request.trusted_proxy on, and off again after it,
# also when it raises (pre-flight ruling G4: the restore in a plain
# method's ensure).
module TrustedProxy
  def self.during
    Cybertrain::Request.trusted_proxy = true
    _value = yield
    nil
  ensure
    Cybertrain::Request.trusted_proxy = false
  end
end

def assert_uuid(value)
  assert LogCapture.uuid?(value.to_s), "expected a version 4 UUID, got #{value.inspect}"
end

test "every request gets a UUID, echoed and readable as request.request_id" do
  r1 = client.get("/things/show")
  r2 = client.get("/things/show")
  assert_uuid r1.header("X-Request-Id")
  assert_equal r1.header("X-Request-Id"), r1.body
  assert_uuid r2.header("X-Request-Id")
  refute r1.header("X-Request-Id") == r2.header("X-Request-Id")
end

test "X-Request-Id from a trusted proxy is used only when well-formed" do
  TrustedProxy.during do
    # the client's peer_address is 127.0.0.1, a trusted proxy now
    assert_equal "abc-123", client.get("/things/show", { "X-Request-Id" => "abc-123" }).header("X-Request-Id")
    assert_equal "abc-123", client.response.body
    assert_equal "a" * 255, client.get("/things/show", { "X-Request-Id" => "a" * 255 }).header("X-Request-Id")
    ["a" * 256, "", "abc 123", "abc_123", "abc\r\nX-Evil: 1", "a, b", "日本"].each do |v|
      assert_uuid client.get("/things/show", { "X-Request-Id" => v }).header("X-Request-Id")
    end
    untrusted = Cybertrain::Test::Client.new(APP)
    untrusted.peer_address = "203.0.113.9"
    assert_uuid untrusted.get("/things/show", { "X-Request-Id" => "abc-123" }).header("X-Request-Id")
  end
  # off again: the same header from loopback is not taken
  assert_uuid client.get("/things/show", { "X-Request-Id" => "abc-123" }).header("X-Request-Id")
end

test "RequestId.accepted? takes 1 to 255 bytes of letters, digits and hyphens" do
  assert Cybertrain::RequestId.accepted?("abc-123")
  assert Cybertrain::RequestId.accepted?("A-Z-a-z-0-9")
  assert Cybertrain::RequestId.accepted?("a" * 255)
  refute Cybertrain::RequestId.accepted?("")
  refute Cybertrain::RequestId.accepted?("a" * 256)
  refute Cybertrain::RequestId.accepted?("abc_123")
  refute Cybertrain::RequestId.accepted?("abc.123")
  refute Cybertrain::RequestId.accepted?("a, b")
  refute Cybertrain::RequestId.accepted?("é")
end

test "every line logged in the request carries the id, the application's own included" do
  lines = logged_lines(config_for("test"), "/things/show")
  id = last_response.header("X-Request-Id").to_s
  assert_uuid id
  assert_equal ["INFO [#{id}] Started GET \"/things/show\" for 127.0.0.1", "INFO [#{id}] in action"], lines[0, 2]
  assert lines[2].start_with?("INFO [#{id}] Completed 200 in "), lines[2]
  assert_equal 3, lines.size
end

test "log_tags orders the request's tags; [] turns them off" do
  both = config_for("test")
  both.log_tags = [:remote_ip, :request_id]
  lines = logged_lines(both, "/things/show")
  id = last_response.header("X-Request-Id").to_s
  assert_uuid id
  assert_equal "INFO [127.0.0.1] [#{id}] in action", lines[1]
  ip_only = config_for("test")
  ip_only.log_tags = [:remote_ip]
  assert_equal "INFO [127.0.0.1] in action", logged_lines(ip_only, "/things/show")[1]
  assert_uuid last_response.header("X-Request-Id")
  none = config_for("test")
  none.log_tags = []
  assert_equal "INFO in action", logged_lines(none, "/things/show")[1]
  # the header is sent either way
  assert_uuid last_response.header("X-Request-Id")
end

test "RequestId.scope_for puts the tags in log_tags order and marks the id's place" do
  request = Cybertrain::Request.new("GET", "/things/show?x=1", {}, "", "127.0.0.1")
  scope = Cybertrain::RequestId.scope_for(request, "abc-123", [:remote_ip, :request_id])
  assert_equal ["127.0.0.1", "abc-123"], scope.scope_tags
  assert_equal 1, scope.scope_id_tag
  assert_equal "abc-123", scope.scope_request_id
  assert_equal "GET", scope.scope_request_method
  assert_equal "/things/show", scope.scope_request_path
  assert_equal "", scope.scope_where
  assert scope.scope_context.empty?
  bare = Cybertrain::RequestId.scope_for(request, "abc-123", [])
  assert bare.scope_tags.empty?
  assert_equal(-1, bare.scope_id_tag)
  assert_equal "abc-123", bare.scope_request_id
end

test "the request path in the Scope is masked as the request log masks it" do
  token = "eyJfcmFpbHMiOnsiZGF0YSI6WzEsIjIwMjYtMTEtMTEiXX19--0123456789abcdef0123456789abcdef01234567"
  request = Cybertrain::Request.new("GET", "/passwords/#{token}/edit", {}, "", "127.0.0.1")
  scope = Cybertrain::RequestId.scope_for(request, "abc-123", [:request_id])
  assert_equal Cybertrain::ParameterFilter.filter_path("/passwords/#{token}/edit"), scope.scope_request_path
end

# The production stack's ErrorPages logs the 500 (an ERROR line):
# captured, so the snapshot stays fixed.
def production_boom
  c = config_for("production")
  c.public_root = "test/fixtures/error_pages"
  capture_log { $last = Cybertrain::Test::Client.new(app_for(c)).get("/things/boom") }
  $last
end

# Dev::ErrorPage over the stack, as the development server's front_app
# puts it; its ERROR line captured.
def dev_error_page_boom
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/things/boom", { "host" => "www.example.com" }, "", "127.0.0.1"))
  capture_log { Cybertrain::Dev::ErrorPage.new(APP.stack, nil).call(ctx) }
  ctx.response
end

test "the id is echoed on error responses" do
  bad = client.get("/things/bad")
  assert_equal 400, bad.status
  assert_uuid bad.header("X-Request-Id")
  dev = config_for("development")
  blocked = Cybertrain::Test::Client.new(app_for(dev))
  log = capture_log { $last = blocked.get("/things/show", { "host" => "rebind.example" }) }
  assert_equal 403, last_response.status
  assert_equal "Blocked host", last_response.body
  assert_uuid last_response.header("X-Request-Id")
  assert log.include?(" WARN [#{last_response.header("X-Request-Id")}] Blocked host: "), log
  prod = production_boom
  assert_equal 500, prod.status
  assert_equal "<h1>500 page</h1>\n", prod.body
  assert_uuid prod.header("X-Request-Id")
  page = dev_error_page_boom
  assert_equal 500, page.status
  assert page.body.include?("RuntimeError"), page.body
  assert_uuid page.header("X-Request-Id")
end

test "a raising request leaves no Scope behind on its thread" do
  assert_raises("RuntimeError") { client.get("/things/boom") }
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
  # the next request on this thread starts from nothing: its own id only
  lines = logged_lines(config_for("test"), "/things/show")
  id = last_response.header("X-Request-Id").to_s
  assert_uuid id
  lines.each { |line| assert line.start_with?("INFO [#{id}] "), line }
  assert_equal 3, lines.size
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

test "a RequestId inside another keeps the outer id and adds no Scope of its own" do
  inner = Cybertrain::RequestId.new(APP.stack, [:request_id])
  outer = Cybertrain::RequestId.new(inner, [:request_id])
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/things/show", { "host" => "www.example.com" }, "", "127.0.0.1"))
  outer.call(ctx)
  id = ctx.response.header("X-Request-Id").to_s
  assert_uuid id
  assert_equal id, ctx.request.request_id
  assert_equal id, ctx.response.body
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

test "the controller and action are the request's where" do
  assert_equal "ThingsController#scope_where", client.get("/things/scope_where").body
  assert Cybertrain::Logger.current_scope.scope_where.empty?
end

test "a controller run without a RequestId writes nothing to the shared empty Scope" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/things/scope_where", {}, "", "127.0.0.1"))
  ROUTER.call(ctx)
  assert_equal "", ctx.response.body
  assert_equal "ThingsController#scope_where", ctx.controller_action
  assert_equal "", Cybertrain::Logger::NO_SCOPE.scope_where
end

Cybertrain::Test.run!
