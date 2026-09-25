require "cybertrain/router"
require "cybertrain/app"
require "cybertrain/http/cookies"
require "cybertrain/test/client"

def build_app
  router = Cybertrain::Router.new
  router.get("/", "root") { |c| c.response.body = "home" }
  router.get("/login") do |c|
    c.response.add_cookie(Cybertrain::Cookies.serialize("user", "alice smith"))
    c.response.add_cookie(Cybertrain::Cookies.serialize("theme", "dark"))
    c.response.body = "logged in"
  end
  router.get("/logout") do |c|
    c.response.add_cookie(Cybertrain::Cookies.serialize("user", "", max_age: 0))
    c.response.body = "logged out"
  end
  router.get("/whoami") do |c|
    user = Cybertrain::Cookies.parse(c.request.cookie_header)["user"]
    c.response.body = user.nil? ? "nobody" : user
  end
  router.get("/echo_header") { |c| c.response.body = c.request.header("X-Token").to_s }
  router.post("/posts") do |c|
    c.response.status = 201
    c.response.body = "created #{c.params.nested(:post)[:title]} (#{c.request.content_type})"
  end
  router.post("/go") { |c| c.response.redirect("/", 303) }
  router.get("/old") { |c| c.response.redirect("http://example.com/whoami") }
  router.patch("/posts/:id") { |c| c.response.body = "patched #{c.params[:id]} #{c.params[:title]}" }
  router.put("/posts/:id") { |c| c.response.body = "put #{c.params[:id]}" }
  router.delete("/posts/:id") { |c| c.response.body = "deleted #{c.params[:id]}" }
  router.post("/posts/:id") { |c| c.response.body = "plain post #{c.params[:id]}" }
  Cybertrain::App.new(router, public_root: "test/no_such_public_dir", logging: false)
end

test "get returns the response and keeps it as the last response" do
  client = Cybertrain::Test::Client.new(build_app)
  res = client.get("/")
  assert_equal "home", res.body
  assert_equal res, client.response
  assert_response res, :ok
  assert_response res, 200
  assert_response res, :success
end

test "assert_response(:not_found) on an unknown path" do
  client = Cybertrain::Test::Client.new(build_app)
  assert_response client.get("/nowhere"), :not_found
  message = assert_raises("AssertionFailed") { assert_response client.response, :ok }
  assert_equal "expected response :ok, got 404", message
end

test "the cookie jar carries Set-Cookie into the next request" do
  client = Cybertrain::Test::Client.new(build_app)
  assert_equal "nobody", client.get("/whoami").body
  client.get("/login")
  assert_equal "alice+smith", client.cookies["user"]
  assert_equal "dark", client.cookies["theme"]
  assert_equal "alice smith", client.get("/whoami").body
end

test "a Max-Age=0 cookie is removed from the jar" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/login")
  client.get("/logout")
  assert_nil client.cookies["user"]
  assert_equal "dark", client.cookies["theme"]
  assert_equal "nobody", client.get("/whoami").body
end

test "extra headers reach the request" do
  client = Cybertrain::Test::Client.new(build_app)
  assert_equal "abc", client.get("/echo_header", { "X-Token" => "abc" }).body
end

test "post sends params as a form body" do
  client = Cybertrain::Test::Client.new(build_app)
  res = client.post("/posts", { "post[title]" => "Hello & bye" })
  assert_response res, :created
  assert_equal "created Hello & bye (application/x-www-form-urlencoded)", res.body
end

test "patch, put and delete reach their routes" do
  client = Cybertrain::Test::Client.new(build_app)
  assert_equal "patched 3 New", client.patch("/posts/3", { "title" => "New" }).body
  assert_equal "put 3", client.put("/posts/3").body
  assert_equal "deleted 3", client.delete("/posts/3").body
end

test "request is the generic entry point" do
  client = Cybertrain::Test::Client.new(build_app)
  res = client.request("HEAD", "/")
  assert_response res, :ok
  assert_equal "home", res.body
  res = client.request("POST", "/posts", "post%5Btitle%5D=raw", { "Content-Type" => "application/x-www-form-urlencoded" })
  assert_equal "created raw (application/x-www-form-urlencoded)", res.body
end

test "follow_redirect! GETs the Location of the last response" do
  client = Cybertrain::Test::Client.new(build_app)
  res = client.post("/go")
  assert_response res, :redirect
  assert_response res, :see_other
  assert_redirected_to res, "/"
  assert_equal "home", client.follow_redirect!.body
  assert_equal "home", client.response.body
end

test "follow_redirect! strips the scheme and host of an absolute Location" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/login")
  client.get("/old")
  assert_redirected_to client.response, "http://example.com/whoami"
  assert_equal "alice smith", client.follow_redirect!.body
end

test "follow_redirect! raises when the last response is not a redirect" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/")
  assert_raises("RuntimeError") { client.follow_redirect! }
end

test "assert_redirected_to fails on a non-redirect or another location" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/")
  message = assert_raises("AssertionFailed") { assert_redirected_to client.response, "/" }
  assert_equal "expected a redirect to \"/\", got 200", message
  client.post("/go")
  message = assert_raises("AssertionFailed") { assert_redirected_to client.response, "/elsewhere" }
  assert_equal "expected a redirect to \"/elsewhere\", got \"/\"", message
end

test "MethodOverride turns a POST with _method=delete into DELETE" do
  client = Cybertrain::Test::Client.new(build_app)
  assert_equal "deleted 9", client.post("/posts/9", { "_method" => "delete" }).body
  assert_equal "plain post 9", client.post("/posts/9").body
end

test "a bare Router works as the client's app" do
  router = Cybertrain::Router.new
  router.get("/ping") { |c| c.response.body = "pong" }
  client = Cybertrain::Test::Client.new(router)
  assert_equal "pong", client.get("/ping").body
end

test "status symbols map to codes" do
  res = Cybertrain::Response.new
  [[201, :created], [204, :no_content], [301, :redirect], [400, :bad_request], [403, :forbidden],
   [422, :unprocessable_entity], [500, :error]].each do |pair|
    res.status = pair[0]
    assert_response res, pair[1]
  end
  # :error means exactly 500, as the plan's Interfaces block specifies.
  res.status = 503
  message = assert_raises("AssertionFailed") { assert_response res, :error }
  assert_equal "expected response :error, got 503", message
  message = assert_raises("AssertionFailed") { assert_response res, :bogus }
  assert_equal "unknown status symbol :bogus", message
end

Cybertrain::Test.run!
