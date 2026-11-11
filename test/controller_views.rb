require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/flash"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Controllers render test/fixtures/views/posts/*.html.erb inside
# layouts/application.html.erb. view_assigns is hand-written in the shape
# gen/controllers.rb emits.

class Post < Cybertrain::Model
  def initialize(id, title)
    super()
    set_id(id)
    mark_persisted! if id > 0
    @title = title
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
    when :comments then ["a", "b"]
    else nil
    end
  end
end

class PostsController < Cybertrain::Controller
  def index
    @posts = [Post.new(1, "One"), Post.new(2, "Two & more")]
  end

  def show
    @post = Post.new(7, "Hello <World>")
  end

  def new_action
    @post = Post.new(0, "Draft")
    render :new, status: :unprocessable_entity
  end

  def form
    render partial: "form", locals: { post: Post.new(3, "Partial") }
  end

  def bare
    @post = Post.new(7, "Bare")
    render :show, layout: false
  end

  def other
    @post = Post.new(7, "Assigned")
    render :show, locals: { post: Post.new(8, "Local") }
  end

  def missing
  end

  # What gen/controllers.rb emits for this class.
  def view_assigns
    { "posts" => @posts, "post" => @post }
  end
end

# Per-controller layouts (V-9), each controller_layout written in the shape
# gen/controllers.rb emits for its `layout` line; their templates are
# PostsController's.

# layout "frame"
class FramedController < PostsController
  def controller_path = "posts"

  def controller_layout(layout_action__)
    "layouts/frame"
  end
end

# layout :pick
class PickedController < PostsController
  def controller_path = "posts"

  def bare_show
    @post = Post.new(7, "Picked")
    render :show
  end

  def pick
    return false if action_name == "bare_show"
    return nil if action_name == "index"
    "frame"
  end

  def controller_layout(layout_action__)
    layout_chosen__ = pick
    return super if layout_chosen__.nil?
    layout_chosen__ == false ? "" : Cybertrain::Controller.layout_path(layout_chosen__.to_s)
  end
end

# layout "admin", only: [:index]
class AdminPostsController < PostsController
  def controller_path = "posts"

  def framed_show
    @post = Post.new(7, "Per call")
    render :show, layout: "frame"
  end

  def bare_show
    @post = Post.new(7, "Bare")
    render :show, layout: false
  end

  def prefixed_show
    @post = Post.new(7, "Prefixed")
    render :show, layout: "layouts/frame"
  end

  def typo_show
    @post = Post.new(7, "Typo")
    render :show, layout: "fram"
  end

  def controller_layout(layout_action__)
    if layout_action__ == "index"
      return "layouts/admin"
    end
    super
  end
end

# layout "admn" (a typo)
class MisnamedController < PostsController
  def controller_path = "posts"

  def controller_layout(layout_action__)
    "layouts/admn"
  end
end

# layout :frame_or_application
class TurboPostsController < PostsController
  def controller_path = "posts"

  def frame_or_application
    return "frame" if request.header("Turbo-Frame")
    "application"
  end

  def controller_layout(layout_action__)
    layout_chosen__ = frame_or_application
    return super if layout_chosen__.nil?
    layout_chosen__ == false ? "" : Cybertrain::Controller.layout_path(layout_chosen__.to_s)
  end
end

Cybertrain::Views.configure("test/fixtures/views", cache: true)
Cybertrain::Views.url_resolver = lambda do |name, args, options|
  case name
  when "edit_post_path"
    id = ""
    case args[0]
    when Cybertrain::Model then id = args[0].to_param
    end
    "/posts/#{id}/edit"
  else raise "no route #{name}"
  end
end

def build_ctx(headers = { "host" => "example.test" })
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/posts/7", headers, ""))
  flash = Cybertrain::Flash.new
  flash.set_now("notice", "Post <saved>")
  ctx.flash = flash
  ctx
end

