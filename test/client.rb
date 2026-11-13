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
  # A session cookie that lasts a minute, one without a lifetime, and one
  # with an Expires two minutes on (Cybertrain.config's clock: the test's).
  router.get("/short_login") do |c|
    c.response.add_cookie(Cybertrain::Cookies.serialize("user", "alice smith", max_age: 60))
    c.response.add_cookie(Cybertrain::Cookies.serialize("theme", "dark"))
    # A plain Time given to `expires:` here, beside the calls of
    # Cookies.serialize without it (the routes above): the compiled program
    # crashed while that parameter defaulted to nil (NOTES, the rule on nil
    # defaults).
    c.response.add_cookie(Cybertrain::Cookies.serialize("dated", "1", expires: Cybertrain::Clock.now + 120))
    c.response.body = "logged in"
  end
  router.get("/expire_dated") do |c|
    c.response.add_cookie(Cybertrain::Cookies.serialize("dated", "", expires: Time.utc(2000, 1, 1)))
    c.response.body = "expired"
  end
  # An unreadable Max-Age (ignored: the cookie stays, its Expires then
  # counts) and a negative one (expired at once).
  router.get("/odd_max_age") do |c|
    c.response.add_cookie("kept=1; Path=/; Max-Age=abc")
    c.response.add_cookie("dated_too=2; Path=/; Max-Age=1x; Expires=Fri, 01 Jan 2100 00:00:00 GMT")
    c.response.add_cookie("gone=3; Path=/; Max-Age=-5")
    c.response.body = "odd"
  end
  router.get("/cookie_header") { |c| c.response.body = c.request.cookie_header.to_s }
  router.get("/to_fragment") { |c| c.response.redirect("/echo?a=1#part", 302) }
  router.get("/to_absolute_fragment") { |c| c.response.redirect("http://www.example.com/echo#part", 302) }
  router.get("/echo") { |c| c.response.body = "#{c.request.path} ?#{c.request.query_string}" }
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

test "follow_redirect! fails, as an assertion, when the last response is not a redirect" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/")
  assert_equal "follow_redirect!: the last response was 200, not a redirect (3xx with a Location)",
               assert_raises("AssertionFailed") { client.follow_redirect! }
end

test "follow_redirect! never sends the Location's fragment" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/to_fragment")
  assert_equal "/echo ?a=1", client.follow_redirect!.body
  client.get("/to_absolute_fragment")
  assert_equal "/echo ?", client.follow_redirect!.body
end

test "local_path drops the fragment and keeps the query, with or without a path" do
  assert_equal "/?x=1", Cybertrain::Test::Client.local_path("http://www.example.com?x=1")
  assert_equal "/?x=1", Cybertrain::Test::Client.local_path("http://www.example.com?x=1#top")
  assert_equal "/", Cybertrain::Test::Client.local_path("http://www.example.com#top")
  assert_equal "/", Cybertrain::Test::Client.local_path("http://www.example.com")
  assert_equal "/a?b=1", Cybertrain::Test::Client.local_path("https://www.example.com:3000/a?b=1#c")
  assert_equal "/a?b=1", Cybertrain::Test::Client.local_path("/a?b=1#c")
  assert_equal "/a", Cybertrain::Test::Client.local_path("/a")
end

test "the jar reads a cookie by a Symbol as by its name" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/login")
  assert_equal "alice+smith", client.cookies[:user]
  assert client.cookies.key?(:theme)
  assert client.cookies.key?("theme")
  refute client.cookies.key?(:nope)
  assert_nil client.cookies[:nope]
  client.cookies[:theme] = "light"
  assert_equal "light", client.cookies["theme"]
  assert_equal ["user", "theme"], client.cookies.keys
  assert_equal 2, client.cookies.size
  assert_equal "light", client.cookies.delete(:theme)
  assert_equal ["user"], client.cookies.keys
end

test "a cookie past its Max-Age or Expires under the clock is neither sent nor read" do
  client = Cybertrain::Test::Client.new(build_app)
  travel_to Time.utc(2030, 1, 1, 12, 0, 0) do
    client.get("/short_login")
    assert_equal "alice smith", client.get("/whoami").body
    assert_equal "1", client.cookies["dated"]
    travel 59
    assert_equal "alice smith", client.get("/whoami").body
    travel 2
    # user had Max-Age=60, dated Expires 12:02.
    assert_nil client.cookies[:user]
    assert_equal "nobody", client.get("/whoami").body
    assert_equal "1", client.cookies["dated"]
    refute client.cookies.key?("user")
    assert_equal ["theme", "dated"], client.cookies.keys
    travel 60
    assert_nil client.cookies["dated"]
    assert_equal ["theme"], client.cookies.keys
    assert_equal "theme=dark", client.get("/cookie_header").body
  end
end

test "a Max-Age that is not a number is ignored, as RFC 6265 says; a negative one expires the cookie" do
  client = Cybertrain::Test::Client.new(build_app)
  client.get("/odd_max_age")
  assert_equal "1", client.cookies["kept"]
  assert_equal "2", client.cookies["dated_too"]
  assert_nil client.cookies["gone"]
  assert_equal ["kept", "dated_too"], client.cookies.keys
end

test "an Expires already past drops the cookie, as Max-Age=0 does" do
  client = Cybertrain::Test::Client.new(build_app)
  travel_to Time.utc(2030, 1, 1, 12, 0, 0) do
    client.get("/short_login")
    client.get("/expire_dated")
    assert_nil client.cookies["dated"]
    assert_equal ["user", "theme"], client.cookies.keys
  end
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

# One pair per entry of Controller::STATUS_SYMBOLS (cybertrain/controller.rb),
# which this program cannot load: the two lists are kept the same by hand,
# and this is where a drift shows.
STATUS_PAIRS = [
  [200, :ok], [201, :created], [202, :accepted], [204, :no_content],
  [205, :reset_content], [206, :partial_content],
  [300, :multiple_choices], [301, :moved_permanently], [302, :found], [303, :see_other],
  [304, :not_modified], [307, :temporary_redirect], [308, :permanent_redirect],
  [400, :bad_request], [401, :unauthorized], [402, :payment_required], [403, :forbidden],
  [404, :not_found], [405, :method_not_allowed], [406, :not_acceptable],
  [408, :request_timeout], [409, :conflict], [410, :gone], [411, :length_required],
  [412, :precondition_failed], [413, :payload_too_large], [415, :unsupported_media_type],
  [416, :range_not_satisfiable], [417, :expectation_failed], [422, :unprocessable_entity],
  [429, :too_many_requests], [431, :request_header_fields_too_large],
  [500, :internal_server_error], [501, :not_implemented], [502, :bad_gateway],
  [503, :service_unavailable], [504, :gateway_timeout]
]

test "every Controller::STATUS_SYMBOLS name is an exact match for its code" do
  res = Cybertrain::Response.new
  STATUS_PAIRS.each do |pair|
    res.status = pair[0]
    assert_response res, pair[1]
    assert_equal [pair[0], pair[0]], Cybertrain::Test::Client.status_range(pair[1])
  end
  assert_equal 37, STATUS_PAIRS.size
  # the neighbouring code does not pass: an exact match, not a range
  res.status = 200
  message = assert_raises("AssertionFailed") { assert_response res, :accepted }
  assert_equal "expected response :accepted, got 200", message
  res.status = 429
  message = assert_raises("AssertionFailed") { assert_response res, :unauthorized }
  assert_equal "expected response :unauthorized, got 429", message
end

Cybertrain::Test.run!
