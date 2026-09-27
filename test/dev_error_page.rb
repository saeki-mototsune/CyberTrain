# Cybertrain::Dev::ErrorPage (the development diagnostics middleware) and
# the bits of Cybertrain::Dev::Rebuilder it reads. Runs under CRuby too: no
# FFI is required here (cybertrain/dev/reexec is left out on purpose).
require "stringio"
require "cybertrain/logger"
require "cybertrain/middleware"
require "cybertrain/template/ast"
require "cybertrain/dev/rebuilder"
require "cybertrain/dev/error_page"
require "cybertrain/test"

# Keep the error log out of the snapshot.
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

class Raiser < Cybertrain::Middleware
  def call(ctx)
    raise "boom <b>" if ctx.request.path == "/boom"
    if ctx.request.path == "/template"
      raise Cybertrain::Template::RuntimeError, "posts/show.html.erb:12: undefined method 'titel' for Post"
    end
    if ctx.request.path == "/syntax"
      raise Cybertrain::Template::SyntaxError, "posts/_form.html.erb:3: unterminated <% tag"
    end
    raise ArgumentError, "wrong number of arguments (given 1, expected 0)" if ctx.request.path == "/argument"
    if ctx.request.path == "/download"
      # A send_data-style action that fails after setting its headers.
      ctx.response.redirect("/elsewhere")
      ctx.response.set_header("Content-Disposition", "attachment; filename=x.csv")
      ctx.response.content_type = "text/csv"
      ctx.response.add_cookie("remember=1; Path=/")
      ctx.response.body = "a,b\n"
      raise "export failed"
    end

    super
  end
end

class Page < Cybertrain::Middleware
  def call(ctx)
    case ctx.request.path
    when "/json"
      ctx.response.content_type = "application/json"
      ctx.response.body = "{\"ok\":true}"
    when "/fragment"
      ctx.response.body = "<p>no body tag</p>"
    when "/no_content"
      ctx.response.status = 204
    when "/not_modified"
      ctx.response.status = 304
    when "/empty"
      ctx.response.status = 200
    when "/continue"
      ctx.response.status = 100
    else
      ctx.response.body = "<!DOCTYPE html>\n<html><body class=\"app\"><h1>Posts</h1></body></html>"
    end
    nil
  end
end

def build_ctx(method, target)
  Cybertrain::Context.new(Cybertrain::Request.new(method, target, {}, "", "127.0.0.1"))
end

def request(app, target, method = "GET")
  ctx = build_ctx(method, target)
  app.call(ctx)
  ctx.response
end

def failed_rebuilder
  r = Cybertrain::Dev::Rebuilder.new("/apps/blog")
  r.record_build(false, "app/controllers/posts_controller.rb:3: syntax error, unexpected <end>\n")
  r
end

def plain_app
  Cybertrain::Dev::ErrorPage.new(Raiser.new(Page.new))
end

test "an exception from the inner app becomes a 500 HTML page" do
  res = request(plain_app, "/boom")
  assert_equal 500, res.status
  assert_equal "text/html; charset=utf-8", res.header("Content-Type")
  assert_includes res.body, "<h1>RuntimeError</h1>"
  assert_includes res.body, "boom &lt;b&gt;"
  assert res.body.index("boom <b>").nil?, "the message must be escaped"
end

test "the error page shows the request line" do
  res = request(plain_app, "/boom?page=2&sort=title", "POST")
  assert_includes res.body, "POST /boom?page=2&amp;sort=title HTTP/1.1"
end

test "the error page names any exception class" do
  res = request(plain_app, "/argument")
  assert_equal 500, res.status
  assert_includes res.body, "<h1>ArgumentError</h1>"
  assert_includes res.body, "wrong number of arguments (given 1, expected 0)"
end

test "a template runtime error shows the template name and line" do
  res = request(plain_app, "/template")
  assert_includes res.body, "<h1>Cybertrain::Template::RuntimeError</h1>"
  assert_includes res.body, "posts/show.html.erb"
  assert_includes res.body, "line 12"
  assert_includes res.body, "undefined method &#39;titel&#39; for Post"
end

test "a template syntax error shows its location" do
  res = request(plain_app, "/syntax")
  assert_includes res.body, "posts/_form.html.erb"
  assert_includes res.body, "line 3"
