# Cybertrain::Dev::ErrorPage (the development diagnostics middleware) and
# Cybertrain::Dev::Rebuilder: its command, the cybertrain-build lock, and the
# last_failed/last_output the page reads. Runs under CRuby too: no
# FFI is required here (cybertrain/dev/reexec is left out on purpose).
require "stringio"
require "cybertrain/logger"
require "cybertrain/middleware"
require "cybertrain/template/ast"
require "cybertrain/dev/rebuilder"
require "cybertrain/dev/error_page"
require "cybertrain/http/query"
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
    raise Cybertrain::QueryTooMany, "too many parameters (limit 4096)" if ctx.request.path == "/toomany"
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

test "the diagnostics page carries the security defaults on the wire" do
  wire = request(plain_app, "/boom").to_http
  assert_includes wire, "X-Content-Type-Options: nosniff\r\n"
  assert_includes wire, "X-Frame-Options: SAMEORIGIN\r\n"
  assert_equal 1, wire.scan(/^x-frame-options:/i).length
end

test "parameters past Query's limits are a plain 400, not the diagnostics page" do
  res = request(plain_app, "/toomany")
  assert_equal 400, res.status
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type")
  assert_equal "Bad Request: too many parameters (limit 4096)", res.body
end

test "the error page shows the request line" do
  res = request(plain_app, "/boom?page=2&sort=title", "POST")
  assert_includes res.body, "POST /boom?page=2&amp;sort=title HTTP/1.1"
end

# A failing request carrying parameters: the params tree as the Router
# would have built it from the query string, and the given body.
def failing_with(target, content_type, payload)
  req = Cybertrain::Request.new("POST", target, { "content-type" => content_type }, payload, "127.0.0.1")
  failing = Cybertrain::Context.new(req)
  failing.params = Cybertrain::Query.parse(req.query_string)
  plain_app.call(failing)
  failing.response
end

test "the error page filters parameter values in the request line and the parameter dump" do
  res = failing_with("/boom?user%5Bpassword%5D=hunter2&user%5Bname%5D=ann&page=2&tags[]=a&api_key=k1", "text/plain", "")
  assert_equal 500, res.status
  assert res.body.index("hunter2").nil?, "the password must not be shown"
  assert res.body.index("k1").nil?, "the api key must not be shown"
  assert_includes res.body, "POST /boom?user%5Bpassword%5D=[FILTERED]&amp;user%5Bname%5D=ann&amp;page=2&amp;tags[]=a&amp;api_key=[FILTERED] HTTP/1.1"
  assert_includes res.body, "<pre class=\"params\">Parameters: {&quot;page&quot;=&gt;&quot;2&quot;, &quot;api_key&quot;=&gt;&quot;[FILTERED]&quot;, &quot;tags&quot;=&gt;[&quot;a&quot;], &quot;user&quot;=&gt;{&quot;password&quot;=&gt;&quot;[FILTERED]&quot;, &quot;name&quot;=&gt;&quot;ann&quot;}}</pre>"
  assert res.body.index("<pre class=\"json\">").nil?, "no JSON dump for a non-JSON body"
end

test "the error page dumps a JSON body with filtered members, recursively" do
  res = failing_with("/boom", "application/json", "{\"user\":{\"name\":\"a\",\"API_Key\":\"k1\"},\"items\":[{\"token\":\"t1\"},1,null,true],\"secret\":{\"x\":1},\"n\":1.5}")
  assert res.body.index("k1").nil?, "the api key must not be shown"
  assert res.body.index("t1").nil?, "the token must not be shown"
  assert_includes res.body, "<pre class=\"json\">JSON body: {&quot;user&quot;=&gt;{&quot;name&quot;=&gt;&quot;a&quot;, &quot;API_Key&quot;=&gt;&quot;[FILTERED]&quot;}, &quot;items&quot;=&gt;[{&quot;token&quot;=&gt;&quot;[FILTERED]&quot;}, 1, nil, true], &quot;secret&quot;=&gt;&quot;[FILTERED]&quot;, &quot;n&quot;=&gt;1.5}</pre>"
  assert_includes res.body, "<pre class=\"params\">Parameters: {}</pre>"
end

test "a JSON body that does not parse is left out of the dump" do
  res = failing_with("/boom", "application/json", "{\"password\": ")
  assert_equal 500, res.status
  assert res.body.index("<pre class=\"json\">").nil?, "no dump for a body that does not parse"
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

