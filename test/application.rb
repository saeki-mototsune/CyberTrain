# Cybertrain::Config and Cybertrain::Application: config defaults and
# environment overrides, the secret, the production stack (ErrorPages in
# front), and a booted Application serving requests through its full
# middleware stack (RequestLogger -> Static -> MethodOverride ->
# SessionStore -> CsrfProtection -> Router) with
# Cybertrain::Test::Client -- every middleware the program requires is
# exercised (spikes/NOTES.md rule 36).
#
# It links SQLite through FFI (Application#boot connects the database), so
# it cannot run under CRuby: its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/application"
require "cybertrain/test"
require "cybertrain/test/client"

# ---- a scratch app root: views, public files, the secret key -------------

ROOT = "tmp/application_test"

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
  dir = File.dirname(path)
  parts = dir.split("/")
  current = +""
  parts.each do |part|
    current << "/" unless current.empty?
    current << part
    Dir.mkdir(current) unless Dir.exist?(current)
  end
  File.write(path, content)
  nil
end

remove_tree(ROOT)
write_file("#{ROOT}/views/layouts/site.html.erb", "<title>Site</title>\n<%= csrf_meta_tags %>\n<%= yield %>\n")
write_file("#{ROOT}/views/pages/index.html.erb", "<h1>Home</h1>\n")
write_file("#{ROOT}/views/pages/links.html.erb", "<%= link_to \"Notes\", notes_path %>\n")
write_file("#{ROOT}/public/robots.txt", "User-agent: *\n")
at_exit { remove_tree(ROOT) }

# Every variable Config reads, cleared so the defaults are deterministic.
CONFIG_ENV = ["CYBERTRAIN_ENV", "PORT", "CYBERTRAIN_DATABASE", "CYBERTRAIN_SECRET_KEY_BASE", "SPINEL_WORKERS"]
SAVED_ENV = {}
CONFIG_ENV.each do |name|
  value = ENV[name]
  SAVED_ENV[name] = value unless value.nil?
end

def clear_config_env
  CONFIG_ENV.each { |name| ENV.delete(name) }
  nil
end

def restore_config_env
  clear_config_env
  SAVED_ENV.each_key { |name| ENV[name] = SAVED_ENV[name].to_s }
  nil
end

# The chain's classes, outermost first.
def stack_names(app)
  names = []
  node = app.stack
  until node.nil?
    names << node.class.name
    node = node.app
  end
  names
end

# ---- Config ----------------------------------------------------------------

test "config defaults in development" do
  clear_config_env
  c = Cybertrain::Config.new
  restore_config_env
  assert_equal "development", c.env
  assert c.development?
  refute c.test?
  refute c.production?
  assert_equal "127.0.0.1", c.host
  assert_equal 3000, c.port
  assert_equal "storage/development.sqlite3", c.database_path
  assert_equal "", c.secret_key_base
  assert_equal "app/views", c.views_root
  assert_equal "public", c.public_root
  assert_equal "layouts/application", c.layout
  assert_equal :info, c.log_level
  assert_equal "_cybertrain_session", c.session_cookie_name
  assert_equal 1209600, c.session_max_age
  assert_equal 4, c.pool_size
  refute c.session_secure
  assert c.static_files
  assert c.csrf
  assert_equal 1, c.workers
  assert_equal "tmp/secret_key", c.secret_key_path
end

test "environment variables override the config defaults" do
  clear_config_env
  ENV["CYBERTRAIN_ENV"] = "production"
  ENV["PORT"] = "8080"
  ENV["CYBERTRAIN_SECRET_KEY_BASE"] = "from-env"
  ENV["SPINEL_WORKERS"] = "3"
  c = Cybertrain::Config.new
  ENV["CYBERTRAIN_DATABASE"] = "/var/db/blog.sqlite3"
  with_database = Cybertrain::Config.new
  restore_config_env
  assert c.production?
  assert c.session_secure
  assert_equal 8080, c.port
  assert_equal "storage/production.sqlite3", c.database_path
  assert_equal "from-env", c.secret_key_base
  assert_equal 3, c.workers
  assert_equal "/var/db/blog.sqlite3", with_database.database_path
end

test "an empty CYBERTRAIN_DATABASE counts as unset" do
  clear_config_env
  ENV["CYBERTRAIN_ENV"] = "test"
  ENV["CYBERTRAIN_DATABASE"] = ""
  c = Cybertrain::Config.new
  restore_config_env
  assert c.test?
  assert_equal "storage/test.sqlite3", c.database_path
