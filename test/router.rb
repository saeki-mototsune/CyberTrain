require "cybertrain/html"
require "cybertrain/router"
require "cybertrain/test"

# cybertrain/html is required on purpose: its SafeString#to_s once made the
# Router's route-param keys reach Params#set_value boxed, which only broke
# the C build in programs that load both (see Router#assemble_params).

def build_ctx(method, target, body = "", headers = {})
  Cybertrain::Context.new(Cybertrain::Request.new(method, target, headers, body, "127.0.0.1"))
end

def dispatch(router, method, target, body = "", headers = {})
  ctx = build_ctx(method, target, body, headers)
  router.call(ctx)
  ctx
end

def sample_router
  router = Cybertrain::Router.new
  router.get("/", "root") { |c| c.response.body = "home" }
  router.get("/posts", "posts") { |c| c.response.body = "index" }
  router.get("/posts/new", "new_post") { |c| c.response.body = "new" }
  router.get("/posts/:id", "post") { |c| c.response.body = "show #{c.params[:id]}" }
  router.get("/posts/:id/edit", "edit_post") { |c| c.response.body = "edit #{c.params[:id]}" }
  router.post("/posts") { |c| c.response.body = "create" }
  router.patch("/posts/:id") { |c| c.response.body = "update #{c.params[:id]}" }
  router.put("/posts/:id") { |c| c.response.body = "replace #{c.params[:id]}" }
  router.delete("/posts/:id") { |c| c.response.body = "destroy #{c.params[:id]}" }
  router
end

test "static path matches" do
  ctx = dispatch(sample_router, "GET", "/posts")
  assert_equal 200, ctx.response.status
  assert_equal "index", ctx.response.body
  assert_equal "posts", ctx.route_name
end

test "root path matches" do
  assert_equal "home", dispatch(sample_router, "GET", "/").response.body
end

test "dynamic segment is captured into route_params and params" do
  ctx = dispatch(sample_router, "GET", "/posts/42/edit")
  assert_equal "edit 42", ctx.response.body
  assert_equal({ "id" => "42" }, ctx.route_params)
  assert_equal "edit_post", ctx.route_name
end

test "first matching route wins" do
  assert_equal "new", dispatch(sample_router, "GET", "/posts/new").response.body
  router = Cybertrain::Router.new
  router.get("/a/:x") { |c| c.response.body = "first" }
  router.get("/a/b") { |c| c.response.body = "second" }
  assert_equal "first", dispatch(router, "GET", "/a/b").response.body
end

test "verb selects the route" do
  router = sample_router
  assert_equal "create", dispatch(router, "POST", "/posts").response.body
  assert_equal "update 7", dispatch(router, "PATCH", "/posts/7").response.body
  assert_equal "replace 7", dispatch(router, "PUT", "/posts/7").response.body
  assert_equal "destroy 7", dispatch(router, "DELETE", "/posts/7").response.body
end

test "HEAD is answered by the GET route" do
  ctx = dispatch(sample_router, "HEAD", "/posts/3")
  assert_equal 200, ctx.response.status
  assert_equal "show 3", ctx.response.body
end

test "trailing slash and repeated slashes are ignored" do
  assert_equal "index", dispatch(sample_router, "GET", "/posts/").response.body
  assert_equal "show 5", dispatch(sample_router, "GET", "//posts//5/").response.body
end

test "segments are percent-decoded, plus stays a plus" do
  assert_equal "show a b", dispatch(sample_router, "GET", "/posts/a%20b").response.body
  assert_equal "show a+b", dispatch(sample_router, "GET", "/posts/a+b").response.body
end