test "the rebuild command runs gen then an incremental build in the app root, logging to tmp/rebuild.log" do
  r = Cybertrain::Dev::Rebuilder.new("/apps/my blog")
  assert_equal "/apps/my blog/tmp/rebuild.log", r.log_file
  assert_equal "/apps/my blog/build/bin/server", r.binary_path
  assert r.incremental
  assert_equal "mkdir -p '/apps/my blog/tmp' && { cd '/apps/my blog' && SPIN_DEBUG=1 spin run gen && spin build 'server' -- --incremental; } " \
               "> '/apps/my blog/tmp/rebuild.log' 2>&1", r.command
  refute r.last_failed
  assert_equal "", r.last_output
end

test "without --incremental the rebuild command is the plain spin build" do
  r = Cybertrain::Dev::Rebuilder.new("/apps/my blog")
  assert_equal "mkdir -p '/apps/my blog/tmp' && { cd '/apps/my blog' && SPIN_DEBUG=1 spin run gen && spin build 'server'; } " \
               "> '/apps/my blog/tmp/rebuild.log' 2>&1", r.command(false)
end

test "only spinel refusing the flag reads as a toolchain without --incremental" do
  assert Cybertrain::Dev::Rebuilder.incremental_unsupported?("build server\nspinel: unknown option '--incremental'\nspin: build failed\n")
  refute Cybertrain::Dev::Rebuilder.incremental_unsupported?("app/models/post.rb:3: syntax error\nspin: build failed\n")
  refute Cybertrain::Dev::Rebuilder.incremental_unsupported?("")
end

test "a failing rebuild keeps the command output" do
  log = File.expand_path("tmp/dev_error_page_rebuild.log")
  r = Cybertrain::Dev::Rebuilder.new("tmp/dev_error_page_missing_root", "server", log)
  refute r.rebuild
  assert r.last_failed
  assert_includes r.last_output, "dev_error_page_missing_root"
  File.delete(log) if File.exist?(log)
end

# A `spin` first on PATH that answers like a Spinel release without
# --incremental: it records each build's arguments and refuses the flag.
test "a toolchain that refuses --incremental gets the plain build at once, and from then on" do
  Dir.mkdir("tmp") unless File.directory?("tmp")
  root = File.expand_path("tmp/dev_error_page_fallback_root")
  bin = "#{root}/fakebin"
  calls = "#{root}/calls"
  Dir.mkdir(root) unless File.directory?(root)
  Dir.mkdir(bin) unless File.directory?(bin)
  File.delete(calls) if File.exist?(calls)
  File.write("#{bin}/spin", "#!/bin/sh\n" \
                            "[ \"$1\" = build ] || exit 0\n" \
                            "echo \"$*\" >> '#{calls}'\n" \
                            "case \"$*\" in *--incremental*) echo \"spinel: unknown option '--incremental'\"; exit 1;; esac\n" \
                            "echo built\n")
  File.chmod(0o755, "#{bin}/spin")
  path = ENV["PATH"] || ""
  ENV["PATH"] = "#{bin}:#{path}"
  r = Cybertrain::Dev::Rebuilder.new(root, "server", "#{root}/tmp/rebuild.log")
  assert r.rebuild
  refute r.last_failed
  refute r.incremental
  assert_equal "built\n", r.last_output
  assert r.rebuild
  ENV["PATH"] = path
  assert_equal "build server -- --incremental\nbuild server\nbuild server\n", File.read(calls)
  [calls, "#{bin}/spin", "#{root}/tmp/rebuild.log"].each { |f| File.delete(f) if File.exist?(f) }
  ["#{root}/tmp", "#{root}/build", bin, root].each { |d| Dir.rmdir(d) if File.directory?(d) }
end

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

GEN_ROOT = File.expand_path("tmp/dev_error_page_gen_root")
GEN_CALLS = "#{GEN_ROOT}/calls"
GEN_BINARY = "#{GEN_ROOT}/build/bin/gen"
GEN_CHECK = "#{GEN_ROOT}/build/gen-check.c"
GEN_COMPILED = "#{GEN_ROOT}/build/gen-compiled.c"
GEN_STAMP = "#{GEN_ROOT}/build/gen-compiled.stamp"

def write_gen_binary(body)
  File.write(GEN_BINARY, "#!/bin/sh\n#{body}\n")
  File.chmod(0o755, GEN_BINARY)
  nil
end

# Records the binary now there as the one the saved C compiled to.
def adopt_gen_binary(rebuilder)
  File.write(GEN_CHECK, File.read(GEN_COMPILED))
  rebuilder.promote_gen_check
  nil
end

