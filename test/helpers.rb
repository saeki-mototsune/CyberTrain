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
  Views.url_resolver = lambda do |name, args, options|
    ROUTE_CALLS << "#{name}(#{args.map { |a| route_param(a) }.join(", ")})"
    path = case name
           when "posts_path" then "/posts"
           when "new_post_path" then "/posts/new"
           when "post_path" then "/posts/#{route_param(args[0])}"
           when "edit_post_path" then "/posts/#{route_param(args[0])}/edit"
           when "post_url" then "http://example.test/posts/#{route_param(args[0])}"
           else raise "no route #{name}"
           end
    Cybertrain::Gen.with_options(path, options)
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

test "link_to and button_to check data: keys; a SafeString attribute is escaped once" do
  install_routes
  env = new_env
  env["bad"] = { "x\" onclick=\"a" => 1 }
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= link_to 'All', '/a', data: bad %>", env) }
  assert_equal "posts/inline:1: invalid attribute name 'data-x\" onclick=\"a'", msg
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= button_to 'Go', '/go', data: bad %>", env) }
  assert_equal "posts/inline:1: invalid attribute name 'data-x\" onclick=\"a'", msg
  assert_equal "<a href=\"/a\" class=\"a&amp;b\" data-x=\"&amp;\" data-y=\"&lt;\">All</a>",
               render_inline("<%= link_to 'All', '/a', class: raw('a&amp;b'), data: { x: raw('&amp;'), y: '<', z: nil } %>")
  assert_equal "<form class=\"button_to\" method=\"get\" action=\"/go\"><button class=\"a&amp;b\" data-turbo=\"false\" type=\"submit\">Go</button></form>",
               render_inline("<%= button_to 'Go', '/go', method: :get, class: raw('a&amp;b'), data: { turbo: false } %>")
  assert_equal "<img src=\"/x.png\" alt=\"A &amp; B\" class=\"a&amp;b\">", render_inline("<%= image_tag '/x.png', alt: raw('A &amp; B'), class: raw('a&amp;b') %>")
  assert_equal "<img src=\"/x.png\" alt=\"A &amp; B\">", render_inline("<%= image_tag '/x.png', alt: 'A & B' %>")
  assert_equal "<link rel=\"stylesheet\" href=\"/x.css\" media=\"a&amp;b\">", render_inline("<%= stylesheet_link_tag '/x.css', media: raw('a&amp;b') %>")
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

test "number helpers from a template" do
  assert_equal "12.345.678|98 765 432,98", render_inline("<%= number_with_delimiter(12345678, delimiter: '.') %>|<%= number_with_delimiter(98765432.98, delimiter: ' ', separator: ',') %>")
  assert_equal "111.235|111.23|13|1.111,23", render_inline("<%= number_with_precision(111.2345) %>|<%= number_with_precision(111.2345, precision: 2) %>|<%= number_with_precision(13, precision: 5, strip_insignificant_zeros: true) %>|<%= number_with_precision(1111.2345, precision: 2, separator: ',', delimiter: '.') %>")
  assert_equal "1.23 Thousand|490 Thousand|500 lt", render_inline("<%= number_to_human(1234) %>|<%= number_to_human(489939, precision: 2) %>|<%= number_to_human(500000, units: { unit: 'ml', thousand: 'lt' }) %>")
  assert_equal "100.000%|100%", render_inline("<%= number_to_percentage(100) %>|<%= number_to_percentage(100, precision: 0) %>")
  assert_equal "$1,234,567,890.51|-$1,234,567,890.50|1,234,567,890.50 €", render_inline("<%= number_to_currency(1234567890.506) %>|<%= number_to_currency(-1234567890.50) %>|<%= number_to_currency(1234567890.50, unit: '€', format: '%n %u') %>")
  assert_equal "1 Byte|1.21 KB|1.07 EB", render_inline("<%= number_to_human_size(1) %>|<%= number_to_human_size(1234) %>|<%= number_to_human_size(1234567890123456789) %>")
end

