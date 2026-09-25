require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/session"
require "cybertrain/flash"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
#
# Templates are rendered inline through Cybertrain::Template::Helpers; the
# url_resolver is a stub lambda standing in for Gen::Routes.path_for that
# records every call it receives.

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
end

Views = Cybertrain::Views
Views.configure("test/fixtures/views", cache: true)

ROUTE_CALLS = []

def route_param(v)
  case v
  when Cybertrain::Model then v.to_param
  else v.to_s
  end
end

def install_routes
  Views.url_resolver = lambda do |name, args|
    ROUTE_CALLS << "#{name}(#{args.map { |a| route_param(a) }.join(", ")})"
    case name
    when "posts_path" then "/posts"
    when "new_post_path" then "/posts/new"
    when "post_path" then "/posts/#{route_param(args[0])}"
    when "edit_post_path" then "/posts/#{route_param(args[0])}/edit"
    when "post_url" then "http://example.test/posts/#{route_param(args[0])}"
    else raise "no route #{name}"
    end
  end
  ROUTE_CALLS.clear
  nil
end

# A controller whose session already holds a CSRF token, so the token the
# helpers print is deterministic.
def controller_with_session
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/posts/7?x=1", { "host" => "example.test" }, ""))
  ctx.session = Cybertrain::Session.new({ "_csrf_token" => "tok<en>" })
  flash = Cybertrain::Flash.new
  flash.set_now("notice", "Saved!")
  ctx.flash = flash
  ctx.params.set_value("q", "ruby")
  Cybertrain::Controller.new(ctx)
end

def new_env
  env = {}
  env["__template_dir"] = "posts"
  env["post"] = Post.new(7, "Hello <World>")
  env["n"] = 1234567
  env
end

def render_with(helpers, src, env = new_env)
  template = Cybertrain::Template::Template.parse(src, "posts/inline")
  Cybertrain::Template::Interpreter.new(helpers).render(template, env)
end

def render_inline(src, env = new_env)
  render_with(Cybertrain::Template::Helpers.new(nil), src, env)
end

test "path helpers raise until the app installs a url_resolver" do
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= posts_path %>") }
  assert_equal "posts/inline:1: no routes", msg
end

test "h and raw" do
  assert_equal "&lt;b&gt;|<b>", render_inline("<%= h '<b>' %>|<%= raw '<b>' %>")
  assert_equal "&lt;i&gt;", render_inline("<%= escape '<i>' %>")
  # A SafeString is already HTML: h/escape pass it through, as in Rails.
  assert_equal "<b>|<i>", render_inline("<%= h raw('<b>') %>|<%= escape raw('<i>') %>")
  assert_equal "&lt;b&gt;", render_inline("<%= h h('<b>') %>")
end

test "link_to escapes its text and its href" do
  install_routes
  assert_equal "<a href=\"/x?a=1&amp;b=&quot;2&quot;\">Tom &amp; &lt;Jerry&gt;</a>", render_inline("<%= link_to 'Tom & <Jerry>', '/x?a=1&b=\"2\"' %>")
  assert_equal "<a href=\"/posts/7\" class=\"btn\">Hello &lt;World&gt;</a>", render_inline("<%= link_to post.title, post_path(post), class: 'btn' %>")
  assert_equal "<a href=\"/posts/7\"><b>raw</b></a>", render_inline("<%= link_to raw('<b>raw</b>'), post %>")
  assert_equal "<a href=\"/posts\" data-confirm=\"Sure?\">All</a>", render_inline("<%= link_to 'All', posts_path, data_confirm: 'Sure?' %>")
  assert_equal "<a href=\"/posts\" data-turbo-confirm=\"Really?\">All</a>", render_inline("<%= link_to 'All', posts_path, data: { turbo_confirm: 'Really?' } %>")
  msg = assert_raises("RuntimeError") { render_inline("<%= link_to 'Destroy', post, method: :delete %>") }
  assert_equal "posts/inline:1: link_to does not support method: (use button_to 'Destroy', path, method: :delete)", msg