end

test "resolve_secret! creates the secret key file in the test env and reuses it" do
  c = Cybertrain::Config.new
  c.env = "test"
  c.secret_key_path = "#{ROOT}/tmp/secret_key"
  secret = c.resolve_secret!
  assert_equal 64, secret.length
  assert_equal secret, c.secret_key_base
  assert_equal secret, File.read("#{ROOT}/tmp/secret_key").strip
  again = Cybertrain::Config.new
  again.env = "test"
  again.secret_key_path = "#{ROOT}/tmp/secret_key"
  assert_equal secret, again.resolve_secret!
end

test "resolve_secret! keeps an explicit secret_key_base" do
  c = Cybertrain::Config.new
  c.env = "production"
  c.secret_key_base = "configured"
  assert_equal "configured", c.resolve_secret!
end

test "resolve_secret! raises in production when the secret is empty" do
  c = Cybertrain::Config.new
  c.env = "production"
  c.secret_key_base = ""
  c.secret_key_path = "#{ROOT}/tmp/never_written"
  assert_raises("RuntimeError") { c.resolve_secret! }
  refute File.exist?("#{ROOT}/tmp/never_written")
end

# ---- Cybertrain.configure, the way config/app.rb calls it -----------------

Cybertrain.configure do |c|
  c.env = "test"
  c.database_path = ":memory:"
  c.pool_size = 1
  c.views_root = "#{ROOT}/views"
  c.public_root = "#{ROOT}/public"
  c.layout = "layouts/site"
  c.secret_key_path = "#{ROOT}/tmp/secret_key"
  c.log_level = :warn
  c.port = 0
end

test "Cybertrain.configure fills the process-wide config" do
  assert Cybertrain.config_loaded?
  assert_equal "test", Cybertrain.env
  assert_equal ":memory:", Cybertrain.config.database_path
  assert_equal "layouts/site", Cybertrain.config.layout
end

test "DB::CLI.database_path follows Cybertrain.config once it is loaded" do
  assert_equal ":memory:", Cybertrain::DB::CLI.database_path
end

# ---- the Application, as Cybertrain::Main builds it for bin/<name>.rb -----

class PagesController < Cybertrain::Controller
  def index
    Cybertrain::DB.with { |c| c.execute("SELECT 1 AS one") }
  end

  def links
  end

  def visit
    count = session["visits"]
    session["visits"] = (count.nil? ? 1 : count.to_i + 1).to_s
    render plain: "visits=#{session["visits"]}"
  end

  def create
    render plain: "created #{params[:title]}", status: :created
  end

  def destroy
    render plain: "destroyed #{params[:id]}"
  end
end

router = Cybertrain::Router.new
router.get("/", "root") { |ctx| PagesController.new(ctx).process(:index) { |c| c.index } }
router.get("/links", "links") { |ctx| PagesController.new(ctx).process(:links) { |c| c.links } }
router.get("/visit", "visit") { |ctx| PagesController.new(ctx).process(:visit) { |c| c.visit } }
router.post("/notes", "notes") { |ctx| PagesController.new(ctx).process(:create) { |c| c.create } }
router.delete("/notes/:id", "note") { |ctx| PagesController.new(ctx).process(:destroy) { |c| c.destroy } }

# The Application Cybertrain::Main builds for bin/<name>.rb, minus views:
# and name:. NOTE(Spinel 2026.09.12): a lambda literal written as a keyword
# argument is not seen as escaping, so its parameters keep the no-evidence
# Integer default and read garbage when the template helpers call it (`name`
# arrives as 0). This resolver ignores its arguments; see the path-helper
# test below for the working shape.
APP = Cybertrain::Application.new(router: router, url_resolver: ->(n, a) { "/" })
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

# The token csrf_meta_tags rendered into the last page.
def page_token(body)
  marker = "name=\"csrf-token\" content=\""
  start = body.index(marker)
  return "" if start.nil?

  from = start + marker.length
  body[from, body.index("\"", from).to_i - from].to_s
end

test "the stack is RequestLogger, Static, MethodOverride, SessionStore, CsrfProtection, Router" do
  assert_equal ["Cybertrain::RequestLogger", "Cybertrain::Static", "Cybertrain::MethodOverride",
                "Cybertrain::SessionStore", "Cybertrain::CsrfProtection", "Cybertrain::Router"], stack_names(APP)
end

