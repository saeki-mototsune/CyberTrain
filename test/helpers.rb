require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/session"
require "cybertrain/flash"
require_relative "support/zone_swap"

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

# The application dictionary of the "number helpers read ..." test: a Hash
# it fills, installed as gen/locales.rb installs Gen::Locales. Empty, every
# other test reads the bundled en and ja dictionaries.
module HelperLocales
  TEXTS = { "" => "" }
  TEXTS.delete("")

  def self.lookup(key) = TEXTS[key]
  def self.lookup_list(key) = key == "\u0000" ? [""] : []
  def self.resolver = ->(key) { HelperLocales.lookup(key) }
  def self.list_resolver = ->(key) { HelperLocales.lookup_list(key) }
end

I18n.install_dictionary(HelperLocales.resolver, HelperLocales.list_resolver)

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
  # A format name is a time.formats / date.formats key (I18n.l): one no
  # dictionary holds is refused, as is a format that is neither a name
  # nor a pattern.
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag t, format: :iso %>", time_env) }
  assert_equal "posts/inline:1: translation missing: en.time.formats.iso", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag d, format: :iso %>", time_env) }
  assert_equal "posts/inline:1: translation missing: en.date.formats.iso", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag t, format: 3 %>", time_env) }
  assert_equal "posts/inline:1: time_tag format: must be a format name (:short, :long, ...) or a strftime String, got 3", msg
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

test "time_tag renders in Time.zone, or once in zone:; a Date as it is" do
  env = time_env
  env["nov"] = Time.utc(2026, 11, 11, 20)
  env["day"] = Date.new(2026, 11, 11)
  env["k"] = Time.utc(2026, 11, 5, 9, 3, 7).getlocal("+09:00")
  ZoneSwap.during("Asia/Tokyo") do
    assert_equal "<time datetime=\"2026-11-12T05:00:00+09:00\">Thu, 12 Nov 2026 05:00:00 +0900</time>", render_inline("<%= time_tag nov %>", env)
    assert_equal "<time datetime=\"2026-11-12T05:00:00+09:00\">05:00 JST +09:00</time>", render_inline("<%= time_tag nov, format: \"%H:%M %Z %:z\" %>", env)
    assert_equal "<time datetime=\"2026-11-12T05:00:00+09:00\">November 12, 2026 05:00</time>", render_inline("<%= time_tag nov, format: :long %>", env)
    assert_equal "<time datetime=\"2026-11-11T15:00:00-05:00\" class=\"at\">15:00 EST</time>",
                 render_inline("<%= time_tag nov, format: \"%H:%M %Z\", zone: \"America/New_York\", class: \"at\" %>", env)
    assert_equal "<time datetime=\"2026-11-11T15:00:00-05:00\">Wed, 11 Nov 2026 15:00:00 -0500</time>", render_inline("<%= time_tag nov, zone: \"America/New_York\" %>", env)
    assert_equal "<time datetime=\"2026-11-11T20:00:00Z\">20:00</time>", render_inline("<%= time_tag nov, format: \"%H:%M\", zone: \"UTC\" %>", env)
    # A UTC alias is UTC (Z); a zone at offset 0 that is not UTC writes
    # the offset.
    assert_equal "<time datetime=\"2026-11-11T20:00:00Z\">20:00 UTC</time>", render_inline("<%= time_tag nov, format: \"%H:%M %Z\", zone: \"Etc/Universal\" %>", env)
    assert_equal "<time datetime=\"2026-11-11T20:00:00Z\">20:00</time>", render_inline("<%= time_tag nov, format: \"%H:%M\", zone: \"Etc/Zulu\" %>", env)
    assert_equal "<time datetime=\"2026-11-11T20:00:00+00:00\">20:00 GMT</time>", render_inline("<%= time_tag nov, format: \"%H:%M %Z\", zone: \"Europe/London\" %>", env)
    # A Date is rendered as it is, in Time.zone or zone:.
    assert_equal "<time datetime=\"2026-11-11\">2026-11-11</time>", render_inline("<%= time_tag day %>", env)
    assert_equal "<time datetime=\"2026-11-11\">2026-11-11</time>", render_inline("<%= time_tag day, zone: \"America/New_York\" %>", env)
    assert_equal "05:00 JST", render_inline("<%= l nov, format: \"%H:%M %Z\" %>", env)
    assert_equal "15:00", render_inline("<%= l nov, format: \"%H:%M\", zone: \"America/New_York\" %>", env)
    # A Time with an offset of its own keeps it.
    assert_equal "<time datetime=\"2026-11-05T18:03:07+09:00\">18:03 +0900</time>", render_inline("<%= time_tag k, format: \"%R %z\" %>", env)
  end
  msg = assert_raises("RuntimeError") { render_inline("<%= time_tag nov, zone: \"Mars/Base\" %>", env) }
  assert_equal "posts/inline:1: unknown time zone \"Mars/Base\"", msg
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