test "a segment with a malformed percent-escape stays literal" do
  router = sample_router
  assert_equal "show %ZZ", dispatch(router, "GET", "/posts/%ZZ").response.body
  assert_equal "show 100%", dispatch(router, "GET", "/posts/100%").response.body
  assert_equal "edit a%2", dispatch(router, "GET", "/posts/a%2/edit").response.body
  assert_equal ["%ZZ", "a%2", "%"], Cybertrain::Request.split_path("/%ZZ/a%2/%")
  # One bad escape keeps the whole segment literal; other segments still decode.
  assert_equal ["a%20%G1", "b c"], Cybertrain::Request.split_path("/a%20%G1/b%20c")
  assert_equal ["a/b"], Cybertrain::Request.split_path("/a%2fb")
end

test "split_path drops empty segments and decodes" do
  assert_equal ["posts", "1"], Cybertrain::Request.split_path("/posts/1/")
  assert_equal [], Cybertrain::Request.split_path("/")
  assert_equal ["café"], Cybertrain::Request.split_path("/caf%C3%A9")
end

test "split_path decodes escapes and multibyte text in one segment and keeps '+' a plus" do
  assert_equal ["a+b c\u00e9"], Cybertrain::Request.split_path("/a+b%20c%C3%A9")
  assert_equal ["+", "A+"], Cybertrain::Request.split_path("/+/%41+")
  assert_equal ["\u00e9+ "], Cybertrain::Request.split_path("/\u00e9+%20")
  # a bad escape keeps its segment literal, "+" included
  assert_equal ["a+b%ZZ", "x y"], Cybertrain::Request.split_path("/a+b%ZZ/x%20y")
end

# Request.split_path raising inside a helper method, not in the assert_raises
# block (NOTES rule 32): the class name of what it raised, or "none".
def split_path_error(path)
  Cybertrain::Request.split_path(path)
  "none"
rescue Cybertrain::QueryMalformed
  "QueryMalformed"
end

test "split_path: an invalid byte sequence in a decoded segment is QueryMalformed (400)" do
  assert_equal ["a", "\u00e9"], Cybertrain::Request.split_path("/a/%C3%A9")
  assert_equal "QueryMalformed", split_path_error("/a/%81")
  assert_equal "QueryMalformed", split_path_error("/a/%C3")
  assert_equal "QueryMalformed", split_path_error("/a/x%81/b")
  # the raw-byte cases need a UTF-8 String that CRuby's split refuses, so
  # they are Query-level tests ("the path segment policy" below)
  # a malformed escape stays literal (404 by non-match), as before
  assert_equal "none", split_path_error("/a/%ZZ")
  assert_equal ["a", "%ZZ"], Cybertrain::Request.split_path("/a/%ZZ")
end

# The per-segment policy of Request.split_path (escapes first, then validity),
# which has to answer the same on both runtimes. A raw invalid byte in a path
# can only reach split_path end to end under Spinel (CRuby's "/\x81".split("/")
# raises ArgumentError on a UTF-8-tagged String, a binary socket buffer is
# fine), so its two raw-byte rows are checked at the Query level, with the
# exact calls split_path makes, and the escape-only rows through split_path.
#   /\x81%zz  literal   valid_escapes? false, never validated or decoded
#   /\x81%41  400       valid_escapes? true, check_valid! raises (CRuby binary: the result check)
#   /%81      400       the result check
#   /%zz      literal
def valid_escapes_answer(text)
  Cybertrain::Query.valid_escapes?(text) ? "escapes ok" : "malformed escape"
end

def check_valid_error(text)
  Cybertrain::Query.check_valid!(text)
  "valid"
rescue Cybertrain::QueryMalformed
  "QueryMalformed"
end

def decode_valid_error(text)
  Cybertrain::Query.decode_valid(text, false)
  "decoded"
rescue Cybertrain::QueryMalformed
  "QueryMalformed"
end

