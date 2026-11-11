require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/router"
require "cybertrain/app"
require "cybertrain/test/client"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
#
# turbo_frame_tag, the template's turbo_stream builder, and the
# controller's turbo_stream with `render turbo_stream:`. Templates are
# test/fixtures/views/turbo/**; the controller and its route are
# hand-written in the shape gen/controllers.rb and gen/routes.rb emit.

class Article < Cybertrain::Model
  def initialize(id, title)
    super()
    set_id(id)
    mark_persisted! if id > 0
    @title = title
  end

  def model_name = "Article"

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    else nil
    end
  end

  def title = @title
end

Cybertrain::Views.configure("test/fixtures/views/turbo", cache: true)

def render_inline(src)
  template = Cybertrain::Template::Template.parse(src, "articles/inline")
  env = { "__template_dir" => [nil, 0, 0.0, "", true][3] }
  env["__template_dir"] = "articles"
  env["article"] = Article.new(3, "T & U")
  Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil)).render(template, env)
end

def render_error(src)
  msg = ""
  begin
    render_inline(src)
  rescue StandardError => e
    msg = e.message
  end
  msg
end

test "turbo_frame_tag with a record and options" do
  html = render_inline("<%= turbo_frame_tag article, src: \"/x?a=1&b=2\", loading: \"lazy\", target: \"_top\" do %><b>in</b><% end %>")
  assert_equal "<turbo-frame id=\"article_3\" src=\"/x?a=1&amp;b=2\" loading=\"lazy\" target=\"_top\"><b>in</b></turbo-frame>", html
  # A String id, no options: no attributes but the id, and no block.
  assert_equal "<turbo-frame id=\"tray\"></turbo-frame>", render_inline("<%= turbo_frame_tag \"tray\" %>")
  # Attributes are escaped once: a SafeString goes in as it is.
  assert_equal "<turbo-frame id=\"a&quot;b\" src=\"&amp;\"></turbo-frame>", render_inline("<%= turbo_frame_tag \"a\\\"b\", src: raw(\"&amp;\") %>")
  # class: and data: as on any tag.
  assert_equal "<turbo-frame id=\"t\" class=\"c\" data-turbo-action=\"advance\"></turbo-frame>",
               render_inline("<%= turbo_frame_tag \"t\", class: \"c\", data: { turbo_action: \"advance\" } %>")
  assert_equal "articles/inline:1: unknown keyword 'lazy' for 'turbo_frame_tag' (known: src, loading, target, class, data)",
               render_error("<%= turbo_frame_tag \"t\", lazy: true %>")
  assert_equal "articles/inline:1: wrong number of arguments for 'turbo_frame_tag' (given 0, expected 1)", render_error("<%= turbo_frame_tag %>")
end

test "turbo_stream.replace with partial and locals, append with html:, remove(target)" do
  html = render_inline("<%= turbo_stream.replace article, partial: \"article\", locals: { article: article } %>")
  assert_equal "<turbo-stream action=\"replace\" target=\"article_3\"><template><p>T &amp; U</p></template></turbo-stream>", html
  html = render_inline("<%= turbo_stream.update \"articles/article\", partial: \"articles/article\", locals: { article: article } %>")
  assert_equal "<turbo-stream action=\"update\" target=\"articles/article\"><template><p>T &amp; U</p></template></turbo-stream>", html
  assert_equal "<turbo-stream action=\"append\" target=\"list\"><template>&lt;b&gt;</template></turbo-stream>",
               render_inline("<%= turbo_stream.append \"list\", html: \"<b>\" %>")
  assert_equal "<turbo-stream action=\"prepend\" target=\"list\"><template><b></template></turbo-stream>",
               render_inline("<%= turbo_stream.prepend \"list\", html: raw(\"<b>\") %>")
  assert_equal "<turbo-stream action=\"remove\" target=\"comment_7\"></turbo-stream>", render_inline("<%= turbo_stream.remove \"comment_7\" %>")
  assert_equal "<turbo-stream action=\"remove\" target=\"article_3\"></turbo-stream>", render_inline("<%= turbo_stream.remove article %>")
  # A block is the content, rendered at once.
  assert_equal "<turbo-stream action=\"before\" target=\"x\"><template><i>T &amp; U</i></template></turbo-stream>",
               render_inline("<%= turbo_stream.before \"x\" do %><i><%= article.title %></i><% end %>")
  assert_equal "<turbo-stream action=\"after\" target=\"x\"><template></template></turbo-stream>",
               render_inline("<%= turbo_stream.after \"x\", html: \"\" %>")
  # The target is escaped once.
  assert_equal "<turbo-stream action=\"remove\" target=\"a&lt;b\"></turbo-stream>", render_inline("<%= turbo_stream.remove \"a<b\" %>")
end

