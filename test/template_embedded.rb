require "cybertrain/test"
require "cybertrain/template"
require "cybertrain/template/helpers"
require "cybertrain/views"

# Template::Engine.embedded: templates come from a Hash instead of app/views.
# No database of its own, but cybertrain/template/interpreter.rb requires
# cybertrain/model -> cybertrain/db -> sqlite_ffi.rb, whose `ffi_lib` etc. are
# Spinel-only, so this program cannot run under CRuby either (same as
# template_engine.rb and template_interpreter.rb): its snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23), not `spin test --regen`.

Engine = Cybertrain::Template::Engine

# Helpers#render_helper looks templates up through the process-wide
# Cybertrain::Views.engine (not through any engine instance the test builds
# locally), so Views is configured with the same table up front.
def helpers = Cybertrain::Template::Helpers.new(nil)

def sources
  table = { "" => "" }
  table.delete("")
  table["layouts/application.html.erb"] = "<html><title><%= yield :title %></title><body>\n<%= yield %></body></html>\n"
  table["pages/index.html.erb"] = "<h1>Hello <%= name %></h1>\n<%= render \"pages/note\", note: \"n1\" %>\n"
  table["pages/_note.html.erb"] = "<%# locals: (note:) %>\n<p><%= note %></p>\n"
  table["pages/broken.html.erb"] = "<p>ok</p>\n<%= missing_helper %>\n"
  table
end

def new_env
  # A String-only literal Hash would monomorphize as Hash<String, String>;
  # the interpreter stores non-String values into env too (render_with_layout
  # sets "__content" to a SafeString), so a nil entry widens it to
  # Hash<String, value>, matching template_interpreter.rb's new_env.
  env = {}
  env["name"] = "<world>"
  env["__content_title"] = "Home"
  env["__widen"] = nil
  env
end

Cybertrain::Views.configure_embedded(sources)

test "renders a page and its partial from the embedded table" do
  engine = Engine.embedded(sources)
  assert_equal "<h1>Hello &lt;world&gt;</h1>\n<p>n1</p>\n\n", engine.render("pages/index", new_env, helpers)
end

test "renders inside the embedded layout" do
  html = Engine.embedded(sources).render_with_layout("pages/index", "layouts/application", new_env, helpers)
  assert_equal "<html><title>Home</title><body>\n<h1>Hello &lt;world&gt;</h1>\n<p>n1</p>\n\n</body></html>\n", html
end

test "names with and without the extension are the same template, parsed once" do
  engine = Engine.embedded(sources)
  assert engine.template("pages/index").equal?(engine.template("pages/index.html.erb"))
  assert engine.exists?("pages/index")
  assert engine.exists?("pages/_note.html.erb")
  refute engine.exists?("pages/nope")
end

test "the template name is the key, so errors keep the name:line shape" do
  engine = Engine.embedded(sources)
  assert_equal "pages/index.html.erb", engine.template("pages/index").name
  assert_equal "pages/index.html.erb", engine.template("pages/index").source_path
  error = assert_raises("Cybertrain::Template::RuntimeError") { engine.render("pages/broken", new_env, helpers) }
  assert_includes error, "pages/broken.html.erb:2"
end

test "a missing embedded template says so" do
  error = assert_raises("Cybertrain::Template::MissingTemplate") { Engine.embedded(sources).template("pages/nope") }
  assert_equal "Missing template pages/nope.html.erb (embedded)", error
end

test "Views.configure_embedded installs an embedded engine" do
  Cybertrain::Views.configure_embedded(sources)
  assert Cybertrain::Views.engine.exists?("pages/index")
  refute Cybertrain::Views.engine.exists?("pages/nope")
end

Cybertrain::Test.run!
