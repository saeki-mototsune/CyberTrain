require "tmpdir"
require "cybertrain/middleware/static"
require "cybertrain/assets"
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
OUTSIDE = ROOT + "-outside"
Dir.mkdir(OUTSIDE)
File.write(OUTSIDE + "/x.txt", "outside")
# public/assets as gen leaves it: current digests (the resolver below,
# standing in for gen/assets.rb), one kept in .manifest, an undigested file
# the application keeps there, and a digest-shaped name gen never wrote.
Dir.mkdir(ROOT + "/assets")
Dir.mkdir(ROOT + "/assets/controllers")
Dir.mkdir(ROOT + "/x")
ASSET_FILES = ["assets/app-1a2b3c4d.css", "assets/app-0badf00d.css", "assets/controllers/hello_controller-abcdef01.js",
               "assets/LICENSE-2b3c4d5e", "assets/plain.txt", "assets/app-99999999.css", "x/app-1a2b3c4d.css"]
ASSET_FILES.each { |f| File.write("#{ROOT}/#{f}", "/* #{f} */") }
File.write(ROOT + "/assets/.manifest", "app.css 1a2b3c4d 0badf00d\n../escape.css 0badf00d\n")
File.symlink(SECRET, ROOT + "/link.txt")
File.symlink(OUTSIDE, ROOT + "/outdir")
File.symlink(ROOT + "/robots.txt", ROOT + "/inner.txt")

module StaticAssets
  def self.digest_path(logical)
    case logical
    when "app.css" then "/assets/app-1a2b3c4d.css"
    when "controllers/hello_controller.js" then "/assets/controllers/hello_controller-abcdef01.js"
    when "LICENSE" then "/assets/LICENSE-2b3c4d5e"
    else ""
    end
  end

  def self.resolver = ->(name) { digest_path(name) }
end

Cybertrain::Assets.install(StaticAssets.resolver, "{\"imports\":{}}", Array.new(0) { "" })
Cybertrain::Assets.load_kept(ROOT)

# Test.run! exits the process, so the temporary files are removed at exit.
at_exit do
  ASSET_FILES.each { |f| File.delete("#{ROOT}/#{f}") }
  File.delete(ROOT + "/assets/.manifest")
  Dir.rmdir(ROOT + "/assets/controllers")
  Dir.rmdir(ROOT + "/assets")
  Dir.rmdir(ROOT + "/x")
  File.delete(ROOT + "/link.txt")
  File.delete(ROOT + "/outdir")
  File.delete(ROOT + "/inner.txt")
  File.delete(OUTSIDE + "/x.txt")
  Dir.rmdir(OUTSIDE)
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

test "common public/ file types are served under their own type" do
  want = {
    "webp" => "image/webp", "avif" => "image/avif", "woff" => "font/woff", "woff2" => "font/woff2",
    "ttf" => "font/ttf", "otf" => "font/otf", "wasm" => "application/wasm", "mjs" => "text/javascript; charset=utf-8",
    "pdf" => "application/pdf", "webmanifest" => "application/manifest+json", "mp4" => "video/mp4",
    "WEBP" => "image/webp"
  }
  want.each do |ext, type|
    File.write(ROOT + "/f." + ext, "x")
    assert_equal type, serve("GET", "/f." + ext).header("Content-Type")
    File.delete(ROOT + "/f." + ext)
  end
end

test "static files carry the security defaults once, also for HEAD and the octet-stream fallback" do
  ["/css/app.css", "/data.bin"].each do |target|
    ["GET", "HEAD"].each do |method|
      wire = serve(method, target).to_http(method == "HEAD")
      assert_equal 1, wire.scan(/^x-content-type-options: nosniff\r$/i).length
      assert_equal 1, wire.scan(/^x-frame-options: SAMEORIGIN\r$/i).length
    end
  end
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

# Static raising inside a helper method (NOTES rule 32).
def serve_error(method, target)
  serve(method, target)
  "none"
rescue Cybertrain::QueryMalformed
  "QueryMalformed"
end

test "Static decodes the path once through request.path_segments; an invalid decoded byte is the 400" do
  assert_equal "QueryMalformed", serve_error("GET", "/css/%81")
  assert_equal "QueryMalformed", serve_error("HEAD", "/%C3")
  # a method Static skips reaches the Router, which raises the same decision
  assert_equal "QueryMalformed", serve_error("POST", "/css/%81")
  assert_equal "none", serve_error("GET", "/css/%C3%A9")
  # the Router reuses the segments Static decoded
  ctx = build_ctx("GET", "/posts")
  static_stack.call(ctx)
  assert_equal "from router", ctx.response.body
  assert ctx.request.path_segments.equal?(ctx.request.path_segments)
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

test "a current or kept digest is immutable" do
  ["/assets/app-1a2b3c4d.css", "/assets/app-0badf00d.css", "/assets/controllers/hello_controller-abcdef01.js",
   "/assets/LICENSE-2b3c4d5e", "/assets/app%2D1a2b3c4d.css"].each do |target|
    ["GET", "HEAD"].each do |method|
      res = serve(method, target)
      assert_equal 200, res.status
      assert_equal "public, max-age=31536000, immutable", res.header("Cache-Control").to_s
      wire = res.to_http(method == "HEAD")
      assert_equal 1, wire.scan(/^Cache-Control: public, max-age=31536000, immutable\r$/i).length
    end
  end
  assert_equal "/* assets/app-1a2b3c4d.css */", serve("GET", "/assets/app-1a2b3c4d.css").body
  assert_equal "text/css; charset=utf-8", serve("GET", "/assets/app-0badf00d.css").header("Content-Type")
  assert Cybertrain::Assets.kept_file?("app-0badf00d.css")
  # a .manifest line that would leave public/assets is not read
  refute Cybertrain::Assets.kept_file?("../escape-0badf00d.css")
end

test "an undigested file under public/assets keeps max-age=3600" do
  res = serve("GET", "/assets/plain.txt")
  assert_equal 200, res.status
  assert_equal "public, max-age=3600", res.header("Cache-Control").to_s
  refute Cybertrain::Assets.kept_file?("plain.txt")
end

test "a digest-shaped name gen did not write keeps max-age=3600" do
  # on disk under /assets, but neither current nor in .manifest
  assert_equal "public, max-age=3600", serve("GET", "/assets/app-99999999.css").header("Cache-Control").to_s
  # a current digest's name outside /assets
  assert_equal "public, max-age=3600", serve("GET", "/x/app-1a2b3c4d.css").header("Cache-Control").to_s
  refute Cybertrain::Assets.kept_file?("app-99999999.css")
  refute Cybertrain::Assets.kept_file?("controllers/hello_controller-0badf00d.js")
  refute Cybertrain::Assets.kept_file?("")
end

test "a symlink is served only when it stays inside the root" do
  res = serve("GET", "/link.txt")
  assert_equal 404, res.status
  refute res.body.include?("top secret")
  assert_equal 404, serve("GET", "/outdir/x.txt").status
  assert_equal "User-agent: *\n", serve("GET", "/inner.txt").body
end

test "an absolute or encoded path cannot leave the root" do
  name = File.basename(SECRET)
  ["/assets/../../#{name}", "/assets/%2e%2e/%2e%2e/#{name}", "/#{SECRET}", "/%2F#{SECRET.delete_prefix("/")}", "//#{SECRET.delete_prefix("/")}"].each do |target|
    res = serve("GET", target)
    assert_equal 404, res.status
    refute res.body.include?("top secret"), target
  end
end

Cybertrain::Test.run!
