require "cybertrain/test"
require "cybertrain/template"
require "tmpdir"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

class Post < Cybertrain::Model
  def initialize(title, comments)
    super()
    @title = title
    @comments = comments
  end

  def model_name = "Post"

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    else nil
    end
  end

  def read_association(name)
    case name
    when :comments then @comments
    else nil
    end
  end
end

Engine = Cybertrain::Template::Engine
VIEWS = "test/fixtures/views"

def helpers = Cybertrain::Template::HelperBase.new

# Hash<String, value>, the one environment type (see test/template_interpreter.rb).
def new_env
  env = {}
  env["n"] = 7
  env["posts"] = [Post.new("First <post>", ["a", "b"]), Post.new("Second", [])]
  env
end

test "renders a template with a loop inside the layout" do
  env = new_env
  env["__content_title"] = "All posts"
  html = Engine.new(VIEWS).render_with_layout("posts/index", "layouts/application", env, helpers)
  expected = <<~HTML
    <!DOCTYPE html>
    <html>
    <head><title>All posts</title></head>
    <body>
    <h1>Posts</h1>
    <ul>
      <li>First &lt;post&gt; (2 comments)</li>
      <li>Second (0 comments)</li>
    </ul>

    </body>
    </html>
  HTML
  assert_equal expected, html
end

test "renders without a layout" do
  env = new_env
  env["posts"] = []
  assert_equal "<h1>Posts</h1>\n<p>No posts yet.</p>\n", Engine.new(VIEWS).render("posts/index", env, helpers)
end

test "strict locals come from the line-1 comment" do
  engine = Engine.new(VIEWS)
  form = engine.template("posts/_form")
  assert form.strict_locals?
  assert_equal ["post"], form.locals
  assert_equal "posts/_form.html.erb", form.name
  assert_equal "test/fixtures/views/posts/_form.html.erb", form.source_path
  refute engine.template("posts/index").strict_locals?
  assert_equal 0, engine.template("posts/index").locals.size
  env = new_env
  env["post"] = Post.new("A \"quoted\" title", [])
  assert_equal "<form><input name=\"post[title]\" value=\"A &quot;quoted&quot; title\"></form>\n", engine.render("posts/_form", env, helpers)
end

test "names with and without the extension are the same template" do
  engine = Engine.new(VIEWS)
  assert engine.template("posts/index").equal?(engine.template("posts/index.html.erb"))
  assert engine.exists?("posts/index")
  assert engine.exists?("layouts/application.html.erb")
  refute engine.exists?("posts/nope")
end

test "a missing template raises MissingTemplate with the path" do
  msg = assert_raises("MissingTemplate") { Engine.new(VIEWS).template("posts/nope") }
  assert_equal "Missing template test/fixtures/views/posts/nope.html.erb", msg
  msg = assert_raises("MissingTemplate") { Engine.new(VIEWS).render_with_layout("posts/index", "layouts/nope", new_env, helpers) }
  assert_equal "Missing template test/fixtures/views/layouts/nope.html.erb", msg
end

ROOT = Dir.mktmpdir("cybertrain-views")

test "cache off re-reads a template after a rewrite" do
  path = File.join(ROOT, "page.html.erb")
  File.write(path, "v1 <%= n %>")
  engine = Engine.new(ROOT, cache: false)
  assert_equal "v1 7", engine.render("page", new_env, helpers)
  first = engine.template("page")
  assert first.equal?(engine.template("page"))
  File.write(path, "version two <%= n + 1 %>")
  assert_equal "version two 8", engine.render("page", new_env, helpers)
end

test "cache on keeps the first parse until clear_cache!" do
  path = File.join(ROOT, "cached.html.erb")
  File.write(path, "one")
  engine = Engine.new(ROOT)
  assert_equal "one", engine.render("cached", new_env, helpers)
  File.write(path, "two!")
  assert_equal "one", engine.render("cached", new_env, helpers)
  engine.clear_cache!
  assert_equal "two!", engine.render("cached", new_env, helpers)
end

test "errors name the template file and line" do
  File.write(File.join(ROOT, "broken.html.erb"), "<p>\n<% if n %>\n")
  msg = assert_raises("SyntaxError") { Engine.new(ROOT).template("broken") }
  assert_equal "broken.html.erb:2: 'if' without 'end'", msg
  File.write(File.join(ROOT, "typo.html.erb"), "a\n<%= n.bogus %>")
  msg = assert_raises("RuntimeError") { Engine.new(ROOT).render("typo", new_env, helpers) }
  assert_equal "typo.html.erb:2: undefined method 'bogus' for Integer", msg
  File.write(File.join(ROOT, "helper.html.erb"), "<%= link_to 'x', '/' %>")
  msg = assert_raises("RuntimeError") { Engine.new(ROOT).render("helper", new_env, helpers) }
  assert_equal "helper.html.erb:1: undefined helper 'link_to'", msg
end

Cybertrain::Test.run!

%w[page cached broken typo helper].each { |f| File.delete(File.join(ROOT, "#{f}.html.erb")) }
Dir.rmdir(ROOT)