test "number helpers render nil as an empty string" do
  # A nullable column prints nothing, as in Rails and 0.4; NumberHelper
  # itself still raises for nil (test/number_helper.rb).
  assert_equal "||||||", render_inline("<%= number_with_delimiter nil %>|<%= number_with_precision(nil, precision: 2) %>|<%= number_to_human(nil) %>|<%= number_to_percentage(nil) %>|<%= number_to_currency(nil) %>|<%= number_to_human_size(nil) %>|")
  # Keywords are still checked, and a non-number that is not nil raises.
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= number_to_currency(nil, scale: 2) %>") }
  assert_equal "posts/inline:1: unknown keyword 'scale' for 'number_to_currency' (known: unit, precision, format)", msg
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= number_with_delimiter('') %>") }
  assert_equal "posts/inline:1: number_with_delimiter: \"\" is not a number", msg
end

test "number helpers check their arguments" do
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= number_to_currency('abc') %>") }
  assert_equal "posts/inline:1: number_to_currency: \"abc\" is not a number", msg
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= number_to_percentage(1, scale: 2) %>") }
  assert_equal "posts/inline:1: unknown keyword 'scale' for 'number_to_percentage' (known: precision)", msg
  msg = assert_raises("Cybertrain::Template::RuntimeError") { render_inline("<%= number_to_human_size(1, precision: 2) %>") }
  assert_equal "posts/inline:1: 'number_to_human_size' takes no keyword arguments (given precision)", msg
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

test "a path helper's keywords reach the url_resolver as its options" do
  install_routes
  assert_equal "/posts/7?page=2", render_inline("<%= post_path(post, page: 2) %>")
  assert_equal "/posts.json?q=a+b#top", render_inline("<%= posts_path(q: 'a b', format: :json, anchor: 'top') %>")
  assert_equal ["post_path(7)", "posts_path()"], ROUTE_CALLS
end

test "url_for appends format:, a query and anchor: to a String or a record's route" do
  install_routes
  assert_equal "/x.csv", render_inline("<%= url_for('/x', format: :csv) %>")
  assert_equal "/x?a=1#b", render_inline("<%= url_for('/x', a: 1, anchor: 'b') %>")
  assert_equal "/posts/7.json", render_inline("<%= url_for(post, format: :json) %>")
  assert_equal "/x", render_inline("<%= url_for('/x') %>")
end

test "url_for refuses options on a String that already has a query" do
  install_routes
  msg = assert_raises("RuntimeError") { render_inline("<%= url_for('/search?q=x', page: 2) %>") }
  assert_includes msg, "url_for \"/search?q=x\": options cannot be added to a URL that already has a query or fragment"
  assert_equal "/search?q=x", render_inline("<%= url_for('/search?q=x') %>")
end

test "url_for refuses options on a String that already has a fragment" do
  install_routes
  msg = assert_raises("RuntimeError") { render_inline("<%= url_for('/x#top', format: :csv) %>") }
  assert_includes msg, "options cannot be added to a URL that already has a query or fragment"
end

test "url_for still takes options on a plain String" do
  install_routes
  assert_equal "/search?page=2", render_inline("<%= url_for('/search', page: 2) %>")
end

test "url_for derives the route name from the model" do
  install_routes
  assert_equal "/posts/7|/x", render_inline("<%= url_for(post) %>|<%= url_for('/x') %>")
  assert_equal ["post_path(7)"], ROUTE_CALLS
end

# The general case of nested_url: every Array but the [parent, child] pair,
# which has a path of its own.
test "url_for names the route of an Array of one or three records" do
  install_routes
  env = new_env
  env["draft"] = Post.new(0, "")
  assert_equal "/posts/7|/posts", render_inline("<%= url_for([post]) %>|<%= url_for([draft]) %>", env)
  assert_equal ["post_path(7)", "posts_path()"], ROUTE_CALLS
  msg = assert_raises("RuntimeError") { render_inline("<%= url_for([post, post, post]) %>") }
  assert_equal "posts/inline:1: no route post_post_post_path", msg
  assert_equal "post_post_post_path(7, 7, 7)", ROUTE_CALLS[ROUTE_CALLS.size - 1]
  msg = assert_raises("RuntimeError") { render_inline("<%= url_for([post, 'x', post]) %>") }
  assert_equal "posts/inline:1: url_for expects records in a nested route", msg
  # A Symbol is a namespace: a name part with no route argument.
  msg = assert_raises("RuntimeError") { render_inline("<%= url_for([:admin, post]) %>") }
  assert_equal "posts/inline:1: no route admin_post_path", msg
  assert_equal "admin_post_path(7)", ROUTE_CALLS[ROUTE_CALLS.size - 1]