# Plays the part of gen/routes.rb: literal action names, literal bodies.
def dispatch(action)
  c = PostsController.new(build_ctx)
  case action
  when :index then c.process(:index) { |x| x.index }
  when :show then c.process(:show) { |x| x.show }
  when :new then c.process(:new) { |x| x.new_action }
  when :form then c.process(:form) { |x| x.form }
  when :bare then c.process(:bare) { |x| x.bare }
  when :other then c.process(:other) { |x| x.other }
  when :missing then c.process(:missing) { |x| x.missing }
  else raise ArgumentError, "no route for #{action}"
  end
  c
end

SHOW_BODY = <<~HTML

  <p class="notice">Post &lt;saved&gt;</p>
  <h1>Hello &lt;World&gt;</h1>
  <a href="/posts/7/edit">Edit</a>
HTML

test "an action that renders nothing renders its template inside the layout" do
  c = dispatch(:show)
  expected = "<!DOCTYPE html>\n<html>\n<head><title>Post: Hello &lt;World&gt;</title></head>\n<body>\n#{SHOW_BODY}\n</body>\n</html>\n"
  assert_equal expected, c.response.body
  assert_equal 200, c.response.status
  assert_equal "text/html; charset=utf-8", c.response.header("Content-Type")
  assert c.performed?
end

test "view_assigns feed the template's instance variables" do
  body = dispatch(:index).response.body
  assert_includes body, "<li>One (2 comments)</li>"
  assert_includes body, "<li>Two &amp; more (2 comments)</li>"
  assert_includes body, "<head><title></title></head>"
end

test "render :new, status: :unprocessable_entity" do
  c = dispatch(:new)
  assert_equal 422, c.response.status
  assert_equal "new", c.action_name
  assert_includes c.response.body, "<h1>New post</h1>\n<form><input name=\"post[title]\" value=\"Draft\"></form>\n"
  assert_includes c.response.body, "<!DOCTYPE html>"
end

test "render partial: renders _form without the layout" do
  c = dispatch(:form)
  assert_equal "<form><input name=\"post[title]\" value=\"Partial\"></form>\n", c.response.body
  assert_equal "text/html; charset=utf-8", c.response.header("Content-Type")
end

test "render layout: false" do
  body = dispatch(:bare).response.body
  assert_equal "\n<p class=\"notice\">Post &lt;saved&gt;</p>\n<h1>Bare</h1>\n<a href=\"/posts/7/edit\">Edit</a>\n", body
end

test "render locals: override view_assigns" do
  body = dispatch(:other).response.body
  assert_includes body, "<h1>Local</h1>"
  assert_includes body, "<a href=\"/posts/8/edit\">Edit</a>"
end

test "a missing template propagates as Cybertrain::Template::MissingTemplate" do
  msg = assert_raises("Cybertrain::Template::MissingTemplate") { dispatch(:missing) }
  assert_equal "Missing template test/fixtures/views/posts/missing.html.erb", msg
end

test "no layout is applied when the layout file does not exist" do
  Cybertrain::Views.layout_name = "layouts/none"
  body = dispatch(:show).response.body
  Cybertrain::Views.layout_name = "layouts/application"
  assert_equal SHOW_BODY, body
  assert dispatch(:show).response.body.start_with?("<!DOCTYPE html>")
end

test "controller_path and view_env" do
  c = PostsController.new(build_ctx)
  assert_equal "posts", c.controller_path
  extra = {}
  extra["x"] = 1
  env = c.view_env(extra)
  assert_equal "posts", env["__template_dir"]
  assert_equal "posts", env["__controller_path"]
  assert_equal 1, env["x"]
  assert env.key?("post")
  assert_equal 0, Cybertrain::Controller.new(build_ctx).view_assigns.size
end

FRAMED_SHOW = "<div class=\"frame\">\n#{SHOW_BODY}</div>\n"

