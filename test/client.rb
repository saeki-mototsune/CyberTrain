require "cybertrain/router"
require "cybertrain/app"
require "cybertrain/http/cookies"
require "cybertrain/test/client"
require "digest"

# What an action sees of a multipart request: the boundary the client chose,
# each text part, each file as filename, type, size and digest.
def upload_report(c)
  form = c.request.multipart_form
  lines = [c.request.multipart_boundary]
  i = 0
  while i < form.text_count
    lines << "text #{form.text_name_at(i)}=#{form.text_value_at(i)}"
    i += 1
  end
  i = 0
  while i < form.file_count
    up = form.file_at(i)
    lines << "file #{form.file_name_at(i)} #{up.original_filename} #{up.declared_content_type} #{up.byte_size} #{up.sha256_hex}"
    i += 1
  end
  lines.join("\n")
end

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
  router.get("/peer") { |c| c.response.body = "#{c.request.remote_addr} #{c.request.loopback?}" }
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
  router.post("/upload") do |c|
    c.response.status = 201
    c.response.body = upload_report(c)
  end
  router.patch("/upload/:id") { |c| c.response.body = "patched #{c.params[:id]} #{upload_report(c)}" }
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

test "requests come from 127.0.0.1 unless peer_address says otherwise" do
  client = Cybertrain::Test::Client.new(build_app)
  assert_equal "127.0.0.1", client.peer_address
  assert_equal "127.0.0.1 true", client.get("/peer").body
  client.peer_address = "203.0.113.7"
  assert_equal "203.0.113.7 false", client.get("/peer").body
  client.peer_address = "::1"
  assert_equal "::1 true", client.get("/peer").body
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

test "Test.binary makes a binary String from byte values" do
  data = Cybertrain::Test.binary([0, 255, 0x80, 65, 0, 10, 13])
  assert_equal 7, data.bytesize
  assert_equal [0, 255, 128, 65, 0, 10, 13], [0, 1, 2, 3, 4, 5, 6].map { |n| data.getbyte(n).to_i }
  assert_equal 0, Cybertrain::Test.binary([]).bytesize
  assert_equal Digest::SHA256.hexdigest("\x00\xFF\x80A\x00\n\r".b), Digest::SHA256.hexdigest(data)
  assert_equal "byte value out of range: 256", assert_raises("ArgumentError") { Cybertrain::Test.binary([1, 256]) }
  assert_raises("ArgumentError") { Cybertrain::Test.binary([-1]) }
end

test "post_multipart sends text parts and files as multipart/form-data" do
  client = Cybertrain::Test::Client.new(build_app)
  data = Cybertrain::Test.binary([137, 80, 78, 71, 0, 255, 13, 10, 45, 45, 0])
  uploads = [Cybertrain::Test::Upload.new("post[cover]", "cover.png", "image/png", data)]
  res = client.post_multipart("/upload", { "post[title]" => "H\u00e9llo", "authenticity_token" => "tok" }, uploads)
  assert_response res, :created
  puts res.body
  lines = res.body.split("\n")
  assert_equal "----CybertrainTestBoundary1", lines[0]
  assert_equal "text post[title]=H\u00e9llo", lines[1]
  assert_equal "text authenticity_token=tok", lines[2]
  assert_equal "file post[cover] cover.png image/png 11 #{Digest::SHA256.hexdigest(data)}", lines[3]
end

test "post_multipart takes fields and uploads as optional, and extra headers" do
  client = Cybertrain::Test::Client.new(build_app)
  res = client.post_multipart("/upload")
  assert_response res, :created
  assert_equal "----CybertrainTestBoundary1", res.body
  res = client.post_multipart("/upload", { "a" => "1" }, [], { "X-Token" => "abc" })
  assert_equal "----CybertrainTestBoundary2\ntext a=1", res.body
end

test "the boundary is bumped until no file or field contains it" do
  client = Cybertrain::Test::Client.new(build_app)
  first = Cybertrain::Test.binary([0, 1]) + "----CybertrainTestBoundary1".b + Cybertrain::Test.binary([255])
  second = "x----CybertrainTestBoundary2".b
  uploads = [Cybertrain::Test::Upload.new("a", "a.bin", "application/octet-stream", first),
             Cybertrain::Test::Upload.new("b", "b.bin", "application/octet-stream", second)]
  res = client.post_multipart("/upload", { "t" => "----CybertrainTestBoundary3" }, uploads)
  assert_response res, :created
  puts res.body
  lines = res.body.split("\n")
  assert_equal "----CybertrainTestBoundary4", lines[0]
  assert_equal "text t=----CybertrainTestBoundary3", lines[1]
  assert_equal "file a a.bin application/octet-stream 30 #{Digest::SHA256.hexdigest(first)}", lines[2]
  assert_equal "file b b.bin application/octet-stream 28 #{Digest::SHA256.hexdigest(second)}", lines[3]
end

test "patch_multipart sends a POST with _method=patch, which MethodOverride turns into the PATCH route" do
  client = Cybertrain::Test::Client.new(build_app)
  up = Cybertrain::Test::Upload.new("f", "f.txt", "text/plain", "hi")
  res = client.patch_multipart("/upload/5", { "x" => "1" }, [up])
  assert_response res, :ok
  puts res.body
  lines = res.body.split("\n")
  assert_equal "patched 5 ----CybertrainTestBoundary1", lines[0]
  assert_equal "text x=1", lines[1]
  assert_equal "text _method=patch", lines[2]
  assert_equal "file f f.txt text/plain 2 #{Digest::SHA256.hexdigest("hi")}", lines[3]
  # the caller's own _method field is replaced, never sent twice
  res = client.patch_multipart("/upload/6", { "_method" => "delete" })
  assert_equal "patched 6 ----CybertrainTestBoundary2\ntext _method=patch", res.body
end

test "status symbols cover payload_too_large and unsupported_media_type" do
  res = Cybertrain::Response.new
  res.status = 413
  assert_response res, :payload_too_large
  res.status = 415
  assert_response res, :unsupported_media_type
  res.status = 400
  message = assert_raises("AssertionFailed") { assert_response res, :payload_too_large }
  assert_equal "expected response :payload_too_large, got 400", message
end

Cybertrain::Test.run!
