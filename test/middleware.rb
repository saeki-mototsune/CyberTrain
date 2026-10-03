require "stringio"
require "cybertrain/middleware"
require "cybertrain/middleware/request_logger"
require "cybertrain/http/query"
require "cybertrain/middleware/method_override"
require "cybertrain/middleware/session_store"
require "cybertrain/router"
require "cybertrain/app"
require "cybertrain/test"

class AppendBefore < Cybertrain::Middleware
  def call(ctx)
    ctx.response.body = ctx.response.body + "[outer in]"
    super
    ctx.response.body = ctx.response.body + "[outer out]"
    nil
  end
end

class AppendAfter < Cybertrain::Middleware
  def call(ctx)
    ctx.response.body = ctx.response.body + "[inner in]"
    super
    ctx.response.body = ctx.response.body + "[inner out]"
    nil
  end
end

class Halt < Cybertrain::Middleware
  def call(ctx)
    ctx.response.status = 403
    ctx.response.body = "halted"
    nil
  end
end

def build_ctx(method, target, body = "", headers = {})
  Cybertrain::Context.new(Cybertrain::Request.new(method, target, headers, body, "127.0.0.1"))
end

def endpoint
  router = Cybertrain::Router.new
  router.get("/") { |c| c.response.body = c.response.body + "[app]" }
  router.post("/things/:id") { |c| c.response.body = "POST #{c.params[:id]}" }
  router.delete("/things/:id") { |c| c.response.body = "DELETE #{c.params[:id]}" }
  router.patch("/things/:id") { |c| c.response.body = "PATCH #{c.params[:id]}" }
  router.get("/boom") { |c| raise ArgumentError, "kaboom" }
  router
end

FORM = { "content-type" => "application/x-www-form-urlencoded" }

test "a chain of two middlewares runs in order around the app" do
  stack = AppendBefore.new(AppendAfter.new(endpoint))
  ctx = build_ctx("GET", "/")
  assert_nil stack.call(ctx)
  assert_equal "[outer in][inner in][app][inner out][outer out]", ctx.response.body
end

test "a middleware that does not call super halts the chain" do
  stack = AppendBefore.new(Halt.new(endpoint))
  ctx = build_ctx("GET", "/")
  stack.call(ctx)
  assert_equal 403, ctx.response.status
  assert_equal "halted[outer out]", ctx.response.body
end

test "the base middleware without a next app does nothing" do
  ctx = build_ctx("GET", "/")
  assert_nil Cybertrain::Middleware.new.call(ctx)
  assert_equal 200, ctx.response.status
  assert_equal "", ctx.response.body
end

test "app is reassignable to splice a chain" do
  outer = AppendBefore.new
  outer.app = endpoint
  ctx = build_ctx("GET", "/")
  outer.call(ctx)
  assert_equal "[outer in][app][outer out]", ctx.response.body
end

test "RequestLogger logs Started and Completed lines" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  stack = Cybertrain::RequestLogger.new(endpoint, logger)
  stack.call(build_ctx("GET", "/?page=2"))
  lines = sink.string.split("\n")
  assert_equal 2, lines.size
  assert_equal "[INFO] Started GET \"/?page=2\" for 127.0.0.1", lines[0]
  assert lines[1].start_with?("[INFO] Completed 200 in "), lines[1]
  assert lines[1].end_with?("ms"), lines[1]
end

test "RequestLogger reports the final status" do
  sink = StringIO.new
  stack = Cybertrain::RequestLogger.new(endpoint, Cybertrain::Logger.new(sink))
  stack.call(build_ctx("GET", "/missing"))
  assert_includes sink.string, "Completed 404 in "
end

test "RequestLogger logs Completed 500 and re-raises when the app raises" do
  sink = StringIO.new
  stack = Cybertrain::RequestLogger.new(endpoint, Cybertrain::Logger.new(sink))
  message = assert_raises("ArgumentError") { stack.call(build_ctx("GET", "/boom")) }
  assert_equal "kaboom", message
  lines = sink.string.split("\n")
  assert_equal 2, lines.size
  assert_equal "[INFO] Started GET \"/boom\" for 127.0.0.1", lines[0]
  assert lines[1].start_with?("[INFO] Completed 500 in "), lines[1]
  assert lines[1].end_with?("ms"), lines[1]
end

# An app whose parameter parsing hit a Query limit: the error path outside
# RequestLogger answers 400 for it (ClientError), so the access log must too.
class TooManyApp
  def call(ctx)
    raise Cybertrain::QueryTooMany, "too many parameters (limit 4096)"
  end
end

test "RequestLogger logs the status the client fault gets (400), not 500" do
  sink = StringIO.new
  stack = Cybertrain::RequestLogger.new(TooManyApp.new, Cybertrain::Logger.new(sink))
  message = assert_raises("QueryTooMany") { stack.call(build_ctx("POST", "/things")) }
  assert_equal "too many parameters (limit 4096)", message
  lines = sink.string.split("\n")
  assert_equal 2, lines.size
  assert lines[1].start_with?("[INFO] Completed 400 in "), lines[1]