test "time_tag_strftime formats every directive the bundled formats use" do
  # The bundled en and ja date.formats / time.formats use %Y %m %d %b %B
  # %a %H %M %S %z; %y %e %-d %-m are the other directives rails-i18n's
  # locales use.
  jan = Time.utc(2026, 1, 5, 3, 4, 9)
  assert_equal "26| 5|+0000|5|1|2026/01/05 03:04:09|Mon Jan January",
               Cybertrain::Template::Helpers.time_tag_strftime(jan, "%y|%e|%z|%-d|%-m|%Y/%m/%d %H:%M:%S|%a %b %B")
  assert_equal "26| 5|5|1|2026-01-05",
               Cybertrain::Template::Helpers.time_tag_strftime(Date.new(2026, 1, 5), "%y|%e|%-d|%-m|%Y-%m-%d")
end

test "t and l in a template: the bundled dictionary, lazy keys, the missing span" do
  I18n.locale = nil
  I18n.mark_missing = true
  I18n.available_locales = [:en, :ja]
  # An absolute key, escaped by the template ("can't" has an apostrophe).
  assert_equal "can&#39;t be blank", render_inline("<%= t(\"errors.messages.blank\") %>")
  assert_equal "can&#39;t be blank", render_inline("<%= translate(\"errors.messages.blank\") %>")
  assert_equal "を入力してください", render_inline("<%= t(\"errors.messages.blank\", locale: :ja) %>")
  # count: picks the plural form.
  assert_equal "3 errors prohibited this post from being saved",
               render_inline("<%= t(\"errors.template.header\", count: 3, model: \"post\") %>")
  # A lazy key under the template's name, posts/inline.
  assert_equal "<span class=\"translation_missing\" title=\"translation missing: en.posts.inline.page_title\">Page Title</span>",
               render_inline("<%= t(\".page_title\") %>")
  assert_equal "Fallback &amp; more", render_inline("<%= t(\".page_title\", default: \"Fallback & more\") %>")
  # l, with the template's local t (a Time) as its argument: a local of
  # that name is still the local.
  assert_equal "2026-11-10|10 Nov 12:00|2026/11/10|PM", render_inline("<%= l(d) %>|<%= l(t, format: :short) %>|<%= localize(d, locale: :ja) %>|<%= l(t, format: raw(\"%p\")) %>", time_env)
  # The wrong number of arguments, a value l cannot format, and a lazy key
  # with no template name.
  msg = assert_raises("RuntimeError") { render_inline("<%= t(\"a\", \"b\") %>") }
  assert_equal "posts/inline:1: wrong number of arguments for 't' (given 2, expected 1)", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= l(\"2026-11-10\") %>") }
  assert_equal "posts/inline:1: l: expected a Time or a Date (got String)", msg
  nameless = Cybertrain::Template::Template.parse("<%= t(\".x\") %>", "")
  msg = assert_raises("RuntimeError") { Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil)).render(nameless, new_env) }
  assert_equal ":1: t: the lazy key \".x\" needs a template name", msg
end

