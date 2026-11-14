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

# What ThingsController#scope_probe and #streamed saw, and what the probe
# outside the stack saw.
$probe_scope = Cybertrain::Logger::NO_SCOPE
$outer_scope = Cybertrain::Logger::NO_SCOPE
$stream_seen = ""
$same_scope = false
$probe_id = ""
$last_page = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, "", ""))

# Sits between the development front_app's outer RequestId and the rest:
# records the Scope the outer RequestId installed.
class ScopeProbe < Cybertrain::Middleware
  def call(ctx)
    $outer_scope = Cybertrain::Logger.current_scope
    super
  end
end

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

  # Records the Scope the action runs under (the nesting test compares it
  # with the one an outer probe saw).
  def scope_probe
    $probe_scope = Cybertrain::Logger.current_scope
    render plain: "probed"
  end

  # A streamed body: written after the stack returned. It logs a line and
  # reads the request id off the thread's Scope, as Job.enqueue does.
  def streamed
    stream(content_type: "text/plain") do |out|
      Cybertrain.logger.info("in stream")
      $stream_seen = Cybertrain::Logger.current_scope.scope_request_id
      out.write("streamed")
    end
  end
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/things/show", "things_show") { |ctx| ThingsController.new(ctx).process(:show) { |c| c.show } }
ROUTER.get("/things/boom", "things_boom") { |ctx| ThingsController.new(ctx).process(:boom) { |c| c.boom } }
ROUTER.get("/things/bad", "things_bad") { |ctx| ThingsController.new(ctx).process(:bad) { |c| c.bad } }
ROUTER.get("/things/scope_probe", "things_scope_probe") do |ctx|
  ThingsController.new(ctx).process(:scope_probe) { |c| c.scope_probe }
end
ROUTER.get("/things/streamed", "things_streamed") { |ctx| ThingsController.new(ctx).process(:streamed) { |c| c.streamed } }
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

# Dev::ErrorPage directly over the stack (no outer RequestId: the stack's
# own sets the id); its ERROR line captured. The development front_app's
# whole nesting is the next test's.
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

# The development server's front_app (Roles::ServerRunner#front_app,
# private): RequestId around HostAuthorization around Dev::ErrorPage
# around the stack, whose own RequestId finds the id set. A ScopeProbe
# under the outer RequestId records the Scope it installed.
def front_app_nesting
  dev = config_for("development")
  stack = app_for(dev).stack
  page = Cybertrain::Dev::ErrorPage.new(stack, nil)
  hosts = Cybertrain::HostAuthorization.new(page, dev.checked_hosts, dev.health_path)
  Cybertrain::RequestId.new(ScopeProbe.new(hosts), dev.log_tags)
end

def front_app_get(app, path)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", path, { "host" => "localhost" }, "", "127.0.0.1"))
  app.call(ctx)
  ctx
end

test "the development front_app's nesting makes one id, one header and one Scope" do
  log = capture_log do
    app = front_app_nesting
    $last = front_app_get(app, "/things/scope_probe").response
    # the action ran under the outer RequestId's Scope: the inner one made none
    $same_scope = $probe_scope.equal?($outer_scope)
    $probe_id = $outer_scope.scope_request_id
    $last_page = front_app_get(app, "/things/boom")
  end
  probed = last_response
  id = probed.header("X-Request-Id").to_s
  assert_uuid id
  assert_equal "probed", probed.body
  assert_equal 1, probed.headers.keys.count { |k| k.downcase == "x-request-id" }
  assert $same_scope
  assert_equal id, $probe_id
  page = $last_page.response
  page_id = page.header("X-Request-Id").to_s
  assert_equal 500, page.status
  assert_uuid page_id
  assert_equal page_id, $last_page.request.request_id
  refute page_id == id
  # the diagnostics page's ERROR line is logged inside the outer Scope
  assert log.include?(" ERROR [#{page_id}] RuntimeError: boom"), log
  assert_equal 1, LogCapture.count(log, "ERROR", "RuntimeError: boom")
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

test "SslRedirect's redirect carries the id" do
  c = config_for("production")
  c.force_ssl = true
  c.public_root = "test/fixtures/error_pages"
  capture_log { $last = Cybertrain::Test::Client.new(app_for(c)).get("/things/show") }
  assert last_response.header("Location").to_s.start_with?("https://"), last_response.header("Location").to_s
  assert_uuid last_response.header("X-Request-Id")
end

test "a streamed body is written under the request's Scope; nothing is left for the next request" do
  log = capture_log { $last = Cybertrain::Test::Client.new(app_for(config_for("test"))).get_stream("/things/streamed", events: 1, timeout: 1) }
  id = last_response.header("X-Request-Id").to_s
  assert_uuid id
  assert_equal "streamed", last_response.body
  assert_equal id, $stream_seen
  assert log.include?(" INFO [#{id}] in stream\n"), log
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
  # a plain request next on this thread: its own id, then nothing again
  plain = client.get("/things/show")
  assert_uuid plain.body
  refute plain.body == id
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
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

