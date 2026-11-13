require "tmpdir"
require "cybertrain/test"
require "cybertrain/test/views"
require "cybertrain/test/select"
require "cybertrain/controller"

# render_inline (spec section 9.1) and assert_select over what the
# framework renders: a component (CardComponent, with the Gen::Components
# table hand-written in gen's shape as in test/component_render.rb), a
# form partial (form_with on a new record, outside any request), a page
# with a layout-like head, a turbo frame and a turbo stream, and
# ViewComponent::TestCase reaching both top-level methods from an
# instance, as the class form does.
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
  def initialize(title:, value: 0)
    @title = title
    @value = value
  end

  def value_text = "#{@value} pts"

  # What gen/components.rb emits for this class.
  def view_assigns
    { "title" => @title, "value" => @value }
  end

  def call_view_method(name)
    case name
    when :value_text then value_text
    else nil
    end
  end

  def view_method?(name)
    case name
    when "value_text" then true
    else false
    end
  end

  def component_name
    "card"
  end

  def component_template
    "__components/card_component.html.erb"
  end
end

module Gen
  module Components
    def self.build(name, kwargs)
      case name
      when "card"
        Cybertrain::Component.check_keywords!(name, kwargs, ["title", "value"], 1)
        if kwargs.key?("value") then ::CardComponent.new(title: kwargs["title"], value: kwargs["value"])
        else ::CardComponent.new(title: kwargs["title"])
        end
      else
        raise Cybertrain::Component::Unknown, "no component '#{name}' (app/components/#{name}_component.rb, then `spin run gen`)"
      end
    end
  end
end

Cybertrain::Views.component_builder = ->(name, kwargs) { Gen::Components.build(name, kwargs) }

def route_param(v)
  case v
  when Cybertrain::Model then v.to_param
  else v.to_s
  end
end

Cybertrain::Views.url_resolver = lambda do |name, args, options|
  case name
  when "articles_path" then "/articles"
  when "article_path" then Cybertrain::Gen.with_options("/articles/#{route_param(args[0])}", options)
  else raise "no route #{name}"
  end
end

ROOT = Dir.mktmpdir("cybertrain-render-inline")
FILES = {
  "app/components/card_component.html.erb" => "<div class=\"card\"><h2><%= title %></h2><p><%= value_text %></p><%= content %></div>",
  "app/views/articles/_form.html.erb" => "<%# locals: (article:) %>\n" \
                                         "<%= form_with(model: article) do |f| %>\n" \
                                         "  <div class=\"field\"><%= f.label :title %>\n  <%= f.text_field :title %></div>\n" \
                                         "  <%= f.text_area :body %>\n  <%= f.submit \"Save\" %>\n<% end %>",
  "app/views/pages/_page.html.erb" => "<%# locals: (article:) %>\n" \
                                      "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <title>Blog &amp; <%= article.title %></title>\n" \
                                      "  <meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n" \
                                      "  <script>if (1 < 2) { var s = \"</div><p>\"; }</script>\n</head>\n<body>\n" \
                                      "  <%= turbo_frame_tag article, src: article_path(article, page: 2) do %><%= render component: \"card\", title: article.title %><% end %>\n" \
                                      "  <%= turbo_stream.replace article, html: \"<b>new</b>\" %>\n" \
                                      "  <%= link_to \"Edit <it>\", article_path(article) %>\n  <br>\n  <%= render \"articles/form\", article: article %>\n" \
                                      "</body>\n</html>\n",
  "app/views/pages/_broken.html.erb" => "<div><p>open</div>"
}
DIRS = ["app", "app/views", "app/views/articles", "app/views/pages", "app/components"]
DIRS.each { |d| Dir.mkdir("#{ROOT}/#{d}") }
FILES.each_key { |f| File.write("#{ROOT}/#{f}", FILES[f]) }
at_exit do
  FILES.each_key { |f| File.delete("#{ROOT}/#{f}") }
  DIRS.reverse.each { |d| Dir.rmdir("#{ROOT}/#{d}") }
  Dir.rmdir(ROOT)
end
Cybertrain::Views.configure("#{ROOT}/app/views", cache: false)

# The class form: a ViewComponent::TestCase whose test methods call the
# top-level render_inline and assert_select, as gen's rewrite leaves them.
class CardComponentTest < ViewComponent::TestCase
  def test_renders_the_title
    render_inline(CardComponent.new(title: "Hello"))
    assert_select "div.card > h2", text: "Hello"
    nil
  end

  def test_renders_the_form_partial
    html = render_inline(partial: "articles/form", locals: { article: Article.new(0, "") })
    assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
    assert_includes html, "Save"
    nil
  end
end

test "render_inline renders a component and a partial and keeps the HTML" do
  assert_includes render_inline(CardComponent.new(title: "Hello")), "Hello"
  assert_select "div.card > h2", text: "Hello"
  html = render_inline(partial: "articles/form", locals: { article: Article.new(0, "") })
  assert_select "form[action=\"/articles\"]"; assert_includes html, "Save"
