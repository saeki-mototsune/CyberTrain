require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"
require "cybertrain/model"
require "cybertrain/job"
require "cybertrain/generator"
require_relative "fixtures/gen_app/config/routes"
# The checked-in generator output for the fixture app, loaded the way an
# app's binary loads it: gen/models, routes, controllers, then app/models
# and app/controllers. The fixture is shared with the model generator
# (Task 11b), so gen/app.rb pulls in the generated models and this program
# needs the model runtime; it also loads the fixture's jobs and gen/jobs.rb
# (Job.register), so the job runtime too. That runtime links SQLite through FFI, which
# CRuby cannot load: the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23), not from `spin test --regen`.
require_relative "fixtures/gen_app/gen/app"

FIXTURE = "test/fixtures/gen_app"

# The emitters' current output for the fixture, keyed by gen/ path.
def fixture_outputs
  {
    "gen/routes.rb" => Cybertrain::Gen::RoutesEmitter.emit(Cybertrain::Routes.specs),
    "gen/controllers.rb" => Cybertrain::Gen::ControllersEmitter.emit(Cybertrain::Gen::ControllerScan.scan_dir("#{FIXTURE}/app/controllers"),
                                                                     Cybertrain::Routes.jobs_page_spec),
    "gen/helpers.rb" => Cybertrain::Gen::HelpersEmitter.emit(Cybertrain::Gen::HelperScan.scan_dir("#{FIXTURE}/app/helpers")),
    "gen/components.rb" => Cybertrain::Gen::ComponentsEmitter.emit(Cybertrain::Gen::ComponentScan.scan_dir("#{FIXTURE}/app/components")),
    "gen/console.rb" => Cybertrain::Gen::ConsoleEmitter.emit(["Comment", "Post"]),
    "gen/jobs.rb" => Cybertrain::Gen::JobsEmitter.emit(Cybertrain::Gen::JobScan.scan_dir("#{FIXTURE}/app/jobs")),
    "gen/app.rb" => Cybertrain::Gen::Manifest.emit(FIXTURE)
  }
end

def client
  Cybertrain::Test::Client.new(Gen::Routes.build(Cybertrain::Router.new))
end

# A stale file is rewritten so that the next build (and run) picks it up.
test "the checked-in fixture output is fresh" do
  fixture_outputs.each do |rel, source|
    path = "#{FIXTURE}/#{rel}"
    next if File.read(path) == source

    File.write(path, source)
    flunk("fixture stale: #{path} (rewritten; rebuild and rerun)")
  end
end

test "root dispatches to posts#index and runs inherited callbacks" do
  c = client
  res = c.get("/", { "x-viewer" => "alice" })
  assert_response res, :ok
  assert_equal "index 2 for alice /posts/new", res.body
  assert_equal "index", res.header("X-Action")
end

test "the new action runs new_action" do
  res = client.get("/posts/new")
  assert_equal "new /posts /posts/search", res.body
  assert_equal "new", res.header("X-Action")
end

test "show runs set_post through run_callback and uses url helpers" do
  res = client.get("/posts/5")
  assert_equal "show 5 /posts/5/edit /posts/5/comments /posts/5/preview", res.body
end

test "rescue_from with: dispatches through run_callback" do
  res = client.get("/posts/404")
  assert_response res, :not_found
  assert_equal "not found: post 404", res.body
end

test "create redirects with an Integer helper argument" do
  res = client.post("/posts", { "title" => "x" })
  assert_response res, :see_other
  assert_redirected_to res, "/posts/3"
end

test "update redirects to a *_url helper" do
  res = client.patch("/posts/5")
  assert_redirected_to res, "http://localhost:3000/posts/5"
  assert_equal "update", res.header("X-Action")
end

test "PUT, DELETE, edit, member and collection routes dispatch" do
  c = client
  assert_redirected_to c.put("/posts/8"), "http://localhost:3000/posts/8"
  assert_response c.delete("/posts/8"), :no_content
  assert_equal "edit 8", c.get("/posts/8/edit").body
  assert_equal "preview 8", c.get("/posts/8/preview").body
  assert_equal "search rails", c.get("/posts/search?q=rails").body