end

test "button_to emits the hidden _method and the authenticity token" do
  install_routes
  helpers = Cybertrain::Template::Helpers.new(controller_with_session)
  html = render_with(helpers, "<%= button_to 'Destroy', post_path(post), method: :delete %>")
  assert_equal "<form class=\"button_to\" method=\"post\" action=\"/posts/7\"><input type=\"hidden\" name=\"_method\" value=\"delete\"><input type=\"hidden\" name=\"authenticity_token\" value=\"tok&lt;en&gt;\"><button type=\"submit\">Destroy</button></form>", html
  html = render_with(helpers, "<%= button_to 'Go', '/go' %>")
  assert_equal "<form class=\"button_to\" method=\"post\" action=\"/go\"><input type=\"hidden\" name=\"authenticity_token\" value=\"tok&lt;en&gt;\"><button type=\"submit\">Go</button></form>", html
  html = render_with(helpers, "<%= button_to 'Find', '/search', method: :get, class: 'b' %>")
  assert_equal "<form class=\"button_to\" method=\"get\" action=\"/search\"><button class=\"b\" type=\"submit\">Find</button></form>", html
  # Without a session (no SessionStore) there is no token to print.
  assert_equal "<form class=\"button_to\" method=\"post\" action=\"/go\"><button type=\"submit\">Go</button></form>", render_inline("<%= button_to 'Go', '/go' %>")
end

test "csrf_meta_tags and csrf_token read the session token" do
  helpers = Cybertrain::Template::Helpers.new(controller_with_session)
  assert_equal "<meta name=\"csrf-param\" content=\"authenticity_token\">\n<meta name=\"csrf-token\" content=\"tok&lt;en&gt;\">", render_with(helpers, "<%= csrf_meta_tags %>")
  assert_equal "tok&lt;en&gt;", render_with(helpers, "<%= csrf_token %>")
  assert_equal "", render_inline("<%= csrf_meta_tags %>")
end

test "flash, params and request_path come from the controller" do
  helpers = Cybertrain::Template::Helpers.new(controller_with_session)
  assert_equal "Saved!|ruby|/posts/7", render_with(helpers, "<%= flash[:notice] %>|<%= params[:q] %>|<%= request_path %>")
  assert_equal "none", render_inline("<% if flash[:notice] %>notice<% else %>none<% end %>")
end

test "pluralize picks singular or plural" do
  assert_equal "1 comment|2 comments|0 comments", render_inline("<%= pluralize(1, 'comment') %>|<%= pluralize(2, 'comment') %>|<%= pluralize(0, 'comment') %>")
  assert_equal "3 people|1 person|2 mice", render_inline("<%= pluralize(3, 'person') %>|<%= pluralize(1, 'person') %>|<%= pluralize(2, 'mouse', 'mice') %>")
end

test "truncate shortens long text with an ellipsis" do
  long = "a" * 40
  env = new_env
  env["long"] = long
  assert_equal "#{"a" * 27}...", render_inline("<%= truncate(long) %>", env)
  assert_equal "Hello...", render_inline("<%= truncate('Hello world', length: 8) %>")
  assert_equal "short", render_inline("<%= truncate('short', length: 8) %>")
  assert_equal "Hello world", render_inline("<%= truncate('Hello world', length: 11) %>")
  assert_equal "Hel~", render_inline("<%= truncate('Hello world', length: 4, omission: '~') %>")
end

test "number_with_delimiter groups thousands" do
  assert_equal "1,234,567|999|-1,000|1,234.5", render_inline("<%= number_with_delimiter(n) %>|<%= number_with_delimiter(999) %>|<%= number_with_delimiter(-1000) %>|<%= number_with_delimiter(1234.5) %>")
end