test "the path segment policy: a malformed escape stays literal before any validity check" do
  # /\x81%zz: the escape scan answers false without CRuby's IndexError (it searches
  # the next "%" from i + 1, an ASCII byte, never from the stray byte after
  # the escape), so split_path keeps the segment literal and never validates
  assert_equal "malformed escape", valid_escapes_answer("\x81%zz")
  assert_equal "malformed escape", valid_escapes_answer("%zz")
  assert_equal "malformed escape", valid_escapes_answer("\x81%41%4")
  # a well-formed escape next to a stray byte is then refused by check_valid!
  assert_equal "escapes ok", valid_escapes_answer("\x81%41")
  assert_equal "escapes ok", valid_escapes_answer("%41\x81")
  assert_equal "escapes ok", valid_escapes_answer("%41\x81%41")
  assert_equal "QueryMalformed", check_valid_error("\x81%41")
  # a binary String passes check_valid!, so the RESULT check catches the same
  # bytes (this is what a CRuby socket buffer takes): decode_valid raises
  assert_equal "QueryMalformed", decode_valid_error("\x81%41")
  assert_equal "QueryMalformed", decode_valid_error("%81")
  assert_equal "decoded", decode_valid_error("%41")
  # through split_path itself
  assert_equal "QueryMalformed", split_path_error("/%81")
  assert_equal "none", split_path_error("/%zz")
  assert_equal ["%zz"], Cybertrain::Request.split_path("/%zz")
  assert_equal ["x%zz", "y"], Cybertrain::Request.split_path("/x%zz/y")
end

# Router#call raising inside a helper method (NOTES rule 32).
def dispatch_error(router, method, target)
  dispatch(router, method, target)
  "none"
rescue Cybertrain::QueryMalformed
  "QueryMalformed"
end

test "the Router reads the request's cached path_segments; an invalid decoded segment is the 400" do
  router = sample_router
  assert_equal "QueryMalformed", dispatch_error(router, "GET", "/posts/%81")
  assert_equal "QueryMalformed", dispatch_error(router, "POST", "/posts/%C3")
  assert_equal "none", dispatch_error(router, "GET", "/posts/%C3%A9")
  # one decode per request: the segments the Router matched on are the very
  # Array the request keeps
  ctx = dispatch(router, "GET", "/posts/%41")
  assert_equal "show A", ctx.response.body
  assert ctx.request.path_segments.equal?(ctx.request.path_segments)
  assert_equal ["posts", "A"], ctx.request.path_segments
end

test "a large non-ASCII path segment with an escape splits without a quadratic library call" do
  # Request.split_path decodes through Query.decode_valid (NOTES rule 49):
  # one non-ASCII character, a "+" kept as a plus, and %41 in 60 000 bytes.
  seg = "\u00e9" + ("a" * 30_000) + "+" + ("b" * 30_000) + "%41"
  parts = Cybertrain::Request.split_path("/" + seg)
  assert_equal 1, parts.length
  assert_equal 60_003, parts[0].length
  assert_equal "+", parts[0][30_001, 1]
  assert_equal "bA", parts[0][-2, 2]
end

test "path_for builds paths from route names" do
  router = sample_router
  assert_equal "/posts", router.path_for("posts")
  assert_equal "/", router.path_for("root")
  assert_equal "/posts/9/edit", router.path_for("edit_post", { "id" => "9" })
  assert_equal "/posts/a%20b", router.path_for("post", { "id" => "a b" })
  assert_nil router.path_for("nope")
end

test "Route#path raises ArgumentError when a segment is missing" do
  route = sample_router.routes[4]
  assert_equal "/posts/:id/edit", route.pattern
  assert_equal ["posts", ":id", "edit"], route.segments
  message = assert_raises("ArgumentError") { route.path({ "other" => "1" }) }
  assert_includes message, ":id"
end

test "Route#match returns captures or nil" do
  route = Cybertrain::Route.new("get", "/posts/:id", "post", ->(c) { c.response.body = "x" })
  assert_equal "GET", route.verb
  assert_equal({ "id" => "1" }, route.match("GET", ["posts", "1"]))
  assert_equal({ "id" => "1" }, route.match("HEAD", ["posts", "1"]))
  assert_nil route.match("POST", ["posts", "1"])
  assert_nil route.match("GET", ["posts"])
  assert_nil route.match("GET", ["users", "1"])