test "log_level :none, static_files and csrf switch their middleware off" do
  c = Cybertrain::Config.new
  c.log_level = :none
  c.static_files = false
  c.csrf = false
  c.secret_key_base = "bare-secret"
  bare = Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/bare/#{name}" }, config: c)
  assert_equal ["Cybertrain::MethodOverride", "Cybertrain::SessionStore", "Cybertrain::Router"], stack_names(bare)
end

test "production puts ErrorPages outermost" do
  c = Cybertrain::Config.new
  c.env = "production"
  c.log_level = :none
  c.static_files = false
  c.csrf = false
  c.secret_key_base = "production-secret"
  prod = Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/prod/#{name}" }, config: c)
  assert_equal ["Cybertrain::ErrorPages", "Cybertrain::MethodOverride", "Cybertrain::SessionStore", "Cybertrain::Router"], stack_names(prod)
  # Run it once too (spikes/NOTES.md rule 36). There is no public/404.html
  # under the framework root, so the Router's plain text stays.
  res = Cybertrain::Test::Client.new(prod).get("/nowhere")
  assert_response res, :not_found
  assert_equal "Not Found", res.body
end

# name: is the `spin build` target the dev rebuilder shells out with and the
# build/bin path. Application.new does not check it (a production boot never
# builds); Dev::Rebuilder.new applies Cybertrain::AppName.problem, the
# predicate `cybertrain build` applies to spin.toml's name (the refusals are
# tested in test/dev_error_page.rb).
def application_named(name)
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(n, a) { "/" }, name: name)
end

test "Application.new accepts any name; only the Rebuilder refuses one" do
  application_named("blog")
  application_named("my-app")
  application_named("it's")
  ["-x", "a/b", "..", ".", "a b", ""].each do |odd|
    application_named(odd)
    assert_raises("ArgumentError") { Cybertrain::Dev::Rebuilder.new("/apps/blog", odd) }
  end
  assert Cybertrain::Dev::Rebuilder.new("/apps/blog", "blog").command.include?("spin build 'blog'; }"), "an ordinary target still works"
end

# Two layers on a bad name: Application#serve (a development boot) prints
# `error: <Application.name_problem>` and exits 1 before it builds the
# Rebuilder, so a developer sees a boot failure line, not a backtrace; the
# Rebuilder still raises for direct callers (above). serve itself cannot be
# driven here (it would bind a socket and exit the test process), so this
# tests the text it prints: Application.name_problem, the one thing serve
# asks, with the same refusals as the Rebuilder.
test "Application.name_problem is the text a development boot prints for a bad name" do
  assert_equal "", Cybertrain::Application.name_problem("blog")
  assert_equal "", Cybertrain::Application.name_problem("my-app")
  assert_equal "application name \"-x\" cannot start with '-' (spin would read it as an option)",
               Cybertrain::Application.name_problem("-x")
  assert_equal "application name \"\" cannot be empty", Cybertrain::Application.name_problem("")
  assert_equal "application name \"a/b\" cannot contain '/'", Cybertrain::Application.name_problem("a/b")
  ["-x", "a/b", "..", ".", "a b", ""].each do |odd|
    refute Cybertrain::Application.name_problem(odd).empty?, "#{odd.inspect} should be reported"
    assert_raises("ArgumentError") { Cybertrain::Dev::Rebuilder.new("/apps/blog", odd) }
  end
end

test "production refuses to boot without embedded views" do
  c = Cybertrain::Config.new
  c.env = "production"
  c.secret_key_base = "production-secret"
  none = { "" => "" }
  none.delete("")
  assert Cybertrain::Application.embedded_views_missing?(c, none)
  some = { "pages/index.html.erb" => "<p>hi</p>\n" }
  refute Cybertrain::Application.embedded_views_missing?(c, some)
  c.env = "development"
  refute Cybertrain::Application.embedded_views_missing?(c, none)
end

test "production boots on the embedded table, development on app/views" do
  c = Cybertrain::Config.new
  c.env = "production"
  c.database_path = ":memory:"
  c.secret_key_base = "production-secret"
  c.log_level = :none
  some = { "pages/index.html.erb" => "<p>embedded</p>\n" }
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/" }, views: some, config: c).boot
  assert Cybertrain::Views.engine.exists?("pages/index")
  refute Cybertrain::Views.engine.exists?("layouts/application")
  d = Cybertrain::Config.new
  d.env = "development"
  d.database_path = ":memory:"
  d.secret_key_base = "dev-secret"
  d.log_level = :none
  d.views_root = "test/fixtures/views"
  Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args) { "/" }, views: some, config: d).boot
  assert Cybertrain::Views.engine.exists?("layouts/application")
  refute Cybertrain::Views.engine.exists?("pages/index")
  APP.boot # Views/logger are process-wide (spikes/NOTES.md rule 18); restore APP's own config for the tests below.