# ---- What a request reports (Task 9; spec section 13.2, plan D7) -----------
#
# The request path's automatic reports on the core alone: a 500 is
# reported once, by RequestId here (no ErrorPages in the test
# environment), with the action as `where` and the request's id, method
# and masked path; a 4xx or a rescue_from is not; no parameter, header,
# cookie, client address, query or reset token reaches an event. The
# events are collected by a subscriber added before the first test (kept
# by reset!, which each test runs first).

def no_report_context
  h = { "" => "" }
  h.delete("")
  h
end

REPORTED = Array.new(0) do
  Cybertrain::ErrorEvent.new("", "", "", "", "", "", "", "", false, no_report_context, Array.new(0) { "" }, Time.at(0).utc)
end

class ReportCollect < Cybertrain::ErrorSubscriber
  def report(event)
    REPORTED << event
    nil
  end
end

Cybertrain.error.subscribe(ReportCollect.new)

# The reporter's per-test reset (what cybertrain/test_help registers; this
# program is core-only and does not load it): no dedupe carried over from
# the tests above, which raise the same "boom".
module ReportReset
  def self.hook
    -> {
      Cybertrain.error.reset!
      REPORTED.clear
      nil
    }
  end
end
Cybertrain::Test.on_reset(ReportReset.hook)

class Handled < StandardError
end

class ReportsController < Cybertrain::Controller
  rescue_from(Handled) { |c, e| c.render plain: "handled", status: :unprocessable_entity }

  def boom
    raise RuntimeError, "boom"
  end

  def bad
    render plain: params.require(:thing).to_s
  end

  def rescued
    raise Handled, "handled"
  end

  def token
    raise RuntimeError, "boom"
  end
end

REPORT_ROUTER = Cybertrain::Router.new
REPORT_ROUTER.get("/reports/boom", "reports_boom") { |ctx| ReportsController.new(ctx).process(:boom) { |c| c.boom } }
REPORT_ROUTER.post("/reports/boom", "reports_boom_post") { |ctx| ReportsController.new(ctx).process(:boom) { |c| c.boom } }
REPORT_ROUTER.get("/reports/bad", "reports_bad") { |ctx| ReportsController.new(ctx).process(:bad) { |c| c.bad } }
REPORT_ROUTER.get("/reports/rescued", "reports_rescued") do |ctx|
  ReportsController.new(ctx).process(:rescued) { |c| c.rescued }
end
REPORT_ROUTER.get("/passwords/:token/edit", "edit_password") do |ctx|
  ReportsController.new(ctx).process(:token) { |c| c.token }
end

REPORT_APP = Cybertrain::Application.new(router: REPORT_ROUTER, url_resolver: ->(n, a, o) { "/" }, config: config_for("test"))
REPORT_CLIENT = Cybertrain::Test::Client.new(REPORT_APP)

# A stack that raises what is not a StandardError (a helper not yet
# written).
class NotWrittenApp < Cybertrain::Middleware
  def call(ctx)
    raise NotImplementedError, "not written"
  end
end

def report_client
  REPORT_CLIENT
end

# The reports made so far, once delivered.
def events_after_drain
  Cybertrain.error.drain_reports(2.0)
  REPORTED
end

# The one event reported; fails unless there is exactly one.
def only_event
  events = events_after_drain
  assert_equal 1, events.size
  events[0]
end

# Every String an event holds: its fields, its context's keys and values
# and its backtrace.
def all_strings(ev)
  out = [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id, ev.error_request_method,
         ev.error_request_path, ev.error_environment, ev.error_release]
  ev.error_context.each do |k, v|
    out << k
    out << v
  end
  ev.error_backtrace.each { |line| out << line }
  out
end

def refute_anywhere(ev, secret)
  all_strings(ev).each { |s| refute s.include?(secret), "#{secret.inspect} found in #{s.inspect}" }
end

test "a request's 500 is reported once, with where, method and path" do
  TrustedProxy.during do
    assert_raises("RuntimeError") do
      report_client.get("/reports/boom?page=2&password=hunter2", { "X-Request-Id" => "abc-123" })
    end
  end
  ev = only_event
  assert_equal ["RuntimeError", "boom", "ReportsController#boom", "GET", "/reports/boom", "abc-123"],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_method, ev.error_request_path,
                ev.error_request_id]
  assert_equal false, ev.error_handled
  assert ev.error_context.empty?
  refute_anywhere(ev, "hunter2")
  refute_anywhere(ev, "page=2")
  # The Scope is put back after the report.
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

test "no report for a 4xx or a rescue_from" do
  assert_equal 400, report_client.get("/reports/bad").status
  rescued = report_client.get("/reports/rescued")
  assert_equal 422, rescued.status
  assert_equal "handled", rescued.body
  assert_equal 0, events_after_drain.size
