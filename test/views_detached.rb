require "tmpdir"
require "cybertrain/test"
require "cybertrain/test/views"
require "cybertrain/controller"

# Rendering outside a request (spec 2.5): Views.render_partial and
# Views.render_component build the helpers with no controller; path helpers
# work, the request-bound helpers raise Views::OutsideRequest.
#
# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

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
end

class CardComponent < Cybertrain::Component
  def initialize(title:)
    @title = title
  end

  def view_assigns
    { "title" => @title }
  end

  def component_name
    "card"
  end

  def component_template
    "components/card_component.html.erb"
  end
end

Cybertrain::Views.url_resolver = lambda do |name, args|
  case name
  when "article_path"
    id = ""
    case args[0]
    when Cybertrain::Model then id = args[0].to_param
    end
    "/articles/#{id}"
  else raise "no route #{name}"
  end
end

ROOT = Dir.mktmpdir("cybertrain-views-detached")
FILES = {
  "app/views/articles/_article.html.erb" => "<%# locals: (article:) %>\n<a href=\"<%= article_path(article) %>\"><%= article.title %></a>",
  "app/views/articles/_csrf.html.erb" => "<%= csrf_token %>",
  "app/views/articles/_meta.html.erb" => "<%= csrf_meta_tags %>",
  "app/views/articles/_params.html.erb" => "<%= params[:q] %>",
  "app/views/articles/_flash.html.erb" => "<%= flash[:notice] %>",
  "app/views/articles/_path.html.erb" => "<%= request_path %>",
  "app/views/articles/_url.html.erb" => "<%= article_url(1) %>",
  "app/views/articles/_button.html.erb" => "<%= button_to 'Go', '/go' %>",
  "app/views/_top.html.erb" => "top <%= n %>",
  "app/components/card_component.html.erb" => "<h3><%= title %></h3><%= content %>"
}
DIRS = ["app", "app/views", "app/views/articles", "app/components"]
DIRS.each { |d| Dir.mkdir("#{ROOT}/#{d}") }
FILES.each_key { |f| File.write("#{ROOT}/#{f}", FILES[f]) }
at_exit do
  FILES.each_key { |f| File.delete("#{ROOT}/#{f}") }
  DIRS.reverse.each { |d| Dir.rmdir("#{ROOT}/#{d}") }
  Dir.rmdir(ROOT)
end
Cybertrain::Views.configure("#{ROOT}/app/views", cache: false)

def outside_error(name)
  msg = ""
  begin
    Cybertrain::Views.render_partial(name)
  rescue Cybertrain::Views::OutsideRequest => e
    msg = "OutsideRequest: #{e.message}"
  rescue StandardError => e
    msg = "other: #{e.message}"
  end
  msg
end

test "render_partial returns the HTML, path helpers included" do
  html = Cybertrain::Views.render_partial("articles/article", article: Article.new(12, "A & B"))
  assert_equal "<a href=\"/articles/12\">A &amp; B</a>", html
end

test "strict locals are checked" do
  msg = ""
  begin
    Cybertrain::Views.render_partial("articles/article", post: 1)
  rescue ArgumentError => e
    msg = e.message
  end
  assert_equal "missing local 'article' for articles/_article.html.erb", msg
end

test "a partial name without a directory is at the views root" do
  assert_equal "top 3", Cybertrain::Views.render_partial("top", n: 3)
end

test "request-bound helpers raise OutsideRequest" do
  assert_equal "OutsideRequest: csrf_token needs a request", outside_error("articles/csrf")
  assert_equal "OutsideRequest: csrf_meta_tags needs a request", outside_error("articles/meta")
  assert_equal "OutsideRequest: params needs a request", outside_error("articles/params")
  assert_equal "OutsideRequest: flash needs a request", outside_error("articles/flash")
  assert_equal "OutsideRequest: request_path needs a request", outside_error("articles/path")
  assert_equal "OutsideRequest: article_url needs a request", outside_error("articles/url")
end

test "a form renders without the authenticity token" do
  assert_equal "<form class=\"button_to\" method=\"post\" action=\"/go\"><button type=\"submit\">Go</button></form>", Cybertrain::Views.render_partial("articles/button")
end

test "render_component returns the HTML with the content unescaped" do
  assert_equal "<h3>x &lt;y&gt;</h3><b>c</b>", Cybertrain::Views.render_component(CardComponent.new(title: "x <y>"), "<b>c</b>")
  assert_equal "<h3>x</h3>", Cybertrain::Views.render_component(CardComponent.new(title: "x"))
end

test "Cybertrain::Test wraps both" do
  assert_equal "<h3>t</h3><i>i</i>", Cybertrain::Test.render_component(CardComponent.new(title: "t"), content: "<i>i</i>")
  assert_equal "top 4", Cybertrain::Test.render_partial("top", n: 4)
end

Cybertrain::Test.run!