end

test "boot connects the database, configures views and resolves the secret" do
  assert Cybertrain::DB.connected?
  refute Cybertrain::Views.engine.nil?
  assert_equal "layouts/site", Cybertrain::Views.layout_name
  assert_equal :warn, Cybertrain.logger.level
  assert_equal 64, Cybertrain.config.secret_key_base.length
end

test "a GET renders a template inside the layout" do
  res = CLIENT.get("/")
  assert_response res, :ok
  assert_includes res.body, "<title>Site</title>"
  assert_includes res.body, "<h1>Home</h1>"
  assert_equal 64, page_token(res.body).length
end

test "a POST without the CSRF token is forbidden" do
  assert_response CLIENT.post("/notes", { "title" => "x" }), :forbidden
end

test "a POST with the token from the page passes" do
  token = page_token(CLIENT.get("/").body)
  res = CLIENT.post("/notes", { "title" => "hello", "authenticity_token" => token })
  assert_response res, :created
  assert_equal "created hello", res.body
end

test "a _method=delete POST reaches the DELETE route" do
  token = page_token(CLIENT.get("/").body)
  res = CLIENT.post("/notes/7", { "_method" => "delete", "authenticity_token" => token })
  assert_response res, :ok
  assert_equal "destroyed 7", res.body
end

test "the session cookie round trips" do
  client = Cybertrain::Test::Client.new(APP)
  assert_equal "visits=1", client.get("/visit").body
  assert client.cookies.key?("_cybertrain_session")
  assert_equal "visits=2", client.get("/visit").body
  assert_equal "visits=3", client.get("/visit").body
  assert_equal "visits=1", Cybertrain::Test::Client.new(APP).get("/visit").body
end

test "a static file is served from the public root" do
  res = CLIENT.get("/robots.txt")
  assert_response res, :ok
  assert_equal "User-agent: *\n", res.body
  assert_response CLIENT.get("/missing.txt"), :not_found
end

ROUTE_NAMES = []

# A url_resolver returned from a method (the shape Gen::Routes-backed apps
# should pass until the keyword-lambda issue above is fixed) reaches the
# templates' path helpers with its arguments intact.
def notes_resolver
  lambda do |name, args|
    ROUTE_NAMES << name
    case name
    when "notes_path" then "/notes"
    else "/unknown/#{name}"
    end
  end
end

test "path helpers in templates call the url_resolver" do
  app = Cybertrain::Application.new(router: router, url_resolver: notes_resolver).boot
  res = Cybertrain::Test::Client.new(app).get("/links")
  assert_response res, :ok
  assert_includes res.body, "<a href=\"/notes\">Notes</a>"
  assert_equal ["notes_path"], ROUTE_NAMES
end

# The exact shape the Application usage comment documents: a
# Gen::Routes-style module whose url_resolver is a method-returned lambda.
module FakeGenRoutes
  NAMES = []

  def self.path_for(name, args)
    NAMES << name
    name == "notes_path" ? "/gen/notes" : "/gen/unknown"
  end

  def self.url_resolver = ->(name, args) { path_for(name, args) }
end

test "a method-returned Gen::Routes-style url_resolver keeps its route names" do
  app = Cybertrain::Application.new(router: router, url_resolver: FakeGenRoutes.url_resolver).boot
  res = Cybertrain::Test::Client.new(app).get("/links")
  assert_response res, :ok
  assert_includes res.body, "<a href=\"/gen/notes\">Notes</a>"
  assert_equal ["notes_path"], FakeGenRoutes::NAMES
end

test "the server listens on the configured host and port" do
  server = APP.server
  assert_equal "127.0.0.1", server.host
  server.start
  sock = TCPSocket.new("127.0.0.1", server.port)
  sock.write("GET /robots.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  raw = +""
  while true
    break if sock.wait_readable(5).nil?
    begin
      raw << sock.readpartial(4096)
    rescue EOFError
      break
    end
  end
  sock.close
  server.stop
  assert_includes raw, "HTTP/1.1 200 OK"
  assert_includes raw, "User-agent: *"
end

Cybertrain::Test.run!