end

test "nested routes reach the nested controller" do
  c = client
  assert_redirected_to c.post("/posts/5/comments", { "body" => "hi" }), "/posts/5"
  assert_equal "destroy 9 of 5 /posts/5/comments/9", c.delete("/posts/5/comments/9").body
end

test "custom get route and Cybertrain.url_root" do
  assert_equal "about / http://localhost:3000/about", client.get("/about").body
  Cybertrain.url_root = "https://blog.example"
  assert_equal "about / https://blog.example/about", client.get("/about").body
  Cybertrain.url_root = "http://localhost:3000"
end

test "a scope's routes and a singular resource's block route dispatch" do
  c = client
  assert_equal "about / http://localhost:3000/about", c.get("/v1/about").body
  assert_equal "refresh /v1/about", c.get("/profile/refresh").body
  assert_equal "profile /profile /profile/refresh", c.get("/profile").body
  assert_equal "/v1/about", Gen::Routes.path_for("v1_about_path", [])
  assert_equal "/profile/refresh", Gen::Routes.path_for("refresh_profile_path", [])
end

test "a redirect route and a route drawn with format: false" do
  c = client
  res = c.get("/old-posts/a%20b")
  assert_equal 301, res.status
  assert_equal "/posts/a%20b", res.header("Location")
  assert_equal "", res.body
  assert_equal "file report.v2 html", c.get("/files/report.v2").body
  assert_equal "file report.json html", c.get("/files/report.json").body
  assert_equal "show 3 /posts/3/edit /posts/3/comments /posts/3/preview", c.get("/posts/3.json").body
end

test "unknown paths are 404" do
  assert_response client.get("/nope"), :not_found
  assert_response client.get("/posts/5/comments"), :not_found
end

test "path_for resolves helpers by name" do
  assert_equal "/posts/7", Gen::Routes.path_for("post_path", ["7"])
  assert_equal "/posts/1/comments/2", Gen::Routes.path_for("post_comment_path", ["1", "2"])
  assert_equal "/posts", Gen::Routes.path_for("posts_path", [])
  assert_equal "http://localhost:3000/posts/a%20b/edit", Gen::Routes.path_for("edit_post_url", ["a b"])
  assert_equal "unknown route helper 'nope_path'", assert_raises("ArgumentError") { Gen::Routes.path_for("nope_path", []) }
  assert_equal "missing route parameter", assert_raises("ArgumentError") { Gen::Routes.path_for("post_path", []) }
end

# The generated helpers, called the way a controller calls them (plan
# decisions 13 and 14, spec 2.6).
class HelperProbe
  include ::Gen::UrlHelpers
end
H = HelperProbe.new

test "unused keywords become the query string, in order, escaped" do
  assert_equal "/posts/3?page=2", H.post_path(3, page: 2)
  assert_equal "/posts?q=a+b&sort=new", H.posts_path(q: "a b", sort: :new)
  assert_equal "/posts", H.posts_path(q: nil)
  assert_equal "/posts?tag%5B%5D=a&tag%5B%5D=b", H.posts_path(tag: ["a", "b"])
  assert_equal "/posts/1/comments/2?x=1", H.post_comment_path(1, 2, x: 1)
  assert_equal "http://localhost:3000/posts/3?page=2", H.post_url(3, page: 2)
  assert_equal "/posts/3", H.post_path(3)
end

test "format: and anchor:" do
  assert_equal "/posts/3.json", H.post_path(3, format: :json)
  assert_equal "/posts/3.json?page=2#comments", H.post_path(3, page: 2, format: "json", anchor: "comments")
  assert_equal "/?a=1#top", H.root_path(anchor: "top", a: 1)
  assert_equal "http://localhost:3000/posts.csv", H.posts_url(format: :csv)
end