test "time_ago_in_words buckets" do
  h = Cybertrain::Template::Helpers.new(nil)
  now = Time.at(1_700_000_000)
  # Parallel Arrays rather than pairs: a mixed [Integer, String] pair is a
  # polymorphic Array, and Time - (polymorphic value) raises under Spinel.
  seconds = [0, 29, 45, 150, 44 * 60, 50 * 60, 5 * 3600, 30 * 3600, 3 * 86_400,
             35 * 86_400, 100 * 86_400, 400 * 86_400, 500 * 86_400, 700 * 86_400, 3 * 365 * 86_400]
  words = ["less than a minute", "less than a minute", "1 minute", "3 minutes", "44 minutes",
           "about 1 hour", "about 5 hours", "1 day", "3 days", "about 1 month", "3 months",
           "about 1 year", "over 1 year", "almost 2 years", "about 3 years"]
  seconds.each_with_index do |s, i|
    assert_equal words[i], h.distance_of_time_in_words(now - s, now)
  end
  env = new_env
  env["t"] = Time.now - 3 * 3600
  assert_equal "about 3 hours", render_inline("<%= time_ago_in_words(t) %>", env)
end

test "render a partial with strict locals" do
  html = render_inline("[<%= render 'form', post: post %>]")
  assert_equal "[<form><input name=\"post[title]\" value=\"Hello &lt;World&gt;\"></form>\n]", html
  html = render_inline("<%= render partial: 'form', locals: { post: post } %>")
  assert_equal "<form><input name=\"post[title]\" value=\"Hello &lt;World&gt;\"></form>\n", html
  html = render_inline("<%= render 'posts/form', post: post %>")
  assert_equal "<form><input name=\"post[title]\" value=\"Hello &lt;World&gt;\"></form>\n", html
  msg = assert_raises("RuntimeError") { render_inline("\n<%= render 'form' %>") }
  assert_equal "posts/inline:2: missing local 'post' for posts/_form.html.erb", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= render 'form', post: post, extra: 1 %>") }
  assert_equal "posts/inline:1: unknown local 'extra' for posts/_form.html.erb", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= render 'nope' %>") }
  assert_equal "posts/inline:1: Missing template test/fixtures/views/posts/_nope.html.erb", msg
end

test "content_for and yield :title" do
  env = new_env
  html = render_inline("<% content_for :title do %>Post <%= post.title %><% end %>body", env)
  assert_equal "body", html
  assert_equal "Post Hello &lt;World&gt;", env["__content_title"].to_s
  assert_equal "<t>Post Hello &lt;World&gt;</t>", render_inline("<t><%= yield :title %></t>", env)
  render_inline("<% content_for :title, ' & more' %>", env)
  assert_equal "Post Hello &lt;World&gt; &amp; more", env["__content_title"].to_s
  assert_equal "yes|no", render_inline("<%= content_for?(:title) ? 'yes' : 'no' %>|<%= content_for?(:side) ? 'yes' : 'no' %>", env)
end

test "url helpers go through the url_resolver with name and args" do
  install_routes
  html = render_inline("<%= post_path(post) %> <%= edit_post_path(post) %> <%= posts_path %> <%= post_url(post) %>")
  assert_equal "/posts/7 /posts/7/edit /posts http://example.test/posts/7", html
  assert_equal ["post_path(7)", "edit_post_path(7)", "posts_path()", "post_url(7)"], ROUTE_CALLS
end

test "url_for derives the route name from the model" do
  install_routes
  assert_equal "/posts/7|/x", render_inline("<%= url_for(post) %>|<%= url_for('/x') %>")
  assert_equal ["post_path(7)"], ROUTE_CALLS
end

test "an unknown helper is a RuntimeError" do
  msg = assert_raises("RuntimeError") { render_inline("<%= frobnicate 1 %>") }
  assert_equal "posts/inline:1: undefined helper 'frobnicate'", msg
end

Cybertrain::Test.run!
