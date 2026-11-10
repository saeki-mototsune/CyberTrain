require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"
require "cybertrain/model"
require "cybertrain/job"
require "cybertrain/generator"
require_relative "fixtures/gen_app/config/routes"
# helper_method (spec 4.3), on the fixture app loaded through its
# checked-in gen/app.rb: PostsController declares `helper_method
# :viewer_name, :price_label`, GatedController gets `helper_method :admin?`
# from AdminGate's `included` block, and gen/controllers.rb dispatches each
# name to the controller instance (helper_method? / call_helper_method).
# The templates are under test/fixtures/views/helper_method; the fixture's
# ReceiptComponent calls the helper methods from its own template. Like
# test/gen_concerns.rb, this program links SQLite through FFI: its snapshot
# comes from the compiled binary (script/regen-snapshot).
require_relative "fixtures/gen_app/gen/app"

FIXTURE = "test/fixtures/gen_app"

Cybertrain::Views.configure("test/fixtures/views/helper_method", components_root: "#{FIXTURE}/app/components")

# The fixture's output that these tests load, keyed by gen/ path.
def fixture_outputs
  controllers = Cybertrain::Gen::ControllerScan.scan_dir("#{FIXTURE}/app/controllers")
  concerns = Cybertrain::Gen::ConcernScan.scan_dir("#{FIXTURE}/app/controllers")
  helpers = Cybertrain::Gen::HelperScan.scan_dir("#{FIXTURE}/app/helpers")
  {
    "gen/controllers.rb" => Cybertrain::Gen::ControllersEmitter.emit(controllers, Cybertrain::Routes.jobs_page_spec, concerns, helpers),
    "gen/components.rb" => Cybertrain::Gen::ComponentsEmitter.emit(Cybertrain::Gen::ComponentScan.scan_dir("#{FIXTURE}/app/components")),
    "gen/app.rb" => Cybertrain::Gen::Manifest.emit(FIXTURE)
  }
end

def context(path, headers = {})
  Cybertrain::Context.new(Cybertrain::Request.new("GET", path, headers, ""))
end

# The template <controller_path>/<name> rendered by the controller, as an
# action's `render :name, layout: false` would.
def rendered(controller, name)
  controller.render_template(name, {}, layout: "")
  controller.response.body
end

def posts
  PostsController.new(context("/posts"))
end

# A stale file is rewritten so that the next build (and run) picks it up.
test "the checked-in gen/controllers.rb, gen/components.rb and gen/app.rb are fresh" do
  fixture_outputs.each do |rel, source|
    path = "#{FIXTURE}/#{rel}"
    next if File.exist?(path) && File.read(path) == source

    File.write(path, source)
    flunk("fixture stale: #{path} (rewritten; rebuild and rerun)")
  end
end

test "a template calls a helper_method with positional and keyword arguments" do
  assert_equal "ann USD 1.50\n", rendered(posts, "prices")
  # An omitted keyword takes the method's own default.
  assert_equal "USD 0.99\n", rendered(posts, "default_currency")
  # The generated arm checks the arguments as an app helper's does.
  msg = assert_raises("RuntimeError") { rendered(posts, "no_cents") }
  assert_equal "posts/no_cents.html.erb:1: wrong number of arguments for 'price_label' (given 0, expected 1)", msg
  assert PostsController.new(context("/posts")).helper_method?("viewer_name")
  refute PostsController.new(context("/posts")).helper_method?("stamp")
  refute CommentsController.new(context("/posts/1/comments")).helper_method?("viewer_name")
end

test "a component rendered by the template reaches it too" do
  assert_equal "<div><p class=\"receipt\">ann owes EUR 2.50</p>\n</div>\n", rendered(posts, "receipt")
end

test "a helper_method declared in a concern's included block works" do
  assert_equal "admin? true\n", rendered(GatedController.new(context("/gated/1", { "x-admin" => "1" })), "admin")
  assert_equal "admin? false\n", rendered(GatedController.new(context("/gated/1")), "admin")
  # PostsController does not include AdminGate.
  refute posts.helper_method?("admin?")
end

test "a template outside a request (Views.render_partial) raises undefined helper for it" do
  msg = assert_raises("RuntimeError") { Cybertrain::Views.render_partial("posts/viewer") }
  assert_equal "posts/_viewer.html.erb:1: undefined helper 'viewer_name'", msg
end

Cybertrain::Test.run!