end

test "unmatched request gets a plain-text 404" do
  ctx = dispatch(sample_router, "GET", "/missing")
  assert_equal 404, ctx.response.status
  assert_equal "Not Found", ctx.response.body
  assert_equal "text/plain; charset=utf-8", ctx.response.header("Content-Type")
  assert_equal "", ctx.route_name
  assert_equal 404, dispatch(sample_router, "POST", "/posts/1").response.status
end

test "params assembly order is query < form < route" do
  router = Cybertrain::Router.new
  seen = []
  router.post("/items/:id") do |c|
    seen << "#{c.params[:id]} #{c.params[:a]} #{c.params[:b]} #{c.params.nested(:post)[:title]}"
  end
  form = { "content-type" => "application/x-www-form-urlencoded" }
  dispatch(router, "POST", "/items/7?id=q&a=q&b=q", "id=f&a=f&post[title]=hi", form)
  assert_equal ["7 f q hi"], seen
end

test "ctx.params is the Router's own tree: neither parse cache of the Request is ever changed" do
  router = Cybertrain::Router.new
  seen = []
  router.post("/items/:id") do |c|
    seen << c.params[:q].to_s
    seen << c.params[:f].to_s
  end
  form = { "content-type" => "application/x-www-form-urlencoded" }
  ctx = build_ctx("POST", "/items/7?q=1", "f=2&_method=put&authenticity_token=tok&post[title]=hi", form)
  # (Symbol keys throughout this program: see NOTES rule 51)
  # a middleware that ran BEFORE the Router and kept the trees (to rebuild a
  # canonical or pagination URL after `super`, say)
  q = ctx.request.query_params
  f = ctx.request.form_params
  router.call(ctx)
  assert_equal ["1", "2"], seen
  assert_equal "1", ctx.params[:q]
  assert_equal "2", ctx.params[:f]
  assert_equal "7", ctx.params[:id]
  assert_equal "put", ctx.params[:_method]
  assert_equal "tok", ctx.params[:authenticity_token]
  assert_equal "hi", ctx.params.nested(:post)[:title]
  # ctx.params is neither cache, and the caches are the very objects the
  # early reader holds
  assert !ctx.params.equal?(q)
  assert !ctx.params.equal?(f)
  assert q.equal?(ctx.request.query_params)
  assert f.equal?(ctx.request.form_params)
  # the query tree still holds the query keys alone: no form field, _method,
  # token or route capture
  assert_equal "1", q[:q]
  # (no Params#keys here: next to Hash#keys in this program it mis-dispatches
  # under Spinel, NOTES rule 51)
  assert !q.key?(:f)
  assert !q.key?(:_method)
  assert !q.key?(:authenticity_token)
  assert !q.key?(:post)
  assert !q.key?(:id)
  # the form tree is unchanged too
  assert_equal "2", f[:f]
  assert !f.key?(:id)
  assert !f.key?(:q)
  assert_equal "hi", f.nested(:post)[:title]
  # and writing to ctx.params later (top level or nested) reaches neither
  ctx.params.set_value(:page, "9")
  ctx.params.set_value(:q, "changed")
  ctx.params.nested(:post).set_value(:title, "changed")
  assert !q.key?(:page)
  assert_equal "1", q[:q]
  assert_equal "hi", f.nested(:post)[:title]
end

test "a reader after routing and a request without a form body get the same untouched query tree" do
  router = Cybertrain::Router.new
  router.get("/items/:id") { |c| c.response.body = "#{c.params[:id]} #{c.params[:q]}" }
  ctx = dispatch(router, "GET", "/items/3?q=1&id=query")
  assert_equal "3 1", ctx.response.body
  assert !ctx.params.equal?(ctx.request.query_params)
  assert_equal "query", ctx.request.query_params[:id]
  assert_equal "3", ctx.params[:id]
  assert_equal "1", ctx.request.query_params[:q]
  assert !ctx.request.query_params.key?(:page)
end

