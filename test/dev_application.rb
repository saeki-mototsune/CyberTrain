# The development loop's pieces inside the whole framework (spikes/NOTES.md
# rules 36 and 41): Dev::ErrorPage in front of a booted Application's full
# stack, a real template error, the failed-build banner, and
# Application.port_argument, and the server role as `cybertrain server`
# supervises it (on an inherited listener, the banner from the state file,
# no Rebuilder). The rebuild + re-exec path itself cannot run in-process; it
# is verified by hand against a generated app.
#
# It links SQLite (Application#boot) and the execv shim through FFI, so it
# cannot run under CRuby: its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
require "stringio"
require "socket"
require "cybertrain"
require "cybertrain/application"
require "cybertrain/dev"
require "cybertrain/test"
require "cybertrain/test/client"

ROOT = "tmp/dev_application_test"

def remove_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| remove_tree("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

def write_file(path, content)
  current = +""
  File.dirname(path).split("/").each do |part|
    current << "/" unless current.empty?
    current << part
    Dir.mkdir(current) unless Dir.exist?(current)
  end
  File.write(path, content)
  nil
end

remove_tree(ROOT)
write_file("#{ROOT}/views/layouts/site.html.erb", "<html><body class=\"site\">\n<%= yield %>\n</body></html>\n")
write_file("#{ROOT}/views/pages/index.html.erb", "<h1>Home</h1>\n")
write_file("#{ROOT}/views/pages/broken.html.erb", "<h1>Broken</h1>\n<p><%= no_such_helper(1) %></p>\n")
write_file("#{ROOT}/public/robots.txt", "User-agent: *\n")
at_exit { remove_tree(ROOT) }

class PagesController < Cybertrain::Controller
  def index
  end

  def broken
  end

  def boom
    raise ArgumentError, "bad <input>"
  end

  def status
    render json: { "ok" => true }
  end
end

router = Cybertrain::Router.new
router.get("/", "root") { |ctx| PagesController.new(ctx).process(:index) { |c| c.index } }
router.get("/broken", "broken") { |ctx| PagesController.new(ctx).process(:broken) { |c| c.broken } }
router.get("/boom", "boom") { |ctx| PagesController.new(ctx).process(:boom) { |c| c.boom } }
router.get("/status", "status") { |ctx| PagesController.new(ctx).process(:status) { |c| c.status } }

module DevRoutes
  def self.url_resolver = ->(name, args, options) { "/" }
end

config = Cybertrain::Config.new
config.env = "development"
config.allowed_hosts << "www.example.com" # Test::Client's explicit test hostname.
config.database_path = ":memory:"
config.secret_key_base = "dev-application-test-secret"
config.views_root = "#{ROOT}/views"
config.public_root = "#{ROOT}/public"
config.layout = "layouts/site"

# Request and error logs stay out of the snapshot.
Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)
APP = Cybertrain::Application.new(router: router, url_resolver: DevRoutes.url_resolver, config: config)
APP.boot

REBUILDER = Cybertrain::Dev::Rebuilder.new(File.expand_path(ROOT), "blog")
# What Application#serve_development puts in front of the stack.
CLIENT = Cybertrain::Test::Client.new(Cybertrain::HostAuthorization.new(
  Cybertrain::Dev::ErrorPage.new(APP.stack, REBUILDER), config.allowed_hosts))

test "port_argument reads a port number from argv[0]" do
  assert_equal 4000, Cybertrain::Application.port_argument(["4000"])
  assert_equal 0, Cybertrain::Application.port_argument([])
  assert_equal 0, Cybertrain::Application.port_argument(["--help"])
  assert_equal 0, Cybertrain::Application.port_argument(["70000"])
  assert_equal 0, Cybertrain::Application.port_argument([""])
end

# Spinel counts main among SPINEL_WORKERS (N-1 helpers), and main only waits
# in a server, so the binary asks Spinel for one more than the request
# workers; 1 stays 1, main running every thread (spikes/NOTES.md rule 22).
test "spinel_workers gives Spinel one helper per request worker" do
  assert_equal 1, Cybertrain::Application.spinel_workers(1)
  assert_equal 1, Cybertrain::Application.spinel_workers(0)
  assert_equal 3, Cybertrain::Application.spinel_workers(2)
  assert_equal 5, Cybertrain::Application.spinel_workers(4)
end

# Development re-parses an edited template on the request that renders it,
# writing the engine's cache; with two workers two requests could write it at
# once (spikes/NOTES.md rule 57), so development serves on one.
test "development serves one worker whatever SPINEL_WORKERS asks for" do
  dev = Cybertrain::Config.new
  dev.env = "development"
  dev.workers = 4
  assert_equal 1, Cybertrain::Application.serving_workers(dev)
  assert_equal 1, Cybertrain::Application.spinel_workers_for(dev)
  assert_equal "=> development environment (1 worker; workers = 4 is ignored in development)",
               Cybertrain::Application.environment_banner(dev)
  dev.workers = 1
  assert_equal 1, Cybertrain::Application.serving_workers(dev)
  assert_equal "=> development environment (1 worker)", Cybertrain::Application.environment_banner(dev)

  prod = Cybertrain::Config.new
  prod.env = "production"
  prod.workers = 4
  assert_equal 4, Cybertrain::Application.serving_workers(prod)
  assert_equal 5, Cybertrain::Application.spinel_workers_for(prod)
  assert_equal "=> production environment (4 workers)", Cybertrain::Application.environment_banner(prod)
  prod.workers = 1
  assert_equal "=> production environment (1 worker)", Cybertrain::Application.environment_banner(prod)
