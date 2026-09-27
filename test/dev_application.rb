# The development loop's pieces inside the whole framework (spikes/NOTES.md
# rules 36 and 41): Dev::ErrorPage in front of a booted Application's full
# stack, a real template error, the failed-build banner, and
# Application.port_argument. The rebuild + re-exec path itself cannot run
# in-process; it is verified by hand against a generated app.
#
# It links SQLite (Application#boot) and the execv shim through FFI, so it
# cannot run under CRuby: its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
require "stringio"
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
  def self.url_resolver = ->(name, args) { "/" }
end

config = Cybertrain::Config.new
config.env = "development"
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
CLIENT = Cybertrain::Test::Client.new(Cybertrain::Dev::ErrorPage.new(APP.stack, REBUILDER))

test "port_argument reads a port number from argv[0]" do
  assert_equal 4000, Cybertrain::Application.port_argument(["4000"])
  assert_equal 0, Cybertrain::Application.port_argument([])
  assert_equal 0, Cybertrain::Application.port_argument(["--help"])
  assert_equal 0, Cybertrain::Application.port_argument(["70000"])
  assert_equal 0, Cybertrain::Application.port_argument([""])
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

test "the rebuilder targets the app's build/bin/blog" do
  assert_equal File.expand_path("#{ROOT}/build/bin/blog"), REBUILDER.binary_path
  assert_equal File.expand_path("#{ROOT}/tmp/rebuild.log"), REBUILDER.log_file
end

Cybertrain::Test.run!