# An app whose `spin` and `spinel` are scripts first on PATH. spin logs every
# call but `flags` (with SPIN_DEBUG=1 in front when it is set), which fails while flags-fails exists: `run gen` compiles
# (leaves a build/bin/gen that logs when run, and exits as the file gen-status
# says), unless spin-reuses exists and there is a binary already; `build` fails while build-fails exists, refuses --incremental while
# no-incremental exists, and edits config/routes.rb while edit-during-build
# exists. spinel's "C" is config/routes.rb; while check-fails exists it leaves
# a partial file and fails, and while check-unreadable exists it leaves a
# directory. Returns the PATH to restore.
def fake_spin_app
  remove_tree(GEN_ROOT)
  Dir.mkdir("tmp") unless File.directory?("tmp")
  ["", "/fakebin", "/config", "/build", "/build/bin"].each { |d| Dir.mkdir("#{GEN_ROOT}#{d}") }
  File.write("#{GEN_ROOT}/config/routes.rb", "# routes\n")
  File.write("#{GEN_ROOT}/compiled-gen", "#!/bin/sh\necho gen-binary >> '#{GEN_CALLS}'\n")
  File.write("#{GEN_ROOT}/fakebin/spin", "#!/bin/sh\n" \
                                         "if [ \"$1\" = flags ]; then\n" \
                                         "  [ -e '#{GEN_ROOT}/flags-fails' ] && exit 1\n" \
                                         "  echo '-I .'; exit 0\n" \
                                         "fi\n" \
                                         "echo \"${SPIN_DEBUG:+SPIN_DEBUG=$SPIN_DEBUG }spin $*\" >> '#{GEN_CALLS}'\n" \
                                         "if [ \"$1\" = run ]; then\n" \
                                         "  [ -e '#{GEN_ROOT}/spin-reuses' ] && [ -e '#{GEN_BINARY}' ] && exit 0\n" \
                                         "  cp '#{GEN_ROOT}/compiled-gen' '#{GEN_BINARY}'; chmod 755 '#{GEN_BINARY}'; exit 0\n" \
                                         "fi\n" \
                                         "[ -e '#{GEN_ROOT}/edit-during-build' ] && echo '# edit' >> '#{GEN_ROOT}/config/routes.rb'\n" \
                                         "[ -e '#{GEN_ROOT}/build-fails' ] && { echo 'syntax error'; exit 1; }\n" \
                                         "case \"$*\" in *--incremental*)\n" \
                                         "  [ -e '#{GEN_ROOT}/no-incremental' ] && { echo \"spinel: unknown option '--incremental'\"; exit 1; };;\n" \
                                         "esac\n" \
                                         "echo built\n")
  File.write("#{GEN_ROOT}/fakebin/spinel", "#!/bin/sh\n" \
                                           "[ -e '#{GEN_ROOT}/check-fails' ] && { echo partial > \"$4\"; exit 1; }\n" \
                                           "[ -e '#{GEN_ROOT}/check-unreadable' ] && { mkdir \"$4\"; exit 0; }\n" \
                                           "cat config/routes.rb > \"$4\"\n")
  File.chmod(0o755, "#{GEN_ROOT}/fakebin/spin")
  File.chmod(0o755, "#{GEN_ROOT}/fakebin/spinel")
  path = ENV["PATH"] || ""
  ENV["PATH"] = "#{GEN_ROOT}/fakebin:#{path}"
  # The fake spin records SPIN_DEBUG when it is set: only the gen step may
  # set it, whatever this test process was started with.
  ENV["SPIN_DEBUG"] = ""
  path
end

def gen_rebuilder
  Cybertrain::Dev::Rebuilder.new(GEN_ROOT, "server", "#{GEN_ROOT}/tmp/rebuild.log")
end

# What ran since the last call.
def gen_calls
  text = File.exist?(GEN_CALLS) ? File.read(GEN_CALLS) : ""
  File.delete(GEN_CALLS) if File.exist?(GEN_CALLS)
  text
end

def finish_fake_spin_app(path)
  ENV["PATH"] = path
  remove_tree(GEN_ROOT)
end

COMPILE_GEN = "SPIN_DEBUG=1 spin run gen\nspin build server -- --incremental\n"
SKIP_GEN = "gen-binary\nspin build server -- --incremental\n"

# gen is built in the mode the CLI builds it in (cybertrain/shell.rb), so the
# server's gen step and the rebuild's share one binary; the app is a release
# build.
test "the rebuild command builds gen in spin's debug mode, as the CLI does" do
  assert_equal "SPIN_DEBUG=1 spin run gen", Cybertrain::Dev::Rebuilder::GEN_COMMAND
  assert_equal "#{Cybertrain::Shell::TOOL_SPIN} run gen", Cybertrain::Dev::Rebuilder::GEN_COMMAND