end

test "MethodOverride turns a form POST with _method=delete into DELETE" do
  stack = Cybertrain::MethodOverride.new(endpoint)
  ctx = build_ctx("POST", "/things/1", "_method=delete", FORM)
  stack.call(ctx)
  assert_equal "DELETE", ctx.request.method
  assert_equal "DELETE 1", ctx.response.body
end

test "MethodOverride reads _method from the query string and ignores case" do
  stack = Cybertrain::MethodOverride.new(endpoint)
  ctx = build_ctx("POST", "/things/2?_method=PATCH")
  stack.call(ctx)
  assert_equal "PATCH 2", ctx.response.body
end

test "MethodOverride ignores unknown methods and non-POST requests" do
  stack = Cybertrain::MethodOverride.new(endpoint)
  ctx = build_ctx("POST", "/things/3", "_method=get", FORM)
  stack.call(ctx)
  assert_equal "POST 3", ctx.response.body
  ctx = build_ctx("GET", "/?_method=delete")
  stack.call(ctx)
  assert_equal "GET", ctx.request.method
end

test "MethodOverride ignores _method in a body that is not a form" do
  stack = Cybertrain::MethodOverride.new(endpoint)
  ctx = build_ctx("POST", "/things/4", "_method=delete", { "content-type" => "text/plain" })
  stack.call(ctx)
  assert_equal "POST 4", ctx.response.body
end

test "MethodOverride on a malformed form body raises QueryMalformed (a 400 through ClientError)" do
  stack = Cybertrain::MethodOverride.new(endpoint)
  assert_raises("QueryMalformed") { stack.call(build_ctx("POST", "/things/1", "_method=%zz", FORM)) }
  assert_raises("QueryMalformed") { stack.call(build_ctx("POST", "/things/1?_method=%zz")) }
end

test "MethodOverride and the Router share one parse of the form body" do
  stack = Cybertrain::MethodOverride.new(endpoint)
  ctx = build_ctx("POST", "/things/1?q=1", "_method=delete", FORM)
  # a reader that ran before the Router and kept the trees
  q = ctx.request.query_params
  f = ctx.request.form_params
  stack.call(ctx)
  assert_equal "DELETE 1", ctx.response.body
  assert f.equal?(ctx.request.form_params)
  assert_equal "delete", f["_method"]
  # the Router builds ctx.params as its own tree (query, then form, then the
  # captures merged into a fresh Params); neither cache is ever changed, so
  # the trees fetched before routing are still what the Request holds
  assert !ctx.params.equal?(q)
  assert !ctx.params.equal?(f)
  assert q.equal?(ctx.request.query_params)
  assert_equal "1", q["q"]
  assert_equal 1, q.to_h.length
  assert !q.key?("_method")
  assert !q.key?("id")
  assert_equal "1", ctx.params["q"]
  assert_equal "delete", ctx.params["_method"]
  assert_equal "1", ctx.params["id"]
  ctx.params.set_value("_method", "changed")
  ctx.params.set_value("q", "changed")
  assert_equal "delete", f["_method"]
  assert_equal "1", q["q"]
  assert_equal 1, f.to_h.length
  assert !f.key?("q")
  assert !f.key?("id")
end

# SessionStore parses every cookie on every request but reads only its own,
# so a cookie another app set on the parent domain must not fail the request
# whether or not it percent-decodes ("50%off" does not: Cookies keeps the raw
# value, on both runtimes).
test "a foreign cookie that does not percent-decode does not fail the request" do
  stack = Cybertrain::SessionStore.new(endpoint, secret: "s" * 32)
  ctx = build_ctx("GET", "/", "", { "cookie" => "promo=50%off; theme=dark" })
  assert_nil stack.call(ctx)
  assert_equal 200, ctx.response.status
  assert_equal "[app]", ctx.response.body
end

test "App runs the default stack down to the router" do
  sink = StringIO.new
  router = endpoint
  app = Cybertrain::App.new(router, public_root: "test/no_such_public_dir", logger: Cybertrain::Logger.new(sink))
  assert_equal router, app.router
  ctx = build_ctx("POST", "/things/5", "_method=delete", FORM)
  assert_nil app.call(ctx)
  assert_equal "DELETE 5", ctx.response.body
  assert_includes sink.string, "Started POST \"/things/5\" for 127.0.0.1"
  assert_includes sink.string, "Completed 200 in "
end

test "App without logging writes nothing to its logger" do
  sink = StringIO.new
  app = Cybertrain::App.new(endpoint, public_root: "test/no_such_public_dir", logging: false, logger: Cybertrain::Logger.new(sink))
  ctx = build_ctx("GET", "/")
  app.call(ctx)
  assert_equal "[app]", ctx.response.body
  assert_equal "", sink.string
end

Cybertrain::Test.run!
