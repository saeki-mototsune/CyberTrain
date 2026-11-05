require "cybertrain/test"
require "cybertrain/template"
require "cybertrain/template/helpers"

# The `tag` builder and the content_tag, safe_join, class_names and dom_id
# helpers in templates (docs/guide/template-language.md, "The tag builder").
# cybertrain/model links SQLite through FFI, so this program only runs
# compiled: its snapshot comes from the binary (spikes/NOTES.md rule 23).

class TagArticle < Cybertrain::Model
  def initialize(id)
    super()
    set_id(id)
    mark_persisted! if id > 0
  end

  def model_name = "Article"
end

def render_tag(src, env)
  template = Cybertrain::Template::Template.parse(src, "items/tag")
  Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil)).render(template, env)
end

# A Hash<String, value>, as every template environment.
def tag_env
  env = {}
  env["name"] = "<Ann>"
  env["article"] = TagArticle.new(12)
  env["draft"] = TagArticle.new(0)
  env["bad"] = { "a b" => 1 }
  env["items"] = ["x", "<y>"]
  env
end

def tag_runtime_error(src)
  assert_raises("Cybertrain::Template::RuntimeError") { render_tag(src, tag_env) }
end

test "tag with a do block captures the block's output" do
  assert_equal "<div class=\"c\">hi &lt;Ann&gt;</div>", render_tag("<%= tag.div(class: \"c\") do %>hi <%= name %><% end %>", tag_env)
  assert_equal "<ul><li>x</li><li>&lt;y&gt;</li></ul>", render_tag("<%= tag.ul do %><% items.each do |i| %><%= tag.li i %><% end %><% end %>", tag_env)
  assert_equal "<p>&lt;Ann&gt;</p>", render_tag("<%= tag.p { name } %>", tag_env)
end

test "content, attributes, void and custom elements" do
  env = tag_env
  assert_equal "<span class=\"x\">t</span>", render_tag("<%= tag.span \"t\", class: \"x\" %>", env)
  assert_equal "<input type=\"text\" name=\"q\" disabled>", render_tag("<%= tag.input type: \"text\", name: \"q\", disabled: true, hidden: false %>", env)
  assert_equal "<path d=\"M0 0\"></path>", render_tag("<%= tag.path d: \"M0 0\" %>", env)
  assert_equal "<br>", render_tag("<%= tag.br %>", env)
  assert_equal "<my-widget data-turbo-frame=\"f\"></my-widget>", render_tag("<%= tag.my_widget data: { turbo_frame: \"f\" } %>", env)
  assert_equal "<b><i>x</i></b>", render_tag("<%= tag.b(tag.i(\"x\")) %>", env)
  assert_equal "items/tag:1: br is a void element", tag_runtime_error("<%= tag.br do %>x<% end %>")
  assert_equal "items/tag:1: tag.p takes at most one positional argument (the content)", tag_runtime_error("<%= tag.p(\"a\", \"b\") %>")
end

test "content is escaped and attribute names are checked" do
  env = tag_env
  assert_equal "<script>alert(1)&lt;/script&gt;</script>", render_tag("<%= tag.script(\"alert(1)</script>\") %>", env)
  assert_equal "<div onclick=\"x\"></div>", render_tag("<%= tag.div(onclick: \"x\") %>", env)
  assert_equal "items/tag:1: invalid attribute name 'data-a b'", tag_runtime_error("<%= tag.div(data: bad) %>")
  assert_raises("Cybertrain::Template::SyntaxError") { render_tag("<%= tag.div(\"on click\": \"x\") %>", env) }
end

test "content_tag" do
  env = tag_env
  assert_equal "<p class=\"n\">&lt;i&gt;</p>", render_tag("<%= content_tag \"p\", \"<i>\", class: \"n\" %>", env)
  assert_equal "<p>hi &lt;Ann&gt;</p>", render_tag("<%= content_tag :p do %>hi <%= name %><% end %>", env)
  assert_equal "<hr>", render_tag("<%= content_tag(:hr) %>", env)
end

test "safe_join, class_names, dom_id" do
  env = tag_env
  assert_equal "<b>a</b> &lt;", render_tag("<%= safe_join([tag.b(\"a\"), \"<\"], \" \") %>", env)
  assert_equal "x&lt;y&gt;", render_tag("<%= safe_join(items) %>", env)
  assert_equal "a b", render_tag("<%= class_names(\"a\", { b: true, c: false }) %>", env)
  assert_equal "<i class=\"a on\"></i>", render_tag("<%= tag.i(class: class_names(\"a\", { on: true })) %>", env)
  assert_equal "article_12 edit_article_12 new_article", render_tag("<%= dom_id(@article) %> <%= dom_id(@article, \"edit\") %> <%= dom_id(@draft) %>", env)
  assert_equal "<div id=\"article_12\"></div>", render_tag("<%= tag.div(id: dom_id(article)) %>", env)
  assert_equal "items/tag:1: dom_id expects a record, got x", tag_runtime_error("<%= dom_id(\"x\") %>")
end

Cybertrain::Test.run!
