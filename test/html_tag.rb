require "cybertrain/test"
require "cybertrain/html"

# Cybertrain::Html.tag and the helpers built on it (safe_join, class_names,
# dom_id). Pure Ruby: runs under CRuby (`ruby -I. test/html_tag.rb`) and
# Spinel alike.

Html = Cybertrain::Html
SafeString = Cybertrain::SafeString

# Answers what Html.dom_id asks of a record (a Cybertrain::Model does too).
class FakeRecord
  def initialize(model_name, id)
    @model_name = model_name
    @id = id
  end

  def model_name = @model_name
  def id = @id
  def new_record? = @id == 0
end

test "an element with no content, a void element" do
  assert_equal "<div></div>", Html.tag("div").to_s
  assert_equal "<br>", Html.tag("br").to_s
  assert_equal "<input type=\"text\" name=\"q\">", Html.tag("input", { type: "text", name: "q" }).to_s
  assert_equal "br is a void element", assert_raises("RuntimeError") { Html.tag("br", {}, "x") }
  assert_equal "img is a void element", assert_raises("RuntimeError") { Html.tag("img") { "x" } }
  assert_equal true, Html::VOID_ELEMENTS.size == 13
  assert Html.tag("p").html_safe?
end

test "attributes: nil and false drop, true is bare, Arrays join, data and aria nest" do
  attrs = { href: "/x?a=1&b=2", class: ["btn", nil, "big"], disabled: true, hidden: false, title: nil,
            data: { turbo_frame: "f", id: 3, turbo: true, off: false, gone: nil }, aria: { label: "x" } }
  expected = "<a href=\"/x?a=1&amp;b=2\" class=\"btn big\" disabled data-turbo-frame=\"f\" data-id=\"3\" data-turbo=\"true\" data-off=\"false\" aria-label=\"x\">Go</a>"
  assert_equal expected, Html.tag("a", attrs, "Go").to_s
  assert_equal " id=\"a\" data-x-y=\"1\"", Html.tag_attributes({ id: "a", data: { x_y: 1 } })
  assert_equal "", Html.tag_attributes({})
end

test "attribute values are always escaped, SafeStrings too" do
  assert_equal "<i title=\"&lt;b&gt; &amp; &quot;q&quot;\"></i>", Html.tag("i", { title: SafeString.of("<b> & \"q\"") }).to_s
  assert_equal "<i title=\"&#39;\"></i>", Html.tag("i", { "title" => "'" }).to_s
end

test "content is escaped; a SafeString content and a block's SafeString are not" do
  assert_equal "<p>&lt;b&gt;</p>", Html.tag("p", {}, "<b>").to_s
  assert_equal "<p><b>x</b></p>", Html.tag("p", {}, SafeString.of("<b>x</b>")).to_s
  assert_equal "<p>7</p>", Html.tag("p", {}, 7).to_s
  assert_equal "<div><b></div>", Html.tag("div") { SafeString.of("<b>") }.to_s
  assert_equal "<div>&lt;b&gt;</div>", Html.tag("div") { "<b>" }.to_s
  assert_equal "<div class=\"c\">block</div>", Html.tag("div", { class: "c" }, "content") { "block" }.to_s
  assert_equal "<script>alert(1)&lt;/script&gt;</script>", Html.tag("script", {}, "alert(1)</script>").to_s
end

test "element and attribute names are checked" do
  assert_equal "invalid element name 'Div'", assert_raises("ArgumentError") { Html.tag("Div") }
  assert_equal "invalid element name 'div x'", assert_raises("ArgumentError") { Html.tag("div x") }
  assert_equal "invalid element name ''", assert_raises("ArgumentError") { Html.tag("") }
  assert_equal "<my-widget-2></my-widget-2>", Html.tag("my-widget-2").to_s
  assert_equal "invalid attribute name 'on click'", assert_raises("ArgumentError") { Html.tag("div", { "on click" => "x" }) }
  assert_equal "invalid attribute name 'x\"'", assert_raises("ArgumentError") { Html.tag("div", { "x\"" => "1" }) }
  assert_equal "invalid attribute name 'data-a b'", assert_raises("ArgumentError") { Html.tag("div", { data: { "a b" => 1 } }) }
  assert_equal "<div onclick=\"x\" xml:lang=\"en\" _a.b=\"1\"></div>", Html.tag("div", { "onclick" => "x", "xml:lang" => "en", "_a.b" => "1" }).to_s
end

test "safe_join escapes what is not safe" do
  assert_equal "&lt;a&gt;, <b>", Html.safe_join(["<a>", SafeString.of("<b>")], ", ").to_s
  assert_equal "1<br>2", Html.safe_join([1, 2], SafeString.of("<br>")).to_s
  assert_equal "a&amp;&amp;b", Html.safe_join(["a", nil, "b"], "&").to_s
  assert_equal "", Html.safe_join([]).to_s
  assert Html.safe_join(["x"]).html_safe?
end

test "class_names" do
  assert_equal "a b c", Html.class_names("a", ["b", nil], { "c" => true, "d" => false }, "")
  assert_equal "a b", Html.class_names("a  b", "a", :b, nil, false)
  assert_equal "", Html.class_names
  assert_equal "x y", Html.class_names_of(["x", ["y", ["x"]]])
end

test "dom_id" do
  assert_equal "article_12", Html.dom_id(FakeRecord.new("Article", 12))
  assert_equal "new_article", Html.dom_id(FakeRecord.new("Article", 0))
  assert_equal "edit_article_12", Html.dom_id(FakeRecord.new("Article", 12), "edit")
  assert_equal "edit_article", Html.dom_id(FakeRecord.new("Article", 0), "edit")
  assert_equal "blog_post_3", Html.dom_id(FakeRecord.new("BlogPost", 3))
  assert_equal "admin_user_4", Html.dom_id(FakeRecord.new("Admin::User", 4))
end

test "the tag builder prints as nothing" do
  assert_equal "", Html::TAG_BUILDER.to_s
end

test "class Hashes and Arrays go through class_names; other Hashes are refused" do
  assert_equal "<i class=\"a\"></i>", Html.tag("i", { class: { "a" => true, "b" => nil } }).to_s
  assert_equal "attribute 'style' cannot be a Hash", assert_raises("ArgumentError") { Html.tag("i", { style: { "a" => 1 } }) }
end

Cybertrain::Test.run!