# src rendered with the thread's locale set to loc.
def render_in(loc, src, env = new_env)
  I18n.with_locale(loc) { render_inline(src, env) }
end

test "number helpers in ja" do
  I18n.locale = nil
  I18n.available_locales = [:en, :ja]
  # rails-i18n's ja: currency "%n%u", unit 円, precision 0; decimal_units
  # "%n %u" (the vendored fixture has the space); storage_units "%n%u".
  assert_equal "1,234円|-1,235円|$1,234", render_in(:ja, "<%= number_to_currency(1234) %>|<%= number_to_currency(-1234.5) %>|<%= number_to_currency(1234, unit: '$', format: '%u%n') %>")
  assert_equal "1.23 百万|1.23 千|123|1.23 十億", render_in(:ja, "<%= number_to_human(1234567) %>|<%= number_to_human(1234) %>|<%= number_to_human(123) %>|<%= number_to_human(1234567890) %>")
  assert_equal "1バイト|123バイト|1.21KB|1.18MB", render_in(:ja, "<%= number_to_human_size(1) %>|<%= number_to_human_size(123) %>|<%= number_to_human_size(1234) %>|<%= number_to_human_size(1234567) %>")
  assert_equal "1,234,567.5|111.235|100.000%", render_in(:ja, "<%= number_with_delimiter(1234567.5) %>|<%= number_with_precision(111.2345) %>|<%= number_to_percentage(100) %>")
  # nil still renders "".
  assert_equal "|", render_in(:ja, "<%= number_to_currency(nil) %>|<%= number_to_human_size(nil) %>")
end

test "number helpers in en are unchanged" do
  I18n.locale = nil
  I18n.available_locales = [:en, :ja]
  # 4a's Rails examples, read from the en dictionary now.
  assert_equal "1,234,567|1,234.5", render_in(:en, "<%= number_with_delimiter(1234567) %>|<%= number_with_delimiter(1234.5) %>")
  assert_equal "111.235|111.23|13|1.111,23", render_in(:en, "<%= number_with_precision(111.2345) %>|<%= number_with_precision(111.2345, precision: 2) %>|<%= number_with_precision(13, precision: 5, strip_insignificant_zeros: true) %>|<%= number_with_precision(1111.2345, precision: 2, separator: ',', delimiter: '.') %>")
  assert_equal "123|1.23 Thousand|1.23 Million|1230 Quadrillion|490 Thousand|500 lt|0", render_in(:en, "<%= number_to_human(123) %>|<%= number_to_human(1234) %>|<%= number_to_human(1234567) %>|<%= number_to_human(1234567890123456789) %>|<%= number_to_human(489939, precision: 2) %>|<%= number_to_human(500000, units: { unit: 'ml', thousand: 'lt' }) %>|<%= number_to_human(0) %>")
  assert_equal "100.000%|100%|302.24399%", render_in(:en, "<%= number_to_percentage(100) %>|<%= number_to_percentage(100, precision: 0) %>|<%= number_to_percentage(302.24398923423, precision: 5) %>")
  assert_equal "$1,234,567,890.50|$1,234,567,890.51|$1,234,567,890.506|-$1,234,567,890.50|1,234,567,890.50 €", render_in(:en, "<%= number_to_currency(1234567890.50) %>|<%= number_to_currency(1234567890.506) %>|<%= number_to_currency(1234567890.506, precision: 3) %>|<%= number_to_currency(-1234567890.50) %>|<%= number_to_currency(1234567890.50, unit: '€', format: '%n %u') %>")
  assert_equal "1 Byte|123 Bytes|0 Bytes|-1 Byte|1.21 KB|12.1 KB|1.18 MB|1.15 GB|1.12 TB|1.1 PB|1.07 EB", render_in(:en, "<%= number_to_human_size(1) %>|<%= number_to_human_size(123) %>|<%= number_to_human_size(0) %>|<%= number_to_human_size(-1) %>|<%= number_to_human_size(1234) %>|<%= number_to_human_size(12345) %>|<%= number_to_human_size(1234567) %>|<%= number_to_human_size(1234567890) %>|<%= number_to_human_size(1234567890123) %>|<%= number_to_human_size(1234567890123456) %>|<%= number_to_human_size(1234567890123456789) %>")
