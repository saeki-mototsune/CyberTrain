# Cybertrain::ErrorPages: production's static error pages
# (test/fixtures/error_pages/{404,500}.html) in place of bare error
# responses, and exceptions turned into a logged 500.
require "stringio"
require "cybertrain/middleware"
require "cybertrain/middleware/error_pages"
require "cybertrain/http/query"
require "cybertrain/router"
require "cybertrain/logger"
require "cybertrain/error_reporter"
require "cybertrain/middleware/request_id"
require "cybertrain/test"
require_relative "support/log_capture"

PAGES = "test/fixtures/error_pages"
LOG = StringIO.new

def endpoint
  router = Cybertrain::Router.new
  router.get("/ok") { |c| c.response.body = "fine" }
  router.get("/head404") do |c|
    c.response.status = 404
    c.response.body = ""
  end
  router.get("/html404") do |c|
    c.response.status = 404
    c.response.content_type = "text/html; charset=utf-8"
    c.response.body = "<p>no such post</p>"
  end
  router.get("/json404") do |c|
    c.response.status = 404
    c.response.content_type = "application/json; charset=utf-8"
    c.response.body = "{\"error\":\"not found\"}"
  end
  router.get("/forbidden") do |c|
    c.response.status = 403
    c.response.body = "Invalid authenticity token"
  end
  router.get("/boom") do |c|
    c.response.set_header("Location", "/elsewhere")
    c.response.add_cookie("a=1; Path=/")
    raise ArgumentError, "kaboom"
  end
  router.get("/runtime") do |c|
    # What a controller action writes before it raises (Controller#run_action).
    c.controller_action = "ThingsController#boom"
    raise RuntimeError, "boom"
  end
  router.get("/toodeep") do |c|
    c.response.set_header("Location", "/elsewhere")
    raise Cybertrain::QueryTooDeep, "parameter nesting too deep (limit 32)"
  end
  router
end

def get(path, root = PAGES)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", path, {}, "", "127.0.0.1"))
  Cybertrain::ErrorPages.new(endpoint, root, Cybertrain::Logger.new(LOG, :info)).call(ctx)
  ctx.response
end

test "a success passes through untouched" do
  res = get("/ok")
  assert_equal 200, res.status
  assert_equal "fine", res.body
end

test "the Router's plain-text 404 becomes public/404.html" do
  res = get("/no/such/route")
  assert_equal 404, res.status
  assert_equal "<h1>404 page</h1>\n", res.body
  assert_equal "text/html; charset=utf-8", res.header("Content-Type")
end

test "an empty 404 (head :not_found) becomes public/404.html" do
  res = get("/head404")
  assert_equal 404, res.status
  assert_equal "<h1>404 page</h1>\n", res.body
end

test "a 404 the action rendered as HTML is kept" do
  res = get("/html404")
  assert_equal 404, res.status
  assert_equal "<p>no such post</p>", res.body
end

test "a 404 the action rendered as JSON is kept" do
  res = get("/json404")
  assert_equal "{\"error\":\"not found\"}", res.body
  assert_equal "application/json; charset=utf-8", res.header("Content-Type")
end

test "a status with no page keeps its body" do
  res = get("/forbidden")
  assert_equal 403, res.status
  assert_equal "Invalid authenticity token", res.body
end

test "an exception is logged and becomes public/500.html without the action's headers or cookies" do
  res = get("/boom")
  assert_equal 500, res.status
  assert_equal "<h1>500 page</h1>\n", res.body
  assert_nil res.header("Location")
  assert res.cookies.empty?
  assert_logged LOG.string, "ERROR", "ArgumentError: kaboom"
end

test "parameters past Query's limits are a 400 logged at info, not a 500" do
  res = get("/toodeep", "test/fixtures/no_such_dir")
  assert_equal 400, res.status
  assert_equal "Bad Request", res.body
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type")
  assert_nil res.header("Location")
  assert_logged LOG.string, "INFO", "rejected request (400 Bad Request): parameter nesting too deep (limit 32)"
  refute LOG.string.include?("QueryTooDeep"), "a rejected request is not an error-level log line"
end

test "without the page files the plain-text bodies stay" do
  res = get("/boom", "test/fixtures/no_such_dir")
  assert_equal 500, res.status
  assert_equal "Internal Server Error", res.body
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type")
  assert_equal "Not Found", get("/missing", "test/fixtures/no_such_dir").body
end

test "error answers carry the security defaults on the wire, once" do
  ["/missing", "/boom", "/toodeep", "/forbidden"].each do |path|
    wire = get(path).to_http
    assert_equal 1, wire.scan(/^x-content-type-options: nosniff\r$/i).length
    assert_equal 1, wire.scan(/^x-frame-options: SAMEORIGIN\r$/i).length
  end
end

# ---- What ErrorPages reports (Task 9; spec section 13.2, plan D7) -----------

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

# Added before the first test, so the reporter's reset! keeps it.
Cybertrain.error.subscribe(ReportCollect.new)

# The reporter's per-test reset (cybertrain/test_help's, which this
# program does not load).
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

def events_after_drain
  Cybertrain.error.drain_reports(2.0)
  REPORTED
end

# The production stack's order (Application#build_stack): RequestId
# outermost, ErrorPages inside it.
def production_get(path, log)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", path, { "host" => "www.example.com" }, "", "127.0.0.1"))
  pages = Cybertrain::ErrorPages.new(endpoint, PAGES, Cybertrain::Logger.new(log, :info))
  Cybertrain::RequestId.new(pages, [:request_id]).call(ctx)
  ctx
end

test "production's ErrorPages reports a 500 once, with the request's where, id and path" do
  log = StringIO.new
  ctx = production_get("/runtime?password=hunter2", log)
  res = ctx.response
  assert_equal 500, res.status
  assert_equal "<h1>500 page</h1>\n", res.body
  id = res.header("X-Request-Id").to_s
  refute id.empty?
  # The existing line stays, under the request's tag.
  assert log.string.include?(" ERROR [#{id}] RuntimeError: boom"), log.string
  events = events_after_drain
  assert_equal 1, events.size
  ev = events[0]
  assert_equal ["RuntimeError", "boom", "ThingsController#boom", id, "GET", "/runtime"],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id, ev.error_request_method,
                ev.error_request_path]
  assert_equal false, ev.error_handled
end

test "ErrorPages reports no 4xx, and where is request when no action ran" do
  production_get("/toodeep", StringIO.new)
  production_get("/no/such/route", StringIO.new)
  assert_equal 0, events_after_drain.size
  production_get("/boom", StringIO.new)
  events = events_after_drain
  assert_equal 1, events.size
  assert_equal "ArgumentError", events[0].error_class
  assert_equal "request", events[0].error_where
end

Cybertrain::Test.run!
