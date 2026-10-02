require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/template"
require "tmpdir"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# plain CRuby: its snapshot must come from the compiled binary (spikes/NOTES.md
# rule 23). The committed one was first captured under CRuby with an FFI shim;
# run script/regen-snapshot test/template_partial_depth.rb on a Spinel machine.
#
# Partials may nest at most Interpreter::MAX_RENDER_DEPTH (12) levels: a
# partial rendering itself (or a cycle) raises a located template error
# instead of overflowing the stack (SystemStackError is no StandardError).

Views = Cybertrain::Views
ROOT = Dir.mktmpdir("cybertrain-depth")
Dir.mkdir(File.join(ROOT, "d"))
Views.configure(ROOT, cache: true)

def put(name, src)
  File.write(File.join(ROOT, "d", name), src)
  nil
end

def render_src(src)
  env = {}
  env["__template_dir"] = "d"
  env["n"] = 0
  template = Cybertrain::Template::Template.parse(src, "d/page")
  Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil)).render(template, env)
end

put("_loop.html.erb", "<%= render 'loop' %>")
put("_ping.html.erb", "<%= render 'pong' %>")
put("_pong.html.erb", "<%= render 'ping' %>")
# Counts down from n to 0: n + 1 nested renders below the page.
put("_down.html.erb", "<%= n %><% if n > 0 %>,<%= render 'down', n: n - 1 %><% end %>")

test "a self-rendering partial raises a located template error" do
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_src("x\n<%= render 'loop' %>") }
  assert_equal "d/_loop.html.erb:1: partial nesting too deep (> 12): d/_loop.html.erb rendered from d/_loop.html.erb", msg
end

test "two partials rendering each other raise too" do
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_src("<%= render 'ping' %>") }
  assert msg.include?("partial nesting too deep (> 12)")
  assert msg.start_with?("d/_")
end

test "the interpreter is usable again after the error" do
  env = {}
  env["__template_dir"] = "d"
  # Seeds the Hash with an Integer value as render_src does: under Spinel a
  # Hash holding only Strings is typed that way, and the `n: 3` local the
  # last render passes would not fit (NOTES rule 9 for containers).
  env["n"] = 0
  interp = Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil))
  template = Cybertrain::Template::Template.parse("<%= render 'loop' %>", "d/page")
  assert_raises("RuntimeError") { interp.render(template, env) }
  fine = Cybertrain::Template::Template.parse("ok", "d/page")
  assert_equal "ok", interp.render(fine, env)
  down = Cybertrain::Template::Template.parse("<%= render 'down', n: 3 %>", "d/page")
  assert_equal "3,2,1,0", interp.render(down, env)
end

test "a 10-level chain renders fine" do
  assert_equal "10,9,8,7,6,5,4,3,2,1,0", render_src("<%= render 'down', n: 10 %>")
end

test "the limit is 12 nested renders, page included" do
  # page + 11 partials = 12 renders: allowed; one more is not.
  html = render_src("<%= render 'down', n: 10 %>")
  assert_equal "10,9,8,7,6,5,4,3,2,1,0", html
  msg = assert_raises("RuntimeError") { render_src("<%= render 'down', n: 11 %>") }
  assert msg.include?("partial nesting too deep (> 12): d/_down.html.erb")
end

Cybertrain::Test.run!

%w[_loop _ping _pong _down].each { |f| File.delete(File.join(ROOT, "d", "#{f}.html.erb")) }
Dir.rmdir(File.join(ROOT, "d"))
Dir.rmdir(ROOT)