end

test "an error without a template location shows no template line" do
  res = request(plain_app, "/boom")
  assert res.body.index("Template:").nil?, "no template line expected"
end

test "template_location splits a template error message" do
  assert_equal "posts/show.html.erb:12", Cybertrain::Dev::ErrorPage.template_location("posts/show.html.erb:12: boom")
  assert_equal "", Cybertrain::Dev::ErrorPage.template_location("boom: 12: nothing")
  assert_equal "", Cybertrain::Dev::ErrorPage.template_location("posts/show.html.erb:x: boom")
end

test "template_location wants the location at the very start of the message" do
  assert_equal "", Cybertrain::Dev::ErrorPage.template_location("undefined thing in posts/show.html.erb:3: x")
  assert_equal "", Cybertrain::Dev::ErrorPage.template_location("error: posts/show.html.erb:3: x")
  assert_equal "posts/_form.html.erb:7", Cybertrain::Dev::ErrorPage.template_location("posts/_form.html.erb:7: see b.erb:9: x")
end

test "the error page replaces every header the failed action had set" do
  res = request(plain_app, "/download")
  assert_equal 500, res.status
  assert_equal "text/html; charset=utf-8", res.header("Content-Type")
  assert res.header("Location").nil?, "no stale Location"
  assert res.header("Content-Disposition").nil?, "no stale Content-Disposition"
  assert_equal 0, res.cookies.size
  assert_equal 1, res.headers.size
  assert_includes res.body, "export failed"
end

test "a successful response passes through untouched" do
  res = request(plain_app, "/")
  assert_equal 200, res.status
  assert_equal "<!DOCTYPE html>\n<html><body class=\"app\"><h1>Posts</h1></body></html>", res.body
end

test "a failed build injects the banner into an HTML response" do
  res = request(Cybertrain::Dev::ErrorPage.new(Raiser.new(Page.new), failed_rebuilder), "/")
  assert_equal 200, res.status
  assert_includes res.body, "Build failed"
  assert_includes res.body, "syntax error, unexpected &lt;end&gt;"
  assert_includes res.body, "<h1>Posts</h1>"
  banner_at = res.body.index("Build failed").to_i
  assert res.body.index("<body class=\"app\">").to_i < banner_at, "the banner goes right after <body>"
  assert banner_at < res.body.index("<h1>Posts</h1>").to_i, "the banner comes before the page"
end

test "the banner is prepended when the page has no body tag" do
  res = request(Cybertrain::Dev::ErrorPage.new(Raiser.new(Page.new), failed_rebuilder), "/fragment")
  assert_equal 0, res.body.index("<div id=\"cybertrain-build-failed\"")
  assert_includes res.body, "<p>no body tag</p>"
end

test "the banner is not injected into a JSON response" do
  res = request(Cybertrain::Dev::ErrorPage.new(Raiser.new(Page.new), failed_rebuilder), "/json")
  assert_equal "{\"ok\":true}", res.body
end

test "the banner is not injected into bodyless responses" do
  app = Cybertrain::Dev::ErrorPage.new(Raiser.new(Page.new), failed_rebuilder)
  ["/no_content", "/not_modified", "/empty", "/continue"].each do |path|
    res = request(app, path)
    assert res.body.empty?, "#{path} must stay empty"
  end
  assert_equal 204, request(app, "/no_content").status
  assert_equal 304, request(app, "/not_modified").status
end

test "the error page carries the banner too" do
  res = request(Cybertrain::Dev::ErrorPage.new(Raiser.new(Page.new), failed_rebuilder), "/boom")
  assert_equal 500, res.status
  assert_includes res.body, "Build failed"
  assert_includes res.body, "boom &lt;b&gt;"
end

test "no banner once a later build succeeds" do
  rebuilder = failed_rebuilder
  rebuilder.record_build(true, "")
  res = request(Cybertrain::Dev::ErrorPage.new(Raiser.new(Page.new), rebuilder), "/")
  assert res.body.index("Build failed").nil?, "no banner expected"
end

