# Cybertrain::ErrorPages: production's static error pages
# (test/fixtures/error_pages/{404,500}.html) in place of bare error
# responses, and exceptions turned into a logged 500.
require "stringio"
require "cybertrain/middleware"
require "cybertrain/middleware/error_pages"
require "cybertrain/http/query"
require "cybertrain/router"
require "cybertrain/logger"
require "cybertrain/test"

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
  assert_includes LOG.string, "[ERROR] ArgumentError: kaboom"
end

test "parameters past Query's limits are a 400 logged at info, not a 500" do
  res = get("/toodeep", "test/fixtures/no_such_dir")
  assert_equal 400, res.status
  assert_equal "Bad Request", res.body
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type")
  assert_nil res.header("Location")
  assert_includes LOG.string, "[INFO] rejected request (400 Bad Request): parameter nesting too deep (limit 32)"
  refute LOG.string.include?("QueryTooDeep"), "a rejected request is not an error-level log line"
end

test "without the page files the plain-text bodies stay" do
  res = get("/boom", "test/fixtures/no_such_dir")
  assert_equal 500, res.status
  assert_equal "Internal Server Error", res.body
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type")
  assert_equal "Not Found", get("/missing", "test/fixtures/no_such_dir").body
end

Cybertrain::Test.run!
