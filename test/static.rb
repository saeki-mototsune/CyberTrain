require "tmpdir"
require "cybertrain/middleware/static"
require "cybertrain/router"
require "cybertrain/test"

ROOT = Dir.mktmpdir("cybertrain-static")
Dir.mkdir(ROOT + "/css")
File.write(ROOT + "/css/app.css", "body { color: red; }\n")
File.write(ROOT + "/robots.txt", "User-agent: *\n")
File.write(ROOT + "/index.html", "<h1>home</h1>")
File.write(ROOT + "/data.bin", "raw")
SECRET = ROOT + "-secret.txt"
File.write(SECRET, "top secret")

# Test.run! exits the process, so the temporary files are removed at exit.
at_exit do
  File.delete(ROOT + "/css/app.css")
  Dir.rmdir(ROOT + "/css")
  File.delete(ROOT + "/robots.txt")
  File.delete(ROOT + "/index.html")
  File.delete(ROOT + "/data.bin")
  Dir.rmdir(ROOT)
  File.delete(SECRET)
end

def build_ctx(method, target)
  Cybertrain::Context.new(Cybertrain::Request.new(method, target, {}, "", "127.0.0.1"))
end

def static_stack
  router = Cybertrain::Router.new
  router.get("/posts") { |c| c.response.body = "from router" }
  router.post("/robots.txt") { |c| c.response.body = "posted" }
  Cybertrain::Static.new(router, ROOT)
end

def serve(method, target)
  ctx = build_ctx(method, target)
  static_stack.call(ctx)
  ctx.response
end

test "serves a file with the content type from its extension" do
  res = serve("GET", "/css/app.css")
  assert_equal 200, res.status
  assert_equal "body { color: red; }\n", res.body
  assert_equal "text/css; charset=utf-8", res.header("Content-Type")
  assert_equal "public, max-age=3600", res.header("Cache-Control")
  assert_equal "text/plain; charset=utf-8", serve("GET", "/robots.txt").header("Content-Type")
end

test "an unknown extension is served as octet-stream" do
  res = serve("GET", "/data.bin")
  assert_equal "raw", res.body
  assert_equal "application/octet-stream", res.header("Content-Type")
end

test "a directory serves its index.html" do
  res = serve("GET", "/")
  assert_equal "<h1>home</h1>", res.body
  assert_equal "text/html; charset=utf-8", res.header("Content-Type")
end

test "a missing file falls through to the next app" do
  assert_equal "from router", serve("GET", "/posts").body
  res = serve("GET", "/nope.css")
  assert_equal 404, res.status
  assert_equal "Not Found", res.body
end

test "dot-dot segments are rejected" do
  name = File.basename(SECRET)
  ["/../#{name}", "/css/../../#{name}", "/%2E%2E/#{name}", "/css/%2e%2e%2F..%2F#{name}"].each do |target|
    res = serve("GET", target)
    assert_equal 404, res.status
    refute res.body.include?("top secret"), target
  end
end

test "a malformed percent-escape falls through instead of raising" do
  ["/%ZZ", "/100%", "/css/app%2.css", "/css/%"].each do |target|
    res = serve("GET", target)
    assert_equal 404, res.status
    assert_equal "Not Found", res.body
  end
end

test "only GET and HEAD are served" do
  assert_equal "posted", serve("POST", "/robots.txt").body
end

test "HEAD keeps Content-Length but sends no body" do
  res = serve("HEAD", "/robots.txt")
  assert_equal 200, res.status
  wire = res.to_http(true)
  assert_includes wire, "Content-Length: 14\r\n"
  assert wire.end_with?("\r\n\r\n"), wire
  refute wire.include?("User-agent"), wire
end

Cybertrain::Test.run!