test "a Hash value is refused" do
  msg = assert_raises("ArgumentError") { H.posts_path(q: { "a" => "b" }) }
  assert_equal "path helper option :q must be a String, Symbol, number, boolean or Array (got Hash)", msg
end

test "path_for takes the template's keywords" do
  assert_equal "/posts/7.json?page=2#c", Gen::Routes.path_for("post_path", ["7"], { "page" => 2, "format" => "json", "anchor" => "c" })
  assert_equal "http://localhost:3000/posts?q=a+b", Gen::Routes.path_for("posts_url", [], { "q" => "a b" })
  assert_equal "/posts/7?page=3", Gen::Routes.url_resolver.call("post_path", ["7"], { "page" => 3 })
end

test "the router knows the route names" do
  router = Gen::Routes.build(Cybertrain::Router.new)
  assert_equal 25, router.routes.size
  assert_equal "/posts/3/edit", router.path_for("edit_post", { "id" => "3" })
end

test "gen/app.rb loads the generated models next to the controllers" do
  post = Post.new
  post.title = "Hello"
  assert_equal "Hel", post.summary
  assert_equal "Comment", Comment.new.class.name
end

test "view_assigns exposes the scanned ivars" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/posts", {}, ""))
  assert_equal ["viewer", "posts", "post"], PostsController.new(ctx).view_assigns.keys
  assert_equal ["viewer"], PagesController.new(ctx).view_assigns.keys
end

# gen/helpers.rb and gen/components.rb, loaded by gen/app.rb, installed
# the app's builders; templates reach the fixture's PricesHelper and
# CardComponent through them.
Cybertrain::Views.configure("#{FIXTURE}/app/views", cache: false)

def render_inline(src)
  template = Cybertrain::Template::Template.parse(src, "posts/inline")
  env = { "__template_dir" => "posts" }
  env["post"] = Post.new
  Cybertrain::Template::Interpreter.new(Cybertrain::Views.helpers_builder.call(nil)).render(template, env)
end

test "the generated ApplicationHelpers dispatches to the fixture's helpers" do
  Cybertrain::Views.url_resolver = Gen::Routes.url_resolver
  assert_equal "/posts/0?page=2|/x.csv|/posts/0#c", render_inline("<%= post_path(post, page: 2) %>|<%= url_for('/x', format: :csv) %>|<%= url_for(post, anchor: 'c') %>")
  assert_equal "3.14 USD|3.1 EUR", render_inline("<%= price 3.14159 %>|<%= price 3.14159, unit: 'EUR', precision: 1 %>")
  # The block arrives as a SafeString; interpolated into a plain String it
  # is text again, and link_to_path escapes it.
  assert_equal "<a href=\"/posts/0\" class=\"badge\">warn: &lt;b&gt;x&lt;/b&gt;</a>", render_inline("<%= post_badge post, 'warn' do %><b>x</b><% end %>")
  # No block: block_given? is false in the helper.
  assert_equal "<a href=\"/posts/0\" class=\"badge\">info: -</a>", render_inline("<%= post_badge post %>")
end

test "the generated Gen::Components builds and renders the fixture's component" do
  assert_equal "<div class=\"card\"><h3>T</h3><p>2 pts</p></div>\n", render_inline("<%= render component: \"card\", title: \"T\", value: 2 %>")
  assert_equal "<div class=\"card\"><h3>x</h3><p>0 pts</p><i>c</i></div>\n", Cybertrain::Views.render_component(CardComponent.new(title: "x"), "<i>c</i>")
end

test "the generated Gen::Console tables" do
  assert_equal "SELECT * FROM `posts`", Gen::Console.scope("Post").to_sql
  assert_equal ["Comment", "Post"], Gen::Console::MODEL_NAMES
  msg = ""
  begin
    Gen::Console.scope("Nope")
  rescue Cybertrain::Console::UnknownModel => e
    msg = e.message
  end
  assert_equal "no model \"Nope\" (models: Comment, Post)", msg
end

Cybertrain::Test.run!