end

test "a component with content:, its view method, and the HTML kept for assert_select" do
  html = render_inline(CardComponent.new(title: "T & U", value: 3), content: "<em>body</em>")
  assert_equal "<div class=\"card\"><h2>T &amp; U</h2><p>3 pts</p><em>body</em></div>", html
  assert_equal html, Cybertrain::Test.last_html
  matched = assert_select("div.card > *", count: 3)
  assert_equal ["h2", "p", "em"], matched.map(&:node_tag)
  assert_select "h2", "T & U"
  assert_select "p", text: /\A3 pts\z/
  assert_select "div.card em", 1
  assert_select "form", false
end

test "the form partial: form_with on a new record, outside a request" do
  html = render_inline(partial: "articles/form", locals: { article: Article.new(0, "A \"quoted\" <title>") })
  assert_select "form[action=\"/articles\"][method=post] input[name=\"article[title]\"]"
  assert_select "form > div.field > label[for=article_title]", "Title"
  assert_select "input#article_title[value='A \"quoted\" <title>']"
  assert_select "textarea[name=\"article[body]\"]", text: ""
  assert_select "input[type=submit][value=Save]"
  # No authenticity token outside a request.
  assert_select "input[name=authenticity_token]", false
  assert_select "form input", count: 2
  # An edit form: the record's path and the hidden _method.
  render_inline(partial: "articles/form", locals: { article: Article.new(7, "x") })
  assert_select "form[action=\"/articles/7\"] > input[type=hidden][name=_method][value=patch]"
  refute html == Cybertrain::Test.last_html
end

test "a page: doctype, head, script text, a turbo frame around a component, a turbo stream, a link, the form" do
  render_inline(partial: "pages/page", locals: { article: Article.new(3, "Hi") })
  assert_select "html[lang=en] > head > title", text: "Blog & Hi"
  assert_select "head > script", text: /var s = "<\/div><p>"/
  assert_select "p", count: 1
  assert_select "turbo-frame#article_3[src=\"/articles/3?page=2\"] > div.card > h2", "Hi"
  assert_select "turbo-stream[action=replace][target=article_3] > template", text: "<b>new</b>"
  assert_select "turbo-stream b", false
  assert_select "a[href=\"/articles/3\"]", "Edit <it>"
  assert_select "body > br"
  assert_select "body > form[action=\"/articles/3\"] input#article_title[value=Hi]"
  assert_select "body > *", count: 5
end

test "ViewComponent::TestCase: the class form reaches render_inline and assert_select" do
  t = CardComponentTest.new
  t.setup
  t.test_renders_the_title
  t.test_renders_the_form_partial
  t.teardown
  assert_includes Cybertrain::Test.last_html, "<form action=\"/articles\""
  base = false
  case t
  when ActiveSupport::TestCase then base = true
  end
  assert base
end

test "failures: a missing element, an unsupported selector, a block, neither or both forms, malformed HTML" do
  render_inline(CardComponent.new(title: "Hello"))
  failed = assert_raises("AssertionFailed") { assert_select "div.card > h2", text: "Bye" }
  assert_equal "Expected at least 1 element matching \"div.card > h2\" with text \"Bye\", found 0.\nHTML (first 500 characters):\n" \
               "<div class=\"card\"><h2>Hello</h2><p>0 pts</p></div>", failed
  assert_equal "assert_select: pseudo-classes are not supported (selector: \"h2:first-child\")",
               assert_raises("AssertionFailed") { assert_select "h2:first-child" }
  assert_equal "assert_select: sibling combinators (+ and ~) are not supported (selector: \"h2 + p\")",
               assert_raises("AssertionFailed") { assert_select "h2 + p" }
  assert_equal "assert_select: attribute operators other than = are not supported (selector: \"div[class^=c]\")",
               assert_raises("AssertionFailed") { assert_select "div[class^=c]" }
  assert_equal "assert_select: the nested block form is not supported (selector: \"div\")",
               assert_raises("AssertionFailed") { assert_select("div") { assert_select "h2" } }
  assert_equal "render_inline: pass the content as content:, not a block",
               assert_raises(ArgumentError) { render_inline(CardComponent.new(title: "x")) { "y" } }
  assert_equal "render_inline: pass a component or partial:, not neither", assert_raises(ArgumentError) { render_inline }
  assert_equal "render_inline: pass a component or partial:, not both",
               assert_raises(ArgumentError) { render_inline(CardComponent.new(title: "x"), partial: "articles/form") }
  assert_equal "render_inline: content: is for a component; a partial takes locals:",
               assert_raises(ArgumentError) { render_inline(partial: "articles/form", content: "x", locals: { article: Article.new(0, "") }) }
  render_inline(partial: "pages/broken")
  assert_equal "assert_select: the HTML could not be read: mismatched end tag </div> at byte 12 (open: <p>)\n" \
               "HTML (first 500 characters):\n<div><p>open</div>", assert_raises("AssertionFailed") { assert_select "p" }
end

Cybertrain::Test.run!