end

test "an unknown helper is a RuntimeError" do
  msg = assert_raises("RuntimeError") { render_inline("<%= frobnicate 1 %>") }
  assert_equal "posts/inline:1: undefined helper 'frobnicate'", msg
end

# A controller for /posts with the given query string (no session).
def controller_for_query(query)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/posts?#{query}", { "host" => "example.test" }, ""))
  Cybertrain::Controller.new(ctx)
end

def pager_env(number, more)
  penv = new_env
  penv["page"] = Cybertrain::Page.new(number, 10, more)
  penv
end

test "paginate renders Newer / Older around Page N, keeping the query minus page" do
  install_routes
  helpers = Cybertrain::Template::Helpers.new(controller_for_query("q=a+%26+b&page=2&tags[]=x&sort=new"))
  html = render_with(helpers, "<%= paginate page, posts_path %>", pager_env(2, true))
  assert_equal "<nav class=\"pager\"><a href=\"/posts?q=a+%26+b&amp;tags%5B%5D=x&amp;sort=new\" rel=\"prev\">Newer</a> " \
               "<span class=\"pager-current\">Page 2</span> " \
               "<a href=\"/posts?q=a+%26+b&amp;tags%5B%5D=x&amp;sort=new&amp;page=3\" rel=\"next\">Older</a></nav>", html
  html = render_with(helpers, "<%= paginate page, posts_path %>", pager_env(5, true))
  assert_equal "<nav class=\"pager\"><a href=\"/posts?q=a+%26+b&amp;tags%5B%5D=x&amp;sort=new&amp;page=4\" rel=\"prev\">Newer</a> " \
               "<span class=\"pager-current\">Page 5</span> " \
               "<a href=\"/posts?q=a+%26+b&amp;tags%5B%5D=x&amp;sort=new&amp;page=6\" rel=\"next\">Older</a></nav>", html
end

test "paginate leaves out a link to a page that does not exist" do
  install_routes
  helpers = Cybertrain::Template::Helpers.new(controller_for_query("page=1"))
  assert_equal "<nav class=\"pager\"><span class=\"pager-current\">Page 1</span> <a href=\"/posts?page=2\" rel=\"next\">Older</a></nav>",
               render_with(helpers, "<%= paginate page, posts_path %>", pager_env(1, true))
  assert_equal "<nav class=\"pager\"><a href=\"/posts?page=2\" rel=\"prev\">Newer</a> <span class=\"pager-current\">Page 3</span></nav>",
               render_with(helpers, "<%= paginate page, posts_path %>", pager_env(3, false))
  assert_equal "<nav class=\"pager\"><span class=\"pager-current\">Page 1</span></nav>",
               render_inline("<%= paginate page, '/posts' %>", pager_env(1, false))
end

test "paginate escapes what it is given and takes a path's own query string" do
  helpers = Cybertrain::Template::Helpers.new(controller_for_query("ignored=1"))
  html = render_with(helpers, "<%= paginate page, '/s\"<x>?q=%3Cb%3E&page=9' %>", pager_env(2, true))
  assert_equal "<nav class=\"pager\"><a href=\"/s&quot;&lt;x&gt;?q=%3Cb%3E\" rel=\"prev\">Newer</a> " \
               "<span class=\"pager-current\">Page 2</span> " \
               "<a href=\"/s&quot;&lt;x&gt;?q=%3Cb%3E&amp;page=3\" rel=\"next\">Older</a></nav>", html
  msg = assert_raises("RuntimeError") { render_inline("<%= paginate 3, '/posts' %>") }
  assert_equal "posts/inline:1: paginate expects a Page (from Relation#page), got 3", msg
end

