# Requires the whole framework entry point at once: cross-file compile
# problems (require order, duplicated names) surface here, not in the
# per-feature tests that require only their own files.
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/client"

test "the entry point exposes every M1 feature" do
  head = Cybertrain::HttpParser.parse_head("GET /posts?id=1 HTTP/1.1\r\nHost: x\r\nCookie: a=1")
  req = Cybertrain::Request.new(head.method, head.target, head.headers, "", "127.0.0.1", head.http_version)
  ctx = Cybertrain::Context.new(req)
  ctx.params = Cybertrain::Query.parse(req.query_string)
  assert_equal "1", ctx.params[:id]
  assert_equal({ "a" => "1" }, Cybertrain::Cookies.parse(req.cookie_header))
  ctx.response.body = Cybertrain::Html.escape("<b>")
  assert_includes ctx.response.to_http, "&lt;b&gt;"
  Cybertrain.logger.info("m1 ok")
  assert_equal "0.2.0", Cybertrain::VERSION
end

test "an App routes a request through the default stack" do
  router = Cybertrain::Router.new
  router.get("/hello/:name", "hello") { |c| c.response.body = "hi #{c.params[:name]}" }
  router.post("/items", "items") { |c| c.response.redirect("/hello/created", 303) }
  app = Cybertrain::App.new(router, logging: false)
  client = Cybertrain::Test::Client.new(app)
  res = client.get("/hello/world")
  assert_response res, :ok
  assert_equal "hi world", res.body
  res = client.post("/items", { "x" => "1" })
  assert_redirected_to res, "/hello/created"
  res = client.follow_redirect!
  assert_equal "hi created", res.body
  assert_response client.get("/missing"), :not_found
  assert_equal "/hello/x", router.path_for("hello", { "name" => "x" })
end

test "the Server serves the same App over a socket" do
  router = Cybertrain::Router.new
  router.get("/ping", "ping") { |c| c.response.body = "pong" }
  app = Cybertrain::App.new(router, logging: false)
  server = Cybertrain::Server.new(app, port: 0, logger: Cybertrain::Logger.new(nil, :error))
  server.start
  sock = TCPSocket.new("127.0.0.1", server.port)
  sock.write("GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  raw = +""
  loop do
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
  assert_includes raw, "pong"
end

test "the database layer opens a pooled in-memory SQLite connection" do
  Cybertrain::DB.connect(":memory:", size: 1)
  Cybertrain::DB.with do |c|
    c.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT)")
    c.execute("INSERT INTO notes (body) VALUES (?)", ["hello"])
    rows = c.execute("SELECT id, body FROM notes")
    assert_equal 1, rows.size
    assert_equal "hello", rows[0]["body"]
  end
  Cybertrain::DB.disconnect
  assert_equal "2026-01-02T03:04:05Z", Cybertrain::Cast.iso8601(Time.utc(2026, 1, 2, 3, 4, 5))
end

# A controller wired the way gen/routes.rb will wire it, behind the session
# and CSRF middleware, so the whole M2a surface compiles and runs together.
class NotesController < Cybertrain::Controller
  before_action :remember_visit

  def index
    seen = session["visits"]
    notice = flash[:notice]
    render plain: "visits=#{seen.nil? ? "0" : seen} notice=#{notice.nil? ? "-" : notice} token=#{Cybertrain::CsrfProtection.token_for(session)}"
  end

  def create
    flash[:notice] = "created #{params[:title]}"
    redirect_to "/notes", status: :see_other
  end

  def run_callback(name)
    case name
    when :remember_visit then remember_visit
    else super
    end
  end

  def remember_visit
    count = session["visits"]
    session["visits"] = (count.nil? ? 1 : count.to_i + 1).to_s
  end
end

test "controller, session, flash and CSRF work together through the stack" do
  router = Cybertrain::Router.new
  router.get("/notes", "notes") { |ctx| NotesController.new(ctx).process(:index) { |c| c.index } }
  router.post("/notes", "notes") { |ctx| NotesController.new(ctx).process(:create) { |c| c.create } }
  csrf = Cybertrain::CsrfProtection.new(router)
  stack = Cybertrain::SessionStore.new(csrf, secret: "integration-secret")
  client = Cybertrain::Test::Client.new(stack)

  first = client.get("/notes")
  assert_response first, :ok
  assert_includes first.body, "visits=1 notice=-"
  token = first.body.split("token=")[1]

  assert_response client.post("/notes", { "title" => "x" }), :forbidden
  created = client.post("/notes", { "title" => "x", "authenticity_token" => token })
  assert_redirected_to created, "/notes"
  after = client.follow_redirect!
  assert_includes after.body, "visits=3 notice=created x"
  assert_includes client.get("/notes").body, "visits=4 notice=-"
end

test "the schema DSL and migrations are reachable from the entry point" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table("posts") do |t|
      t.string("title", null: false)
      t.timestamps
    end
  end
  assert_equal ["posts"], definition.tables.map { |t| t.name }
  assert_includes Cybertrain::Schema::Dumper.to_ruby(definition), "create_table \"posts\""
  Cybertrain::Schema.reset!
end

class CreateNotesMigration < Cybertrain::Migration::Base
  def change
    create_table(:notes) do |t|
      t.string(:title, null: false)
      t.timestamps
    end
    add_index(:notes, [:title])
  end
end

test "the migrator applies a migration and the dumper reads it back" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  migrator = Cybertrain::DB::Migrator.new(conn)
  Cybertrain::Migration.reset!
  Cybertrain::Migration.register("20260925000000", CreateNotesMigration.new)
  applied = migrator.migrate(Cybertrain::Migration.all)
  assert_equal 1, applied
  assert_equal ["20260925000000"], migrator.applied_versions
  dumped = Cybertrain::DB::SchemaDumper.dump_to_ruby(conn)
  assert_includes dumped, "create_table \"notes\""
  assert_includes dumped, "index_notes_on_title"
  conn.close
end

def integration_url_resolver
  ->(name, args) { name == "notes_path" ? "/notes" : "/#{name}/#{args.size}" }
end

test "an Application boots the full stack from config" do
  Cybertrain.configure do |c|
    c.env = "test"
    c.database_path = ":memory:"
    c.secret_key_base = "integration-secret-key-base"
    c.log_level = :warn
    c.static_files = false
  end
  router = Cybertrain::Router.new
  router.get("/app", "app") { |ctx| ctx.response.body = "booted #{Cybertrain::Views.url_resolver.call("notes_path", [])}" }
  application = Cybertrain::Application.new(router: router, url_resolver: integration_url_resolver)
  application.boot
  client = Cybertrain::Test::Client.new(application)
  res = client.get("/app")
  assert_response res, :ok
  assert_equal "booted /notes", res.body
  assert_response client.post("/app", { "x" => "1" }), :forbidden
  Cybertrain::DB.disconnect
end

Cybertrain::Test.run!