end

test "the development stack passes a good page through" do
  res = CLIENT.get("/")
  assert_equal 200, res.status
  assert_includes res.body, "<h1>Home</h1>"
  assert res.body.index("Build failed").nil?, "no banner before a failed build"
end

test "a template error is a 500 page naming the template and line" do
  res = CLIENT.get("/broken")
  assert_equal 500, res.status
  assert_includes res.body, "<h1>Cybertrain::Template::RuntimeError</h1>"
  assert_includes res.body, "Template: pages/broken.html.erb, line 2"
  assert_includes res.body, "no_such_helper"
  assert_includes res.body, "GET /broken HTTP/1.1"
end

test "a controller exception is a 500 page with the escaped message" do
  res = CLIENT.get("/boom?x=1")
  assert_equal 500, res.status
  assert_includes res.body, "<h1>ArgumentError</h1>"
  assert_includes res.body, "bad &lt;input&gt;"
  assert_includes res.body, "GET /boom?x=1 HTTP/1.1"
end

test "a failed build puts its output on every HTML page but not on JSON" do
  REBUILDER.record_build(false, "app/controllers/pages_controller.rb:9: syntax error\n")
  page = CLIENT.get("/")
  assert_includes page.body, "<body class=\"site\"><div id=\"cybertrain-build-failed\""
  assert_includes page.body, "pages_controller.rb:9: syntax error"
  assert_includes page.body, "<h1>Home</h1>"
  error = CLIENT.get("/boom")
  assert_includes error.body, "Build failed"
  json = CLIENT.get("/status")
  assert_equal "{\"ok\":true}", json.body
  REBUILDER.record_build(true, "")
  assert CLIENT.get("/").body.index("Build failed").nil?, "the banner goes away after a good build"
end

test "static files still pass through the development stack" do
  res = CLIENT.get("/robots.txt")
  assert_equal 200, res.status
  assert_equal "User-agent: *\n", res.body
end

test "host rejection precedes diagnostics and failed-build output" do
  REBUILDER.record_build(false, "private compiler output")
  ["/", "/boom", "/broken", "/robots.txt"].each do |path|
    res = CLIENT.get(path, { "host" => "rebind.example" })
    assert_equal 403, res.status
    assert_equal "Blocked host", res.body
    assert res.cookies.empty?
  end
  REBUILDER.record_build(true, "")
end

test "the rebuilder targets the app's build/bin/blog" do
  assert_equal File.expand_path("#{ROOT}/build/bin/blog"), REBUILDER.binary_path
  assert_equal File.expand_path("#{ROOT}/tmp/rebuild.log"), REBUILDER.log_file
end

# The supervised role, run in this process: the client thread waits for the
# readiness file, asks for two pages through the role's own listener and
# stops the server, as the supervisor's TERM would.
SUPERVISED_PAGES = Array.new(0) { "" }

# A whole response read off a Connection: close request.
def supervised_get(port, path)
  sock = TCPSocket.new("127.0.0.1", port)
  sock.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
  response = read_until_closed(sock)
  sock.close
  response
end

def read_until_closed(sock)
  response = +""
  response << sock.readpartial(65536) until sock.wait_readable(5).nil?
  response
rescue EOFError, Errno::ECONNRESET
  response
end

def supervised_client(port, ready_path)
  tries = 0
  while !File.exist?(ready_path) && tries < 200
    sleep 0.05
    tries += 1
  end
  SUPERVISED_PAGES << supervised_get(port, "/")
  SUPERVISED_PAGES << supervised_get(port, "/status")
  APP.server.stop
  nil
end

test "supervised, the role serves the state file's failed build on its inherited listener and builds no Rebuilder" do
  state_path = "#{ROOT}/state"
  ready_path = "#{ROOT}/ready"
  File.write(state_path, Cybertrain::Dev::StateFile.format(7, "cruby", "failed", "app/models/post.rb:4: syntax error\n"))
  held = TCPServer.new("127.0.0.1", 0)
  held.autoclose = false
  port = held.addr[1]
  ENV["CYBERTRAIN_DEV_LISTEN_FD"] = held.fileno.to_s
  ENV["CYBERTRAIN_DEV_STATE_FILE"] = state_path
  ENV["CYBERTRAIN_DEV_READY_FILE"] = ready_path
  ENV["CYBERTRAIN_DEV_GENERATION"] = "7"
  client = Thread.new { supervised_client(port, ready_path) }
  APP.serve([])
  client.join
  ["CYBERTRAIN_DEV_LISTEN_FD", "CYBERTRAIN_DEV_STATE_FILE", "CYBERTRAIN_DEV_READY_FILE",
   "CYBERTRAIN_DEV_GENERATION"].each { |name| ENV.delete(name) }
  assert_equal "7", File.read(ready_path)
  assert_equal 2, SUPERVISED_PAGES.size
  page = SUPERVISED_PAGES[0]
  assert_includes page, "HTTP/1.1 200 OK"
  assert_includes page, "<body class=\"site\"><div id=\"cybertrain-build-failed\""
  assert_includes page, "app/models/post.rb:4: syntax error"
  assert_includes page, "<h1>Home</h1>"
  json = SUPERVISED_PAGES[1]
  assert_includes json, "{\"ok\":true}"
  assert json.index("Build failed").nil?, "no banner on JSON"
  assert !APP.server_runner.rebuilding?, "no Rebuilder under supervision"
end

Cybertrain::Test.run!