test "a template reads the Page" do
  assert_equal "2|10|10|true|true|3|1", render_inline("<%= page.number %>|<%= page.per %>|<%= page.row_offset %>|<%= page.next? %>|<%= page.prev? %>|<%= page.next_number %>|<%= page.prev_number %>", pager_env(2, true))
  assert_equal "last", render_inline("<% if page.next? %>more<% else %>last<% end %>", pager_env(4, false))
end

def time_env
  env = new_env
  env["t"] = Time.utc(2026, 11, 10, 12, 0, 0)
  env["d"] = Date.new(2026, 11, 10)
  env
end

test "time_tag for Time, Date, text and format:" do
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">Tue, 10 Nov 2026 12:00:00 +0000</time>", render_inline("<%= time_tag t %>", time_env)
  assert_equal "<time datetime=\"2026-11-10\">2026-11-10</time>", render_inline("<%= time_tag d %>", time_env)
  # The text is escaped unless it is a SafeString.
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">&lt;now&gt;</time>", render_inline("<%= time_tag t, \"<now>\" %>", time_env)
  assert_equal "<time datetime=\"2026-11-10\"><b>day</b></time>", render_inline("<%= time_tag d, raw(\"<b>day</b>\") %>", time_env)
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">10 Nov 12:00</time>", render_inline("<%= time_tag t, format: :short %>", time_env)
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">November 10, 2026 12:00</time>", render_inline("<%= time_tag t, format: :long %>", time_env)
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">2026/11 &amp;</time>", render_inline("<%= time_tag t, format: \"%Y/%m &\" %>", time_env)
  assert_equal "<time datetime=\"2026-11-10\">Nov 10</time>", render_inline("<%= time_tag d, format: :short %>", time_env)
  assert_equal "<time datetime=\"2026-11-10\">November 10, 2026</time>", render_inline("<%= time_tag d, format: :long %>", time_env)
  # A block is the text; other keywords are attributes.
  assert_equal "<time datetime=\"2026-11-10\" class=\"when\"><i>x</i></time>", render_inline("<%= time_tag d, class: \"when\" do %><i>x</i><% end %>", time_env)
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag t, format: :iso %>", time_env) }
  assert_equal "posts/inline:1: time_tag format: must be :short, :long or a strftime String, got iso", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag \"x\" %>", time_env) }
  assert_equal "posts/inline:1: time_tag expects a Time or a Date, got x", msg
end

test "time_tag format: Strings take flags, widths and composites; an unknown directive raises" do
  env = time_env
  env["e"] = Time.utc(2026, 11, 5, 9, 3, 7, 123456)
  # 18:03:07 in Tokyo is 09:03:07 UTC.
  env["k"] = Time.utc(2026, 11, 5, 9, 3, 7).getlocal("+09:00")
  env["w"] = Time.utc(2026, 11, 5, 9, 3, 7).getlocal("-05:30")
  assert_equal "<time datetime=\"2026-11-05T09:03:07Z\">November 5, 2026</time>", render_inline("<%= time_tag e, format: \"%B %-d, %Y\" %>", env)
  assert_equal "<time datetime=\"2026-11-05T09:03:07Z\">2026-11-05 09:03:07</time>", render_inline("<%= time_tag e, format: \"%F %T\" %>", env)
  assert_equal "<time datetime=\"2026-11-05T09:03:07Z\">11/05/26 09:03 9:3 NOV</time>", render_inline("<%= time_tag e, format: \"%D %R %-H:%-M %^b\" %>", env)
  assert_equal "<time datetime=\"2026-11-05T09:03:07Z\">07.123 123456 123456000 1793869387</time>", render_inline("<%= time_tag e, format: \"%S.%L %6N %N %s\" %>", env)
  assert_equal "<time datetime=\"2026-11-05T09:03:07Z\"> 5| 9|09 AM am|309|4 4|  Nov|00009</time>", render_inline("<%= time_tag e, format: \"%e|%_H|%I %p %P|%j|%u %w|%5b|%5H\" %>", env)
  # Multibyte text between directives is copied as it is.
  assert_equal "<time datetime=\"2026-11-05T09:03:07Z\">2026年11月5日 (木曜)</time>", render_inline("<%= time_tag e, format: \"%Y年%-m月%-d日 (木曜)\" %>", env)
  # A Time with an offset: xmlschema with a colon, %z without, %:z with.
  assert_equal "<time datetime=\"2026-11-05T18:03:07+09:00\">Thu, 05 Nov 2026 18:03:07 +0900</time>", render_inline("<%= time_tag k %>", env)
  assert_equal "<time datetime=\"2026-11-05T18:03:07+09:00\">18:03 +0900 +09:00</time>", render_inline("<%= time_tag k, format: \"%R %z %:z\" %>", env)
  assert_equal "<time datetime=\"2026-11-05T03:33:07-05:30\">Thu, 05 Nov 2026 03:33:07 -0530</time>", render_inline("<%= time_tag w %>", env)
  # A Date takes the same directives.
  assert_equal "<time datetime=\"2026-11-10\">Tuesday 10 %</time>", render_inline("<%= time_tag d, format: \"%A %-d %%\" %>", env)
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag e, format: \"%Y %Q\" %>", env) }
  assert_equal "posts/inline:1: time_tag format: unknown directive %Q in \"%Y %Q\"", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag e, format: \"%Y %-\" %>", env) }
  assert_equal "posts/inline:1: time_tag format: incomplete directive %- in \"%Y %-\"", msg