end

test "number helpers read every setting of an application's locale, then number.format, then the default locale" do
  I18n.locale = nil
  I18n.available_locales = [:en, :ja, :de]
  t = HelperLocales::TEXTS
  t["de.number.format.delimiter"] = "."
  t["de.number.format.separator"] = ","
  t["de.number.format.precision"] = "2"
  t["de.number.currency.format.unit"] = "€"
  t["de.number.currency.format.format"] = "%n %u"
  t["de.number.percentage.format.format"] = "%n %"
  t["de.number.human.decimal_units.format"] = "%n%u"
  t["de.number.human.decimal_units.units.thousand"] = "Tsd."
  t["de.number.human.storage_units.format"] = "%u %n"
  t["de.number.human.storage_units.units.byte.one"] = "Byte"
  t["de.number.human.storage_units.units.byte.other"] = "Bytes"
  t["de.number.human.storage_units.units.kb"] = "kB"
  # The namespace's own setting, else de's number.format (delimiter ".",
  # separator ",", precision 2); what de lacks altogether is en's
  # (number.human.decimal_units.units.million, storage_units.units.mb).
  assert_equal "1.234.567,5|1.111,23", render_in(:de, "<%= number_with_delimiter(1234567.5) %>|<%= number_with_precision(1111.2345) %>")
  assert_equal "1.234,50 €|-1.234,50 €", render_in(:de, "<%= number_to_currency(1234.5) %>|<%= number_to_currency(-1234.5) %>")
  assert_equal "1.234,50 %", render_in(:de, "<%= number_to_percentage(1234.5) %>")
  assert_equal "1,2Tsd.|1,2Million|12", render_in(:de, "<%= number_to_human(1234) %>|<%= number_to_human(1234567) %>|<%= number_to_human(12) %>")
  assert_equal "Byte 1|Bytes 2|kB 1,2|MB 1,2", render_in(:de, "<%= number_to_human_size(1) %>|<%= number_to_human_size(2) %>|<%= number_to_human_size(1234) %>|<%= number_to_human_size(1234567) %>")
  # An application key overrides the bundled one in a bundled locale.
  t["en.number.currency.format.unit"] = "US$"
  assert_equal "US$1.50", render_in(:en, "<%= number_to_currency(1.5) %>")
  t.clear
  assert_equal "$1.50", render_in(:en, "<%= number_to_currency(1.5) %>")
  I18n.available_locales = [:en, :ja]
end

# The English settings of each helper, as Rails' NumberHelper DEFAULTS.
NUMBER_SRC = "<%= number_with_delimiter(1234.5) %>|<%= number_with_precision(1.2345, precision: 2) %>|" \
             "<%= number_to_currency(12.5) %>|<%= number_to_percentage(12.5) %>|<%= number_to_human(1234567) %>|" \
             "<%= number_to_human_size(1) %>|<%= number_to_human_size(1234) %>"
NUMBER_EN = "1,234.5|1.23|$12.50|12.500%|1.23 Million|1 Byte|1.21 KB"

test "number helpers answer the English settings when neither the current nor the default locale has number keys" do
  I18n.locale = nil
  I18n.mark_missing = true
  t = HelperLocales::TEXTS
  t["fr.greeting"] = "Bonjour"
  t["de.greeting"] = "Hallo"
  # fr is the default and the current locale, and holds none of them.
  I18n.default_locale = :fr
  I18n.available_locales = [:fr, :de]
  assert_equal NUMBER_EN, render_in(:fr, NUMBER_SRC)
  # de is current, fr the default: neither has them.
  assert_equal NUMBER_EN, render_in(:de, NUMBER_SRC)
  # A setting one of them has still wins, the rest stay English.
  t["fr.number.format.separator"] = ","
  assert_equal "1,234,5|1,23|$12,50|12,500%|1,23 Million|1 Byte|1,21 KB", render_in(:de, NUMBER_SRC)
  t.clear
  I18n.default_locale = :en
  I18n.available_locales = [:en, :ja]