test "the rebuild command runs gen then build in the app root, logging to tmp/rebuild.log" do
  r = Cybertrain::Dev::Rebuilder.new("/apps/my blog")
  assert_equal "/apps/my blog/tmp/rebuild.log", r.log_file
  assert_equal "/apps/my blog/build/bin/server", r.binary_path
  assert_equal "mkdir -p '/apps/my blog/tmp' && { cd '/apps/my blog' && spin run gen && spin build server; } " \
               "> '/apps/my blog/tmp/rebuild.log' 2>&1", r.command
  refute r.last_failed
  assert_equal "", r.last_output
end

test "a failing rebuild keeps the command output" do
  log = File.expand_path("tmp/dev_error_page_rebuild.log")
  r = Cybertrain::Dev::Rebuilder.new("tmp/dev_error_page_missing_root", "server", log)
  refute r.rebuild
  assert r.last_failed
  assert_includes r.last_output, "dev_error_page_missing_root"
  File.delete(log) if File.exist?(log)
end

test "no rebuild while cybertrain build holds tmp/cybertrain-build.lock" do
  Dir.mkdir("tmp") unless File.directory?("tmp")
  root = File.expand_path("tmp/dev_error_page_locked_root")
  log = "#{root}/tmp/rebuild.log"
  Dir.mkdir(root) unless File.directory?(root)
  Dir.mkdir("#{root}/tmp") unless File.directory?("#{root}/tmp")
  File.write("#{root}/tmp/cybertrain-build.lock", Process.pid.to_s)
  File.delete(log) if File.exist?(log)
  r = Cybertrain::Dev::Rebuilder.new(root, "server", log)
  refute r.rebuild
  assert r.last_failed
  assert r.last_skipped
  assert_equal "cybertrain build in progress (tmp/cybertrain-build.lock); " \
               "rebuild skipped — save the file again once it finishes", r.last_output
  refute File.exist?(log)
  # once the build is over the banner says so instead of "in progress"
  File.delete("#{root}/tmp/cybertrain-build.lock")
  assert r.last_skipped
  assert_equal "cybertrain build finished; save a file to rebuild", r.last_output
  r.record_build(true, "")
  refute r.last_skipped
  assert_equal "", r.last_output
  Dir.rmdir("#{root}/tmp")
  Dir.rmdir(root)
end

test "a lock whose build process is gone is stale: removed and ignored" do
  Dir.mkdir("tmp") unless File.directory?("tmp")
  root = File.expand_path("tmp/dev_error_page_stale_root")
  lock = "#{root}/tmp/cybertrain-build.lock"
  Dir.mkdir(root) unless File.directory?(root)
  Dir.mkdir("#{root}/tmp") unless File.directory?("#{root}/tmp")
  r = Cybertrain::Dev::Rebuilder.new(root, "server", "#{root}/tmp/rebuild.log")
  refute r.build_in_progress?
  File.write(lock, "2147483647")
  refute r.build_in_progress?
  refute File.exist?(lock)
  File.write(lock, Process.pid.to_s)
  assert r.build_in_progress?
  assert File.exist?(lock)
  # a lock that records no PID cannot be told stale, so it counts as held
  File.write(lock, "")
  assert r.build_in_progress?
  File.delete(lock)
  Dir.rmdir("#{root}/tmp")
  Dir.rmdir(root)
end

test "a lock older than 30 minutes is stale even with a live PID: age wins over aliveness" do
  Dir.mkdir("tmp") unless File.directory?("tmp")
  root = File.expand_path("tmp/dev_error_page_old_lock_root")
  lock = "#{root}/tmp/cybertrain-build.lock"
  Dir.mkdir(root) unless File.directory?(root)
  Dir.mkdir("#{root}/tmp") unless File.directory?("#{root}/tmp")
  r = Cybertrain::Dev::Rebuilder.new(root, "server", "#{root}/tmp/rebuild.log")
  # this test's own PID is alive, so without the age bound the lock would
  # be read as held forever (the failure mode: a reused PID after a
  # SIGKILLed build)
  File.write(lock, Process.pid.to_s)
  assert r.build_in_progress?
  old = Time.now - 31 * 60
  File.utime(old, old, lock)
  refute r.build_in_progress?
  refute File.exist?(lock)
  Dir.rmdir("#{root}/tmp")
  Dir.rmdir(root)
end

test "shell_quote escapes single quotes" do
  assert_equal "'it'\\''s'", Cybertrain::Dev::Rebuilder.shell_quote("it's")
end

Cybertrain::Test.run!