test "ctx.params never aliases the Request's caches: mutating a value in an action changes nothing the middleware reads" do
  router = Cybertrain::Router.new
  router.post("/items/:id") do |c|
    c.params[:q] << "XYZ"
    c.params[:f] << "XYZ"
    c.params[:id].upcase!
    c.params.list(:tags)[0] << "XYZ"
    c.params.nested(:post)[:title] << "XYZ"
  end
  form = { "content-type" => "application/x-www-form-urlencoded" }
  ctx = build_ctx("POST", "/items/abc?q=1&tags[]=t", "f=2&post[title]=hi", form)
  # the readers a middleware would hold (built before routing) ...
  segments_before = ctx.request.path_segments
  q = ctx.request.query_params
  f = ctx.request.form_params
  router.call(ctx)
  # ... see none of it
  assert_equal "1", q[:q]
  assert_equal ["t"], q.list(:tags)
  assert_equal "2", f[:f]
  assert_equal "hi", f.nested(:post)[:title]
  assert_equal ["items", "abc"], ctx.request.path_segments
  assert segments_before.equal?(ctx.request.path_segments)
  # Whether the action's own tree took the appends is not asserted: under
  # Spinel an in-place `<<` on a String read out of a Params does not reach
  # the stored value (NOTES rule 55), under CRuby it does; the contract under
  # test is only that the caches are untouched either way.
end

test "later sources still win when each is parsed straight into ctx.params" do
  router = Cybertrain::Router.new
  router.post("/items/:id") { |c| c.response.body = "#{c.params[:q]} #{c.params[:f]} #{c.params[:id]}" }
  form = { "content-type" => "application/x-www-form-urlencoded" }
  ctx = dispatch(router, "POST", "/items/7?q=1&id=x", "f=2&q=3", form)
  assert_equal "3 2 7", ctx.response.body
  # no cache was needed to route; asking for one later parses the same text
  assert_equal "1", ctx.request.query_params[:q]
  assert_equal "3", ctx.request.form_params[:q]
end

# Router#call raising inside a helper method (NOTES rule 32): the class name
# of a Query limit error, or "none".
def dispatch_limit_error(router, method, target, body, headers)
  dispatch(router, method, target, body, headers)
  "none"
rescue Cybertrain::QueryTooMany
  "QueryTooMany"
end

test "the Query limits apply per parse call: the query string and the form body each get MAX_PAIRS" do
  router = Cybertrain::Router.new
  router.post("/items") { |c| c.response.body = "#{c.params[:a]} #{c.params[:b]}" }
  form = { "content-type" => "application/x-www-form-urlencoded" }
  rest = (0...4095).map { |i| "k#{i}=1" }.join("&")
  # 4096 pairs in the query string and 4096 in the form body: both within
  # the limit, though together they are twice MAX_PAIRS
  assert_equal "q f", dispatch(router, "POST", "/items?a=q&" + rest, "b=f&" + rest, form).response.body
  assert_equal "QueryTooMany", dispatch_limit_error(router, "POST", "/items?a=q&" + rest + "&x=1", "b=f", form)
  assert_equal "QueryTooMany", dispatch_limit_error(router, "POST", "/items?a=q", "b=f&" + rest + "&x=1", form)
end

test "form body is ignored unless the request is a form" do
  router = Cybertrain::Router.new
  router.post("/items") { |c| c.response.body = c.params[:a].to_s }
  assert_equal "q", dispatch(router, "POST", "/items?a=q", "a=f").response.body
  json = { "content-type" => "application/json" }
  assert_equal "q", dispatch(router, "POST", "/items?a=q", "a=f", json).response.body
end

test "route params and escaped output work in one program" do
  router = Cybertrain::Router.new
  router.get("/tags/:name") { |c| c.response.body = Cybertrain::Html.out(c.params[:name]) }
  assert_equal "&lt;b&gt;", dispatch(router, "GET", "/tags/%3Cb%3E").response.body
end

Cybertrain::Test.run!