end

test "time_tag format: a width replaces a number's padding; a width or flag strftime does not mean here raises" do
  env = time_env
  env["e"] = Time.utc(2026, 11, 5, 9, 3, 7, 123456)
  # As Time#strftime: %1d is "5", %4d "0005", %_4d "   5", %3e "  5", %04e "0005".
  assert_equal "<time datetime=\"2026-11-05T09:03:07Z\">5|0005|   5|  5|0005|9|  9</time>",
               render_inline("<%= time_tag e, format: \"%1d|%4d|%_4d|%3e|%04e|%1H|%3k\" %>", env)
  [["%6L", "%L takes no width or flag; use %3N, %6N or %9N"], ["%-N", "%N takes no flag"], ["%:Y", "the : flag is only for %:z"],
   ["%::z", "%z takes no width and no flag but :"], ["%6z", "%z takes no width and no flag but :"], ["%5Z", "%Z takes no width"],
   ["%-_d", "combine at most one of the flags - _ 0"], ["%^#b", "combine at most one of the flags ^ #"],
   ["%-T", "%T takes no flag but ^"]].each do |directive, why|
    msg = assert_raises("RuntimeError") { render_inline("<%= time_tag e, format: \"%Y #{directive}\" %>", env) }
    assert_equal "posts/inline:1: time_tag format: #{directive} in \"%Y #{directive}\": #{why}", msg
  end
end

def page_helpers(verb, target)
  ctx = Cybertrain::Context.new(Cybertrain::Request.new(verb, target, { "host" => "example.test" }, ""))
  Cybertrain::Template::Helpers.new(Cybertrain::Controller.new(ctx))
end

test "current_page? path only, with query, false on POST" do
  get = page_helpers("GET", "/posts?page=2")
  assert_equal "true", render_with(get, "<%= current_page?(\"/posts\") %>")
  assert_equal "true", render_with(get, "<%= current_page?(\"/posts/\") %>")
  assert_equal "false", render_with(get, "<%= current_page?(\"/posts/7\") %>")
  # With a query in the argument, the query must match too.
  assert_equal "true", render_with(get, "<%= current_page?(\"/posts?page=2\") %>")
  assert_equal "false", render_with(get, "<%= current_page?(\"/posts?page=3\") %>")
  assert_equal "true", render_with(page_helpers("HEAD", "/posts"), "<%= current_page?(\"/posts\") %>")
  assert_equal "false", render_with(page_helpers("POST", "/posts"), "<%= current_page?(\"/posts\") %>")
  # A record goes through url_for.
  install_routes
  assert_equal "true", render_with(page_helpers("GET", "/posts/7"), "<%= current_page?(post) %>")
  # Without a controller there is no current page.
  assert_equal "false", render_inline("<%= current_page?(\"/posts\") %>")
end

Cybertrain::Test.run!