end

test "a precision: keyword is read as 0.4 read it, in all four helpers" do
  I18n.locale = nil
  I18n.default_locale = :en
  I18n.available_locales = [:en, :ja]
  # A Float precision is its whole part; a text that is no number is 0.
  assert_equal "1.23|1.23|1.23 Thousand|12.50%|$1.23", render_in(:en, "<%= number_with_precision(1.2345, precision: 2.0) %>|" \
    "<%= number_with_precision(1.2345, precision: '2') %>|<%= number_to_human(1234, precision: 3.0) %>|" \
    "<%= number_to_percentage(12.5, precision: 2.0) %>|<%= number_to_currency(1.234, precision: 2.0) %>")
  assert_equal "1|1%|$1", render_in(:en, "<%= number_with_precision(1.2345, precision: 'abc') %>|" \
    "<%= number_to_percentage(1.2, precision: 'abc') %>|<%= number_to_currency(1.234, precision: 'abc') %>")
end

test "time_ago_in_words and distance_of_time_in_words in en and ja" do
  I18n.locale = nil
  I18n.available_locales = [:en, :ja]
  h = Cybertrain::Template::Helpers.new(nil)
  now = Time.at(1_700_000_000)
  seconds = [0, 29, 45, 150, 44 * 60, 50 * 60, 5 * 3600, 30 * 3600, 3 * 86_400,
             35 * 86_400, 100 * 86_400, 400 * 86_400, 500 * 86_400, 700 * 86_400, 3 * 365 * 86_400]
  words = ["1分未満", "1分未満", "1分", "3分", "44分", "約1時間", "約5時間", "1日", "3日",
           "約1ヶ月", "3ヶ月", "約1年", "1年以上", "2年弱", "約3年"]
  seconds.each_with_index do |s, i|
    assert_equal words[i], I18n.with_locale(:ja) { h.distance_of_time_in_words(now - s, now) }
  end
  env = new_env
  env["a"] = Time.utc(2026, 11, 10, 12, 0, 0)
  env["b"] = Time.utc(2026, 11, 10, 12, 1, 30)
  env["c"] = Time.utc(2025, 1, 1, 0, 0, 0)
  env["e"] = Time.utc(2026, 5, 1, 0, 0, 0)
  # 90 s, and 1 year 4 months (either order).
  assert_equal "2 minutes|over 1 year|over 1 year", render_in(:en, "<%= distance_of_time_in_words(a, b) %>|<%= distance_of_time_in_words(c, e) %>|<%= distance_of_time_in_words(e, c) %>", env)
  assert_equal "2分|1年以上|1年以上", render_in(:ja, "<%= distance_of_time_in_words(a, b) %>|<%= distance_of_time_in_words(c, e) %>|<%= distance_of_time_in_words(e, c) %>", env)
  env["t"] = Time.now - 90
  assert_equal "2 minutes", render_in(:en, "<%= time_ago_in_words(t) %>", env)
  assert_equal "2分", render_in(:ja, "<%= time_ago_in_words(t) %>", env)
  env["t"] = Time.now - 485 * 86_400
  assert_equal "over 1 year", render_in(:en, "<%= time_ago_in_words(t) %>", env)
  assert_equal "1年以上", render_in(:ja, "<%= time_ago_in_words(t) %>", env)
  msg = assert_raises("RuntimeError") { render_inline("<%= distance_of_time_in_words(a) %>", env) }
  assert_equal "posts/inline:1: wrong number of arguments for 'distance_of_time_in_words' (given 1, expected 2)", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= distance_of_time_in_words(a, 'now') %>", env) }
  assert_equal "posts/inline:1: 'distance_of_time_in_words' expects a Time", msg
  msg = assert_raises("RuntimeError") { render_inline("<%= distance_of_time_in_words(a, b, scope: 'x') %>", env) }
  assert_equal "posts/inline:1: 'distance_of_time_in_words' takes no keyword arguments (given scope)", msg