test "turbo_stream refuses a missing or doubled content, and unknown actions" do
  assert_equal "articles/inline:1: turbo_stream.replace needs exactly one of a block, partial:, html:",
               render_error("<%= turbo_stream.replace \"x\" %>")
  assert_equal "articles/inline:1: turbo_stream.replace needs exactly one of a block, partial:, html:",
               render_error("<%= turbo_stream.replace \"x\", html: \"a\", partial: \"article\" %>")
  assert_equal "articles/inline:1: turbo_stream.append needs exactly one of a block, partial:, html:",
               render_error("<%= turbo_stream.append \"x\", html: \"a\" do %>b<% end %>")
  assert_equal "articles/inline:1: unknown keyword 'htm' for 'turbo_stream.update' (known: partial, locals, html)",
               render_error("<%= turbo_stream.update \"x\", htm: \"a\" %>")
  assert_equal "articles/inline:1: 'turbo_stream.remove' takes no keyword arguments (given html)",
               render_error("<%= turbo_stream.remove \"x\", html: \"a\" %>")
  assert_equal "articles/inline:1: wrong number of arguments for 'turbo_stream.remove' (given 0, expected 1)",
               render_error("<%= turbo_stream.remove %>")
  assert_equal "articles/inline:1: undefined method 'morph' for turbo_stream", render_error("<%= turbo_stream.morph \"x\" %>")
  assert_equal "", render_inline("<%= turbo_stream %>")
end

class ArticlesController < Cybertrain::Controller
  def show
    @article = Article.new(3, "T & U")
    render turbo_stream: [
      turbo_stream.replace(@article, partial: "article", locals: { article: @article }),
      turbo_stream.update("count", html: "<2>"),
      turbo_stream.remove("comment_7")
    ]
  end

  def one
    render turbo_stream: turbo_stream.append("list", partial: "articles/article", locals: { article: Article.new(4, "Four") }), status: :created
  end

  def plain
    render turbo_stream: "<turbo-stream></turbo-stream>"
  end

  def bad_locals
    render turbo_stream: turbo_stream.prepend("list", partial: "article", locals: {})
  end

  def neither
    render turbo_stream: turbo_stream.before("list")
  end

  def view_assigns
    { "article" => @article }
  end
end

def build_app
  router = Cybertrain::Router.new
  router.add("GET", "/articles/one", "") { |ctx| ArticlesController.new(ctx).process(:one) { |c| c.one } }
  router.add("GET", "/articles/plain", "") { |ctx| ArticlesController.new(ctx).process(:plain) { |c| c.plain } }
  router.add("GET", "/articles/bad_locals", "") { |ctx| ArticlesController.new(ctx).process(:bad_locals) { |c| c.bad_locals } }
  router.add("GET", "/articles/neither", "") { |ctx| ArticlesController.new(ctx).process(:neither) { |c| c.neither } }
  router.add("GET", "/articles/:id", "") { |ctx| ArticlesController.new(ctx).process(:show) { |c| c.show } }
  Cybertrain::App.new(router, public_root: "test/no_such_public_dir", logging: false)
end

client = Cybertrain::Test::Client.new(build_app)

test "render turbo_stream: [..] in a controller sets the content type" do
  res = client.get("/articles/3")
  assert_equal 200, res.status
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", res.header("content-type")
  assert_equal "<turbo-stream action=\"replace\" target=\"article_3\"><template><p>T &amp; U</p></template></turbo-stream>" \
               "<turbo-stream action=\"update\" target=\"count\"><template>&lt;2&gt;</template></turbo-stream>" \
               "<turbo-stream action=\"remove\" target=\"comment_7\"></turbo-stream>", res.body
  one = client.get("/articles/one")
  assert_equal 201, one.status
  assert_equal "text/vnd.turbo-stream.html; charset=utf-8", one.header("content-type")
  assert_equal "<turbo-stream action=\"append\" target=\"list\"><template><p>Four</p></template></turbo-stream>", one.body
end

def controller
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/articles/x", { "host" => "example.test" }, ""))
  ArticlesController.new(ctx)
end

test "render turbo_stream: refuses a plain String; the controller builder checks its partial and content" do
  msg = ""
  begin
    controller.plain
  rescue ArgumentError => e
    msg = e.message
  end
  assert_equal "render turbo_stream: takes a SafeString or an Array of them (turbo_stream.replace and the others build them), got String", msg
  msg = ""
  begin
    controller.bad_locals
  rescue ArgumentError => e
    msg = e.message
  end
  assert_equal "missing local 'article' for articles/_article.html.erb", msg
  msg = ""
  begin
    controller.neither
  rescue ArgumentError => e
    msg = e.message
  end
  assert_equal "turbo_stream.before needs exactly one of partial:, html:", msg
end

test "a turbo_stream response carries the headers every response does" do
  c = controller
  c.show
  wire = c.response.to_http.downcase
  assert_includes wire, "content-type: text/vnd.turbo-stream.html; charset=utf-8\r\n"
  assert_includes wire, "permissions-policy: camera=(), microphone=(), geolocation=()\r\n"
  assert_includes wire, "x-content-type-options: nosniff\r\n"
end

Cybertrain::Test.run!