end

test "a reset link's token and the query never reach a report" do
  token = Cybertrain::Token.issue("reset", 7, 900, "digest")
  assert_raises("RuntimeError") { report_client.get("/passwords/#{token}/edit?token=#{token}") }
  ev = only_event
  assert_equal "ReportsController#token", ev.error_where
  assert_equal "/passwords/[FILTERED]/edit", ev.error_request_path
  refute_anywhere(ev, token)
end

# Runs the block with the cookie c=v7 in report_client's jar, removed
# again after it, also when it raises (pre-flight ruling G4).
module ReportCookie
  def self.during
    REPORT_CLIENT.cookies["c"] = "v7"
    _value = yield
    nil
  ensure
    REPORT_CLIENT.cookies.delete("c")
  end
end

test "no params, headers, cookies or client address in an event" do
  ReportCookie.during do
    TrustedProxy.during do
      assert_raises("RuntimeError") do
        report_client.post("/reports/boom", { "secret" => "s3" }, { "X-Api-Key" => "k9", "X-Forwarded-For" => "203.0.113.9" })
      end
    end
  end
  refute report_client.cookies.key?("c")
  ev = only_event
  assert_equal "POST", ev.error_request_method
  ["s3", "k9", "v7", "203.0.113.9"].each { |secret| refute_anywhere(ev, secret) }
end

# Moves the Clock 61 seconds on (past the reporter's 60-second dedupe)
# when the request comes back out through it, raising or not: a
# RequestId outside it that reported the same exception again would make
# a second event, not one collapsed by dedupe.
# One step past the reporter's dedupe window.
PAST_DEDUPE = Cybertrain::ErrorReporter::DEDUPE_SECONDS + 1

class ClockSkip < Cybertrain::Middleware
  def call(ctx)
    nxt = @app
    nxt.call(ctx) unless nxt.nil?
    nil
  ensure
    Cybertrain::Clock.travel_to(Cybertrain::Clock.now + PAST_DEDUPE)
  end
end

NESTED_AT = Time.utc(2026, 11, 11, 12)

test "RequestIds inside each other report once: the innermost, which saw the exception first" do
  # outer RequestId -> skip -> middle RequestId -> skip -> the app's stack,
  # whose own RequestId is innermost; nothing between them catches.
  middle = Cybertrain::RequestId.new(ClockSkip.new(REPORT_APP.stack), [:request_id])
  outer = Cybertrain::RequestId.new(ClockSkip.new(middle), [:request_id])
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/reports/boom", { "host" => "www.example.com" }, "", "127.0.0.1"))
  travel_to NESTED_AT
  assert_raises("RuntimeError") { outer.call(ctx) }
  # Two skips: the outer one would have reported two windows on, the
  # middle one one window on.
  assert_equal NESTED_AT.to_i + 2 * PAST_DEDUPE, Time.current.to_i
  ev = only_event
  # Reported before either skip: by the innermost RequestId.
  assert_equal NESTED_AT.to_i, ev.error_occurred_at.to_i
  assert_equal "ReportsController#boom", ev.error_where
  assert_equal ctx.request.request_id, ev.error_request_id
  assert_equal "/reports/boom", ev.error_request_path
  assert ctx.error_reported
end

test "an exception outside StandardError is reported too" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/x", { "host" => "www.example.com" }, "", "127.0.0.1"))
  assert_raises("NotImplementedError") { Cybertrain::RequestId.new(NotWrittenApp.new(nil), [:request_id]).call(ctx) }
  ev = only_event
  assert_equal "NotImplementedError", ev.error_class
  assert_equal "request", ev.error_where
  assert_equal "/x", ev.error_request_path
end

# An Exception neither of RequestId's rescue arms names (an application's
# own, outside StandardError), and an app that raises it.
class OutsideArms < Exception
end

class OutsideArmsApp < Cybertrain::Middleware
  def call(ctx)
    message = "stop"
    raise OutsideArms, message
  end
end

# Calls `app` with a new request; answers the class of what escaped it.
def call_outside_arms(app)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/x", { "host" => "www.example.com" }, "", "127.0.0.1"))
  app.call(ctx)
  "nothing"
rescue OutsideArms => e
  e.class.name.to_s
end

test "an exception outside both rescue arms leaves no Scope behind either" do
  assert_equal "OutsideArms", call_outside_arms(Cybertrain::RequestId.new(OutsideArmsApp.new(nil), [:request_id]))
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

test "RequestId.where_for is the action, or request when none ran" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/x", {}, "", "127.0.0.1"))
  assert_equal "request", Cybertrain::RequestId.where_for(ctx)
  ctx.controller_action = "ThingsController#show"
  assert_equal "ThingsController#show", Cybertrain::RequestId.where_for(ctx)
end

Cybertrain::Test.run!
