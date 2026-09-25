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
  assert_equal ["%ZZ", "a%2", "%"], Cybertrain::Router.split_path("/%ZZ/a%2/%")
  # One bad escape keeps the whole segment literal; other segments still decode.
  assert_equal ["a%20%G1", "b c"], Cybertrain::Router.split_path("/a%20%G1/b%20c")
  assert_equal ["a/b"], Cybertrain::Router.split_path("/a%2fb")
end

test "split_path drops empty segments and decodes" do
  assert_equal ["posts", "1"], Cybertrain::Router.split_path("/posts/1/")
  assert_equal [], Cybertrain::Router.split_path("/")
  assert_equal ["café"], Cybertrain::Router.split_path("/caf%C3%A9")
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
