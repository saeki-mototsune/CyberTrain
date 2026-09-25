# The template engine compiled together with the whole framework.
#
# Every test/template_*.rb program requires only the template files, so a
# method name the template engine shares with another framework file
# (HelperBase#call next to every Proc#call, Frame#target next to
# RequestHead#target: spikes/NOTES.md rules 10, 34, 40 and 41) compiled fine
# there and broke only once both were in one program. This program requires
# the framework entry point plus cybertrain/template and exercises the
# stored-block paths such collisions broke (before_action and rescue_from
# blocks, model callbacks) next to a render, and the rest of the stack it
# requires (rule 36: required-but-unreachable code can miscompile).
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/template"
require "cybertrain/test"
require "cybertrain/test/client"

# ---- a model in the generated shape, with a stored-block callback --------

class NoteRelation < Cybertrain::Relation
  def where(h) = (add_where(h); self)
  def order(o) = (set_order(o); self)

  def to_a
    out = Array.new(0) { Note.new }
    rows.each { |r| out << Note.from_row(r) }
    out
  end

  def first
    r = first_row
    return nil if r.nil?
    Note.from_row(r)
  end
end

class Note < Cybertrain::Model
  def self.table_name = "notes"
  def self.column_names = ["id", "title"]
  def model_name = "Note"

  attr_accessor :title

  def initialize(attrs = {})
    super()
    @title = ""
    assign_attributes(attrs)
  end

  def self.from_row(row)
    rec = Note.new
    rec.load_row(row)
    rec
  end

  def load_row(row)
    set_id(Cybertrain::Cast.int(row["id"]))
    @title = Cybertrain::Cast.str(row["title"])
    mark_persisted!
    nil
  end

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    else nil
    end
  end

  def write_attribute(name, value)
    case name
    when :title then @title = Cybertrain::Cast.str(value)
    end
    nil
  end

  def assign_attributes(attrs)
    attrs.each { |k, v| write_attribute(k.to_s.to_sym, v) }
    self
  end

  def to_row = { "title" => Cybertrain::Cast.to_sql(@title) }

  def self.all = NoteRelation.new("notes")

  def self.create(attrs = {})
    rec = Note.new(attrs)
    rec.save
    rec
  end

  def read_association(name)
    case name
    when :comments then ["c1", "c2"]
    else nil
    end
  end

  def attribute_or_method?(name)
    case name
    when :id, :title, :comments then true
    else false
    end
  end
end

class Note
  validates :title, presence: true
  before_save { |r| r.title = r.title.strip }
end

# ---- helpers: the Task 13 entry point, a subclass of HelperBase ----------

class IntegrationHelpers < Cybertrain::Template::HelperBase
  def helper_call(name, args, kwargs, block, interp, env)
    case name
    when "shout" then interp.to_s_value(args[0]).upcase
    when "no_routes" then raise "no routes"
    else super(name, args, kwargs, block, interp, env)
    end
  end
end

VIEWS = Cybertrain::Template::Engine.new("test/fixtures/views")

def page_env
  env = {}
  env["__content_title"] = "Notes"
  env["posts"] = Note.all.order("id").to_a
  env
end

# ---- a controller with stored blocks that renders a template --------------

class NotesController < Cybertrain::Controller
  before_action { |c| c.response.set_header("X-Before", "block") }
  rescue_from(KeyError) { |c, e| c.render plain: "missing #{e.message}", status: :not_found }

  def index
    html = VIEWS.render_with_layout("posts/index", "layouts/application", page_env, IntegrationHelpers.new)
    render html: Cybertrain::SafeString.new(html)
  end

  def create
    Note.create(title: params[:title].to_s)
    redirect_to "/notes", status: :see_other
  end

  def token
    render plain: Cybertrain::CsrfProtection.token_for(session)
  end

  def missing
    raise KeyError, "the key"
  end
end

Cybertrain::DB.connect(":memory:", size: 1)
Cybertrain::DB.with do |c|
  c.execute("CREATE TABLE notes (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL)")
end

def render_inline(src)
  template = Cybertrain::Template::Template.parse(src, "notes/inline")
  Cybertrain::Template::Interpreter.new(IntegrationHelpers.new).render(template, page_env)
end

test "a model callback runs and its record renders in a template" do
  note = Note.create(title: "  first <note>  ")
  assert_equal "first <note>", note.title
  assert_equal "FIRST &lt;NOTE&gt;|2", render_inline("<% posts.each do |p| %><%= shout p.title %>|<%= p.comments.size %><% end %>")
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("\n<%= posts.first.titel %>") }
  assert_equal "notes/inline:2: undefined method 'titel' for Note", msg
  assert_equal "notes/inline:1: no routes", assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= no_routes %>") }
end

test "a controller with before_action and rescue_from blocks renders through the stack" do
  router = Cybertrain::Router.new
  router.get("/notes", "notes") { |ctx| NotesController.new(ctx).process(:index) { |c| c.index } }
  router.post("/notes", "notes") { |ctx| NotesController.new(ctx).process(:create) { |c| c.create } }
  router.get("/token", "token") { |ctx| NotesController.new(ctx).process(:token) { |c| c.token } }
  router.get("/missing", "missing") { |ctx| NotesController.new(ctx).process(:missing) { |c| c.missing } }
  stack = Cybertrain::SessionStore.new(Cybertrain::CsrfProtection.new(router), secret: "template-integration")
  client = Cybertrain::Test::Client.new(stack)

  page = client.get("/notes")
  assert_response page, :ok
  assert_equal "block", page.header("x-before")
  assert_includes page.body, "<head><title>Notes</title></head>"
  assert_includes page.body, "<li>first &lt;note&gt; (2 comments)</li>"
  token = client.get("/token").body
  assert_response client.post("/notes", { "title" => "second" }), :forbidden
  created = client.post("/notes", { "title" => " second ", "authenticity_token" => token })
  assert_redirected_to created, "/notes"
  assert_includes client.follow_redirect!.body, "<li>second (2 comments)</li>"

  missing = client.get("/missing")
  assert_response missing, :not_found
  assert_equal "missing the key", missing.body
  assert_equal "block", missing.header("x-before")
end

test "the default App stack and the Server still work with templates required" do
  router = Cybertrain::Router.new
  router.get("/hello/:name", "hello") { |c| c.response.body = render_inline("hi <%= shout 'x' %>") + " #{c.params[:name]}" }
  app = Cybertrain::App.new(router, logging: false)
  client = Cybertrain::Test::Client.new(app)
  assert_equal "hi X world", client.get("/hello/world").body

  server = Cybertrain::Server.new(app, port: 0, logger: Cybertrain::Logger.new(nil, :error))
  server.start
  sock = TCPSocket.new("127.0.0.1", server.port)
  sock.write("GET /hello/sock HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
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
  assert_includes raw, "hi X sock"
end

test "the schema DSL is reachable next to the template engine" do
  definition = Cybertrain::Schema.define(version: "1") do |s|
    s.create_table("notes") { |t| t.string("title", null: false) }
  end
  assert_equal ["notes"], definition.tables.map { |t| t.name }
  Cybertrain::Schema.reset!
end

Cybertrain::Test.run!