end

test "the rebuild command takes the gen step it is given" do
  r = Cybertrain::Dev::Rebuilder.new("/apps/my blog")
  assert_equal "mkdir -p '/apps/my blog/tmp' && { cd '/apps/my blog' && ./build/bin/gen && spin build 'server' -- --incremental; } " \
               "> '/apps/my blog/tmp/rebuild.log' 2>&1", r.command(true, "./build/bin/gen")
end

test "the gen check compiles bin/gen.rb to C quietly, with spin's flags and no line map" do
  r = Cybertrain::Dev::Rebuilder.new("/apps/my blog")
  assert_equal "{ cd '/apps/my blog' && mkdir -p build && flags=$(spin flags) && " \
               "spinel bin/gen.rb -c -o build/gen-check.c --force --no-line-map $flags; } > /dev/null 2>&1", r.gen_check_command
end

test "gen is compiled once, then run directly while its C stands still" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  assert r.rebuild
  assert_equal SKIP_GEN, gen_calls
  refute r.last_failed
  assert_equal "built\n", r.last_output
  finish_fake_spin_app(path)
end

test "a full build promotes the checked C, a direct run records nothing" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  assert_equal "# routes\n", File.read(GEN_COMPILED)
  refute File.exist?(GEN_CHECK)
  gen_calls
  assert r.rebuild
  assert_equal SKIP_GEN, gen_calls
  assert File.exist?(GEN_CHECK)
  finish_fake_spin_app(path)
end

# `spin run gen` by hand, from an edit undone since: the C matches, the binary
# is not the one it was compiled to.
test "a binary replaced behind the saved C compiles gen again" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  write_gen_binary("echo replaced >> '#{GEN_CALLS}'")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  assert r.rebuild
  assert_equal SKIP_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a replaced binary newer than its sources does not survive spin's own check" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/spin-reuses", "")
  write_gen_binary("echo replaced >> '#{GEN_CALLS}'")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  assert_equal File.read("#{GEN_ROOT}/compiled-gen"), File.read(GEN_BINARY)
  finish_fake_spin_app(path)
end

test "a saved C with no stamp compiles gen again" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.delete(GEN_STAMP)
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "differing C compiles gen again" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/config/routes.rb", "# routes, longer\n")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  assert_equal "# routes, longer\n", File.read(GEN_COMPILED)
  assert r.rebuild
  assert_equal SKIP_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a missing build/bin/gen does not fail the rebuild" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.delete(GEN_BINARY)
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  refute r.last_failed
  finish_fake_spin_app(path)
end

test "no saved C compiles gen, even with a build/bin/gen there" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.delete(GEN_COMPILED)
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a compile error in the check takes the full command, and its partial C is not promoted" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/check-fails", "")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  refute File.exist?(GEN_CHECK)
  refute File.exist?(GEN_COMPILED)
  File.delete("#{GEN_ROOT}/check-fails")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  assert r.rebuild
  assert_equal SKIP_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "spin flags failing takes the full command" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/flags-fails", "")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "no spinel on PATH takes the full command" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.delete("#{GEN_ROOT}/fakebin/spinel")
  ENV["PATH"] = "#{GEN_ROOT}/fakebin:/usr/bin:/bin"
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  refute File.exist?(GEN_COMPILED)
  finish_fake_spin_app(path)
end

test "a check whose C cannot be read takes the full command and raises nothing" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/check-unreadable", "")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a saved C that cannot be read takes the full command and raises nothing" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.delete(GEN_COMPILED)
  Dir.mkdir(GEN_COMPILED)
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a gen binary that fails falls back to one full build in the same rebuild" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  write_gen_binary("echo broken-binary >> '#{GEN_CALLS}'; exit 1")
  adopt_gen_binary(r)
  assert r.rebuild
  assert_equal "broken-binary\n#{COMPILE_GEN}", gen_calls
  refute r.last_failed
  assert_equal "built\n", r.last_output
  assert r.rebuild
  assert_equal SKIP_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a failed build records nothing, so the next one compiles gen again" do
  path = fake_spin_app
  r = gen_rebuilder
  File.write("#{GEN_ROOT}/build-fails", "")
  refute r.rebuild
  assert r.last_failed
  assert_includes r.last_output, "syntax error"
  refute File.exist?(GEN_COMPILED)
  gen_calls
  File.delete("#{GEN_ROOT}/build-fails")
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "undoing an edit whose full build failed does not read as a match: the binary has moved on" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/config/routes.rb", "# routes, longer\n")
  File.write("#{GEN_ROOT}/build-fails", "")
  refute r.rebuild
  File.delete("#{GEN_ROOT}/build-fails")
  File.write("#{GEN_ROOT}/config/routes.rb", "# routes\n")
  gen_calls
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a failed build on the direct path keeps its output through the full retry, and the saved C" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/build-fails", "")
  refute r.rebuild
  assert_equal "#{SKIP_GEN}#{COMPILE_GEN}", gen_calls
  assert_includes r.last_output, "syntax error"
  File.delete("#{GEN_ROOT}/build-fails")
  assert r.rebuild
  assert_equal SKIP_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "an edit made during the build is seen by the next rebuild" do
  path = fake_spin_app
  r = gen_rebuilder
  File.write("#{GEN_ROOT}/edit-during-build", "")
  assert r.rebuild
  File.delete("#{GEN_ROOT}/edit-during-build")
  gen_calls
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