test "layout by name" do
  c = FramedController.new(build_ctx)
  c.process(:show) { |x| x.show }
  assert_equal FRAMED_SHOW, c.response.body
  assert_equal "layouts/frame", c.controller_layout("show")
  assert_equal "layouts/application", PostsController.new(build_ctx).controller_layout("show")
end

test "layout :method returning false renders bare, returning \"frame\" uses it" do
  bare = PickedController.new(build_ctx)
  bare.process(:bare_show) { |x| x.bare_show }
  assert_equal "\n<p class=\"notice\">Post &lt;saved&gt;</p>\n<h1>Picked</h1>\n<a href=\"/posts/7/edit\">Edit</a>\n", bare.response.body
  framed = PickedController.new(build_ctx)
  framed.process(:show) { |x| x.show }
  assert_equal FRAMED_SHOW, framed.response.body
end

test "layout :method returning nil uses the inherited layout" do
  c = PickedController.new(build_ctx)
  c.process(:index) { |x| x.index }
  assert c.response.body.start_with?("<!DOCTYPE html>\n"), c.response.body
  assert_equal "layouts/application", c.controller_layout("index")
end

test "layout \"admin\", only: [:index] applies to index only" do
  index = AdminPostsController.new(build_ctx)
  index.process(:index) { |x| x.index }
  assert index.response.body.start_with?("<main class=\"admin\">\n<h1>Posts</h1>"), index.response.body
  show = AdminPostsController.new(build_ctx)
  show.process(:show) { |x| x.show }
  assert show.response.body.start_with?("<!DOCTYPE html>"), show.response.body
end

test "render layout: \"frame\" per call wins; render layout: false is bare" do
  framed = AdminPostsController.new(build_ctx)
  framed.process(:index) { |x| x.framed_show }
  assert framed.response.body.start_with?("<div class=\"frame\">\n"), framed.response.body
  assert_includes framed.response.body, "<h1>Per call</h1>"
  bare = AdminPostsController.new(build_ctx)
  bare.process(:index) { |x| x.bare_show }
  assert_equal "\n<p class=\"notice\">Post &lt;saved&gt;</p>\n<h1>Bare</h1>\n<a href=\"/posts/7/edit\">Edit</a>\n", bare.response.body
  # layout: true (the default) is the controller's own layout.
  own = AdminPostsController.new(build_ctx)
  own.process(:index) { |x| x.new_action }
  assert own.response.body.start_with?("<main class=\"admin\">\n<h1>New post</h1>"), own.response.body
end

test "render layout: \"layouts/frame\" is not prefixed twice; a missing named layout raises" do
  assert_equal "layouts/frame", Cybertrain::Controller.layout_path("frame")
  assert_equal "layouts/frame", Cybertrain::Controller.layout_path("layouts/frame")
  prefixed = AdminPostsController.new(build_ctx)
  prefixed.process(:index) { |x| x.prefixed_show }
  assert prefixed.response.body.start_with?("<div class=\"frame\">\n"), prefixed.response.body
  msg = assert_raises("Cybertrain::MissingTemplate") { AdminPostsController.new(build_ctx).process(:index) { |x| x.typo_show } }
  assert_equal "missing layout layouts/fram for AdminPostsController", msg
end

test "a layout line naming a missing layout raises; the default layout stays optional" do
  msg = assert_raises("Cybertrain::MissingTemplate") { MisnamedController.new(build_ctx).process(:show) { |x| x.show } }
  assert_equal "missing layout layouts/admn for MisnamedController", msg
end

test "a Turbo-Frame request picks the frame layout through a two-line method" do
  framed = TurboPostsController.new(build_ctx({ "host" => "example.test", "turbo-frame" => "post_7" }))
  framed.process(:show) { |x| x.show }
  assert_equal FRAMED_SHOW, framed.response.body
  page = TurboPostsController.new(build_ctx)
  page.process(:show) { |x| x.show }
  assert page.response.body.start_with?("<!DOCTYPE html>"), page.response.body
end

Cybertrain::Test.run!
