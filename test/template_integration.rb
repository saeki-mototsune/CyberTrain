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
# NotesController renders the way an app does: implicit and explicit
# renders through Cybertrain::Views with the layout, partials with strict
# locals, form_with/FormBuilder, link_to and flash, driven through
# SessionStore + CsrfProtection by Cybertrain::Test::Client.
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
    found = rows
    i = 0
    while i < found.size
      out << Note.from_row(found[i])
      i += 1
    end
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
    rec = Note.new(Cybertrain::Model::NO_ATTRIBUTES)
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

def page_env
  env = {}
  env["posts"] = Note.all.order("id").to_a
  env
end

# ---- a controller with stored blocks that renders through Views ----------

# Stands in for the app's generated Gen::Routes.path_for and records the
# route names templates asked for.
ROUTE_CALLS = []

def note_id(v)
  case v
  when Cybertrain::Model then v.to_param
  else ""
  end
end

Cybertrain::Views.configure("test/fixtures/views", cache: true)
Cybertrain::Views.url_resolver = lambda do |name, args|
  ROUTE_CALLS << name
  case name
  when "notes_path" then "/notes"
  when "new_note_path" then "/notes/new"
  when "note_path" then "/notes/#{note_id(args[0])}"
  else raise "no route #{name}"
  end
end

class NotesController < Cybertrain::Controller
  before_action { |c| c.response.set_header("X-Before", "block") }
  rescue_from(KeyError) { |c, e| c.render plain: "missing #{e.message}", status: :not_found }

  def index
    @notes = Note.all.order("id").to_a
  end

  def new_action
    @note = Note.new
  end

  def create
    @note = Note.new(title: params.nested(:note)[:title].to_s)
    if @note.save
      flash[:notice] = "Note created"
      redirect_to "/notes", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def token
    render plain: Cybertrain::CsrfProtection.token_for(session)
  end

  def missing
    raise KeyError, "the key"
  end

  # What gen/controllers.rb emits for this class.
  def view_assigns
    { "notes" => @notes, "note" => @note }
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

# The token form_with printed into the page.
def form_token(body)
  marker = "name=\"authenticity_token\" value=\""
  i = body.index(marker)
  return "" if i.nil?

  start = i + marker.length
  body[start, body.index("\"", start).to_i - start]
end

def notes_client
  router = Cybertrain::Router.new
  router.get("/notes", "notes") { |ctx| NotesController.new(ctx).process(:index) { |c| c.index } }
  router.get("/notes/new", "new_note") { |ctx| NotesController.new(ctx).process(:new) { |c| c.new_action } }
  router.post("/notes", "notes") { |ctx| NotesController.new(ctx).process(:create) { |c| c.create } }
  router.get("/token", "token") { |ctx| NotesController.new(ctx).process(:token) { |c| c.token } }
  router.get("/missing", "missing") { |ctx| NotesController.new(ctx).process(:missing) { |c| c.missing } }
  stack = Cybertrain::SessionStore.new(Cybertrain::CsrfProtection.new(router), secret: "template-integration")
  Cybertrain::Test::Client.new(stack)
end

test "a controller with before_action and rescue_from blocks renders through the stack" do
  client = notes_client
  page = client.get("/notes")
  assert_response page, :ok
  assert_equal "block", page.header("x-before")
  assert_equal "text/html; charset=utf-8", page.header("content-type")
  assert_includes page.body, "<!DOCTYPE html>"
  assert_includes page.body, "<head><title>Notes</title></head>"
  assert_includes page.body, "<li><a href=\"/notes/1\">first &lt;note&gt;</a> (2 comments)</li>"
  token = client.get("/token").body
  assert_response client.post("/notes", { "note[title]" => "second" }), :forbidden
  created = client.post("/notes", { "note[title]" => " second ", "authenticity_token" => token })
  assert_redirected_to created, "/notes"
  assert_includes client.follow_redirect!.body, "<li><a href=\"/notes/2\">second</a> (2 comments)</li>"

  missing = client.get("/missing")
  assert_response missing, :not_found
  assert_equal "missing the key", missing.body
  assert_equal "block", missing.header("x-before")
end

test "a form rendered by form_with posts back through CSRF, re-renders with errors, then redirects with a flash" do
  client = notes_client
  ROUTE_CALLS.clear
  page = client.get("/notes/new")
  assert_response page, :ok
  assert_includes page.body, "<head><title>New note</title></head>"
  assert_includes page.body, "<h1>New note</h1>"
  assert_includes page.body, "<form action=\"/notes\" method=\"post\"><input type=\"hidden\" name=\"authenticity_token\""
  assert_includes page.body, "<label for=\"note_title\">Title</label>"
  assert_includes page.body, "<input type=\"text\" name=\"note[title]\" id=\"note_title\" value=\"\">"
  assert_includes page.body, "<input type=\"submit\" name=\"commit\" value=\"Create Note\">"
  assert_includes page.body, "<a href=\"/notes\">Back</a>"
  assert_equal ["notes_path", "notes_path"], ROUTE_CALLS
  token = form_token(page.body)
  assert_equal 64, token.length

  # Validation fails before before_save strips the title, so the form shows it as typed.
  invalid = client.post("/notes", { "note[title]" => "   ", "authenticity_token" => token })
  assert_response invalid, :unprocessable_entity
  assert_includes invalid.body, "<p class=\"errors\">Title can&#39;t be blank</p>"
  assert_includes invalid.body, "<label for=\"note_title\" class=\"field_with_errors\">Title</label>"
  assert_includes invalid.body, "<input type=\"text\" name=\"note[title]\" id=\"note_title\" value=\"   \" class=\"field_with_errors\">"

  created = client.post("/notes", { "note[title]" => "third <one>", "authenticity_token" => form_token(invalid.body) })
  assert_redirected_to created, "/notes"
  index = client.follow_redirect!
  assert_includes index.body, "<p class=\"notice\">Note created</p>"
  assert_includes index.body, "<li><a href=\"/notes/3\">third &lt;one&gt;</a> (2 comments)</li>"
  assert_includes index.body, "<a href=\"/notes/new\">New note</a>"
  refute client.get("/notes").body.index("Note created"), "the flash lasts one request"
end

test "the default App stack and the Server still work with templates required" do
  router = Cybertrain::Router.new
  router.get("/hello/:name", "hello") { |c| c.response.body = render_inline("hi <%= shout 'x' %>") + " #{c.params[:name]}" }
  app = Cybertrain::App.new(router, logging: false)
  client = Cybertrain::Test::Client.new(app)
  assert_equal "hi X world", client.get("/hello/world").body

  server = Cybertrain::Server.new(Cybertrain::ContextHandler.new(app), port: 0, logger: Cybertrain::Logger.new(nil, :error))
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