# The retry compiles gen, edited or not; undoing the edit must not match what
# was saved before it.
test "an edit during a failed retry saves nothing, so undoing it does not read as a match" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  write_gen_binary("echo broken-binary >> '#{GEN_CALLS}'; exit 1")
  adopt_gen_binary(r)
  File.write("#{GEN_ROOT}/edit-during-build", "")
  File.write("#{GEN_ROOT}/build-fails", "")
  refute r.rebuild
  refute File.exist?(GEN_COMPILED)
  refute File.exist?(GEN_STAMP)
  File.delete("#{GEN_ROOT}/edit-during-build")
  File.delete("#{GEN_ROOT}/build-fails")
  File.write("#{GEN_ROOT}/config/routes.rb", "# routes\n")
  gen_calls
  assert r.rebuild
  assert_equal COMPILE_GEN, gen_calls
  finish_fake_spin_app(path)
end

test "a toolchain that starts refusing --incremental still gets the plain build, and the saved C survives" do
  path = fake_spin_app
  r = gen_rebuilder
  assert r.rebuild
  gen_calls
  File.write("#{GEN_ROOT}/no-incremental", "")
  assert r.rebuild
  assert_equal "#{SKIP_GEN}#{COMPILE_GEN}SPIN_DEBUG=1 spin run gen\nspin build server\n", gen_calls
  refute r.incremental
  assert r.rebuild
  assert_equal "gen-binary\nspin build server\n", gen_calls
  finish_fake_spin_app(path)
end

test "the build lock stops the gen check as well" do
  path = fake_spin_app
  r = gen_rebuilder
  Dir.mkdir("#{GEN_ROOT}/tmp")
  File.write("#{GEN_ROOT}/tmp/cybertrain-build.lock", "")
  refute r.rebuild
  assert r.last_skipped
  assert_equal "", gen_calls
  refute File.exist?(GEN_CHECK)
  finish_fake_spin_app(path)
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

test "the rebuild command quotes the build target like every other interpolated value" do
  assert Cybertrain::Dev::Rebuilder.new("/apps/blog", "blog").command.include?("spin build 'blog' -- --incremental; }"), "plain target is quoted"
  tricky = Cybertrain::Dev::Rebuilder.new("/apps/blog", "it's").command
  assert tricky.include?("spin build 'it'\\''s' -- --incremental; }"), "a single quote in the target is escaped"
  assert tricky.index("spin build it's").nil?, "no unquoted target reaches sh"
end

# AppName.problem is the one predicate (`cybertrain build` asks it of
# spin.toml's name too); the Rebuilder, the only user of the target in the app,
# applies it, so Application.new (production included) does not.
test "the Rebuilder refuses a build target that is not usable for spin build" do
  {
    "-x" => "cannot start with '-' (spin would read it as an option)",
    "a/b" => "cannot contain '/'",
    ".." => "cannot be '.' or '..'",
    "." => "cannot be '.' or '..'",
    "a b" => "cannot contain whitespace",
    "" => "cannot be empty"
  }.each do |bad, reason|
    message = assert_raises("ArgumentError") { Cybertrain::Dev::Rebuilder.new("/apps/blog", bad) }
    assert_equal "build target #{bad.inspect} #{reason}", message
  end
  # Ordinary names, including one the shell has to quote, are accepted.
  Cybertrain::Dev::Rebuilder.new("/apps/blog", "blog")
  Cybertrain::Dev::Rebuilder.new("/apps/blog", "my-app")
  Cybertrain::Dev::Rebuilder.new("/apps/blog", "it's")
end

test "shell_quote escapes single quotes" do
  assert_equal "'it'\\''s'", Cybertrain::Shell.quote("it's")
end

Cybertrain::Test.run!
