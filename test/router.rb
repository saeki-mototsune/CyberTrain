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
  # a raw invalid byte anywhere in the path is a 400 too, whole-path check
  # ("the path segment policy" below)
  # a malformed escape stays literal (404 by non-match), as before
  assert_equal "none", split_path_error("/a/%ZZ")
  assert_equal ["a", "%ZZ"], Cybertrain::Request.split_path("/a/%ZZ")
end

# The policy of Request.split_path: the WHOLE path is validated as UTF-8 first
# (Query.utf8!, whatever the String's tag), then each segment holding a "%"
# stays literal for a malformed escape or is decoded (and its result checked).
# The same answers on both runtimes by construction. These are UTF-8 literals
# with a stray byte: the whole-path check runs before `split("/")`, so CRuby's
# ArgumentError from split on a broken UTF-8-tagged String never bites. (A
# binary CRuby buffer takes the same road through utf8!'s one copy; no test
# here builds one, `.b` is unverified under Spinel, so that path is covered by
# the server tests that send raw bytes.)
#   /%zz       literal   malformed escape, never decoded
#   /%81       400       the decoded result is not UTF-8
#   /\x81%zz   400       raw invalid byte, whole-path check
#   /\x81%41   400       whole-path check
#   /\xC3%A9   400       half a character raw is not valid text
def valid_escapes_answer(text)
  Cybertrain::Query.valid_escapes?(text) ? "escapes ok" : "malformed escape"
end

def decode_valid_error(text)
  Cybertrain::Query.decode_valid(text, false)
  "decoded"
rescue Cybertrain::QueryMalformed
  "QueryMalformed"
end

test "the path segment policy: the whole path is validated, then a malformed escape stays literal" do
  assert_equal ["%zz"], Cybertrain::Request.split_path("/%zz")
  assert_equal ["x%zz", "y"], Cybertrain::Request.split_path("/x%zz/y")
  assert_equal "QueryMalformed", split_path_error("/%81")
  assert_equal "QueryMalformed", split_path_error("/\x81%zz")
  assert_equal "QueryMalformed", split_path_error("/\x81%41")
  assert_equal "QueryMalformed", split_path_error("/\xC3%A9")
  assert_equal "QueryMalformed", split_path_error("/\x81")
  assert_equal "QueryMalformed", split_path_error("/a/b\x81/c")
  assert_equal "QueryMalformed", split_path_error("/%41\x81")
  # a raw invalid byte in a segment with no "%" is refused as well
  assert_equal "QueryMalformed", split_path_error("/ok/\xFF")
  # the decoder's result check
  assert_equal "QueryMalformed", decode_valid_error("%81")
  assert_equal "decoded", decode_valid_error("%41")
  # valid_escapes? stays safe on a String nobody validated (it searches from i + 1)
  assert_equal "malformed escape", valid_escapes_answer("\x81%zz")
  assert_equal "malformed escape", valid_escapes_answer("%zz")
  assert_equal "malformed escape", valid_escapes_answer("\x81%41%4")
  assert_equal "escapes ok", valid_escapes_answer("\x81%41")
  assert_equal "escapes ok", valid_escapes_answer("%41\x81")
  assert_equal "escapes ok", valid_escapes_answer("%41\x81%41")
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

test "ctx.params is the Router's own tree: built from the Request's validated texts, later sources win" do
  router = Cybertrain::Router.new
  seen = []
  router.post("/items/:id") do |c|
    seen << c.params[:q].to_s
    seen << c.params[:f].to_s
  end
  form = { "content-type" => "application/x-www-form-urlencoded" }
  ctx = build_ctx("POST", "/items/7?q=1", "f=2&_method=put&authenticity_token=tok&post[title]=hi", form)
  # (Symbol keys throughout this program: see NOTES rule 51)
  # a middleware that ran BEFORE the Router and read the texts (it owns any
  # tree it parses from them)
  query_text = ctx.request.utf8_query_string
  body_text = ctx.request.utf8_body
  q = Cybertrain::Query.parse(query_text)
  router.call(ctx)
  assert_equal ["1", "2"], seen
  assert_equal "1", ctx.params[:q]
  assert_equal "2", ctx.params[:f]
  assert_equal "7", ctx.params[:id]
  assert_equal "put", ctx.params[:_method]
  assert_equal "tok", ctx.params[:authenticity_token]
  assert_equal "hi", ctx.params.nested(:post)[:title]
  # the Router reads the very validated texts the Request holds (one
  # validation per field), and does not change them
  assert query_text.equal?(ctx.request.utf8_query_string)
  assert body_text.equal?(ctx.request.utf8_body)
  assert_equal "q=1", query_text
  # a tree parsed earlier from the text is its owner's: the Router's writes
  # (top level or nested) never reach it
  assert !ctx.params.equal?(q)
  assert_equal "1", q[:q]
  assert !q.key?(:f)
  assert !q.key?(:id)
  ctx.params.set_value(:page, "9")
  ctx.params.set_value(:q, "changed")
  assert !q.key?(:page)
  assert_equal "1", q[:q]
end

test "a request without a form body: ctx.params has the query and the capture, a later parse of the text is unaffected" do
  router = Cybertrain::Router.new
  router.get("/items/:id") { |c| c.response.body = "#{c.params[:id]} #{c.params[:q]}" }
  ctx = dispatch(router, "GET", "/items/3?q=1&id=query")
  assert_equal "3 1", ctx.response.body
  own = Cybertrain::Query.parse(ctx.request.utf8_query_string)
  assert !ctx.params.equal?(own)
  assert_equal "query", own[:id]
  assert_equal "3", ctx.params[:id]
  assert_equal "1", own[:q]
  assert !own.key?(:page)
end

test "ctx.params never aliases the Request's path segments: mutating a capture in an action changes nothing Static reads" do
  router = Cybertrain::Router.new
  router.post("/items/:id") do |c|
    c.params[:id].upcase!
    c.params[:q] << "XYZ"
  end
  form = { "content-type" => "application/x-www-form-urlencoded" }
  ctx = build_ctx("POST", "/items/abc?q=1", "f=2", form)
  segments_before = ctx.request.path_segments
  router.call(ctx)
  assert_equal ["items", "abc"], ctx.request.path_segments
  assert segments_before.equal?(ctx.request.path_segments)
  assert_equal "1", ctx.request.query_value("q")
  # Whether the action's own tree took the appends is not asserted: under
  # Spinel an in-place `<<` on a String read out of a Params does not reach
  # the stored value (NOTES rule 55), under CRuby it does; the contract under
  # test is only that the shared segments are untouched either way.
end

test "later sources still win when each is parsed straight into ctx.params" do
  router = Cybertrain::Router.new
  router.post("/items/:id") { |c| c.response.body = "#{c.params[:q]} #{c.params[:f]} #{c.params[:id]}" }
  form = { "content-type" => "application/x-www-form-urlencoded" }
  ctx = dispatch(router, "POST", "/items/7?q=1&id=x", "f=2&q=3", form)
  assert_equal "3 2 7", ctx.response.body
  # asking for one source later parses the same text
  assert_equal "1", Cybertrain::Query.parse(ctx.request.utf8_query_string)[:q]
  assert_equal "3", Cybertrain::Query.parse(ctx.request.utf8_body)[:q]
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