end

test "pluralize leaves a word alone outside English" do
  I18n.locale = nil
  I18n.available_locales = [:en, :ja]
  assert_equal "2 記事|1 記事|0 記事|2 post|2 記事たち", render_in(:ja, "<%= pluralize(2, '記事') %>|<%= pluralize(1, '記事') %>|<%= pluralize(0, '記事') %>|<%= pluralize(2, 'post') %>|<%= pluralize(2, '記事', '記事たち') %>")
  assert_equal "2 posts|1 post|3 people|2 mice", render_in(:en, "<%= pluralize(2, 'post') %>|<%= pluralize(1, 'post') %>|<%= pluralize(3, 'person') %>|<%= pluralize(2, 'mouse', 'mice') %>")
end

test "paginate in ja, and an application's pager text escaped" do
  I18n.locale = nil
  I18n.available_locales = [:en, :ja]
  helpers = Cybertrain::Template::Helpers.new(controller_for_query("page=2"))
  html = I18n.with_locale(:ja) { render_with(helpers, "<%= paginate page, '/posts' %>", pager_env(2, true)) }
  assert_equal "<nav class=\"pager\"><a href=\"/posts\" rel=\"prev\">前へ</a> <span class=\"pager-current\">2ページ</span> <a href=\"/posts?page=3\" rel=\"next\">次へ</a></nav>", html
  HelperLocales::TEXTS["en.cybertrain.pager.newer"] = "<Newer>"
  HelperLocales::TEXTS["en.cybertrain.pager.page"] = "%{page} of many & more"
  html = render_with(helpers, "<%= paginate page, '/posts' %>", pager_env(2, false))
  assert_equal "<nav class=\"pager\"><a href=\"/posts\" rel=\"prev\">&lt;Newer&gt;</a> <span class=\"pager-current\">2 of many &amp; more</span></nav>", html
  HelperLocales::TEXTS.clear
end

test "time_tag's format names go through I18n.l: a ja page gets ja dates" do
  I18n.locale = nil
  I18n.available_locales = [:en, :ja]
  assert_equal "<time datetime=\"2026-11-10\">2026年11月10日(火)</time>", render_in(:ja, "<%= time_tag d, format: :long %>", time_env)
  assert_equal "<time datetime=\"2026-11-10\">11/10</time>", render_in(:ja, "<%= time_tag d, format: :short %>", time_env)
  assert_equal "<time datetime=\"2026-11-10\">2026/11/10</time>", render_in(:ja, "<%= time_tag d %>", time_env)
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">2026/11/10 12:00</time>", render_in(:ja, "<%= time_tag t, format: :long %>", time_env)
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">11/10 12:00</time>", render_in(:ja, "<%= time_tag t, format: :short %>", time_env)
  assert_equal "<time datetime=\"2026-11-10T12:00:00Z\">2026年11月10日(火) 12時00分00秒 +0000</time>", render_in(:ja, "<%= time_tag t %>", time_env)
  # A pattern String stays a strftime pattern, as before (strftime's
  # English names; only a format name is looked up).
  assert_equal "<time datetime=\"2026-11-10\">Tue 10</time>", render_in(:ja, "<%= time_tag d, format: '%a %-d' %>", time_env)
  # An application's format name.
  HelperLocales::TEXTS["ja.date.formats.month"] = "%Y年%-m月"
  assert_equal "<time datetime=\"2026-11-10\">2026年11月</time>", render_in(:ja, "<%= time_tag d, format: :month %>", time_env)
  HelperLocales::TEXTS.clear
  # en is byte for byte what the fixed patterns gave.
  assert_equal "<time datetime=\"2026-11-10\">November 10, 2026</time>", render_in(:en, "<%= time_tag d, format: :long %>", time_env)
end

Cybertrain::Test.run!
