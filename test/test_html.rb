# assert_select and the HTML reader behind it (spec section 9.2,
# acceptance 6): every selector form and option, each unsupported form's
# message, malformed HTML failing with its byte offset, the excerpt, and
# the reader on the HTML the framework writes and on odd but well-formed
# HTML. CRuby-runnable: it requires the harness, the reader and
# assert_select only, and sets Cybertrain::Test.last_html by hand (a
# render_inline or an integration request sets it in an application).
#
# Each block names its locals apart from every other block's (rule 63).
require "cybertrain/test"
require "cybertrain/test/select"

HTML = %(<div class="card big" id="c1"><h2>Hello <b>you</b></h2><ul><li>a</li><li data-x="1">b</li></ul>) +
       %(<a class="btn" href="/x?a=1&amp;b=2">go</a><form action="/articles"><input name="article[title]"></form></div>)
def html! = Cybertrain::Test.last_html = HTML

# The HTML a layout, form_with, a component and Turbo write (shapes copied
# from test/form_builder.rb, test/turbo_helpers.rb and the blog's layout).
PAGE = <<~HTML
  <!DOCTYPE html>
  <html lang="en">
    <head>
      <title>Blog &amp; more</title>
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <meta name="csrf-token" content="abc+/=">
      <link rel="stylesheet" href="/assets/application-1a2b.css">
      <script type="importmap">{"imports": {"a": "/a.js"}}</script>
      <script>if (1 < 2 && "</p>") { document.title = "<b>"; }</script>
      <style>p > b { color: red; } a[href^="/x"] { }</style>
    </head>
    <body>
      <header class="brand"><a href="/">Blog</a></header>
      <main>
        <p class="notice">Saved &mdash; ok</p>
        <turbo-frame id="article_3" src="/x?a=1&amp;b=2" loading="lazy" target="_top"><b>in</b></turbo-frame>
        <turbo-stream action="replace" target="article_3"><template><p>T &amp; U</p></template></turbo-stream>
        <form action="/posts/7" method="post" class="edit"><input type="hidden" name="_method" value="patch"><input type="hidden" name="authenticity_token" value="t0k=="><label for="post_title" class="field_with_errors">Title</label><input type="text" name="post[title]" id="post_title" value="A &quot;quoted&quot; &lt;title&gt;" class="wide field_with_errors"><textarea name="post[body]" id="post_body">
  </textarea><input type="checkbox" name="post[published]" id="post_published" value="1"><input type="submit" name="commit" value="Update Post"></form>
        <div class="comment" id="comment_7"><p><strong>Ann</strong> wrote:</p><p>Nice   post,
          really.</p><form class="button_to" method="post" action="/articles/3/comments/7"><input type="hidden" name="_method" value="delete"><button type="submit">Delete</button></form></div>
        <svg viewBox="0 0 10 10"><path d="M0 0L10 10"/><circle r="1"/></svg>
      </main>
    </body>
  </html>
HTML

test "every selector form" do
  html!
  assert_equal 1, assert_select("h2").size
  assert_select "div.card"; assert_select "#c1"; assert_select "[data-x]"; assert_select "li[data-x=\"1\"]"; assert_select "li[data-x='1']"
  assert_select "a.btn[href=\"/x?a=1&b=2\"]"
  assert_select "ul li", count: 2; assert_select "div > h2"; assert_select "div > li", count: 0
  assert_select "h1, h2", count: 1
  assert_select "form[action=\"/articles\"] input[name=\"article[title]\"]"
end

test "more selector forms: compounds, chains, lists, the universal tag and spacing" do
  html!
  assert_select "div.card.big#c1"
  assert_select "div.big.card", count: 1
  assert_select ".card.small", count: 0
  assert_select "#c1 > ul > li", count: 2
  assert_select "div ul > li[data-x]", count: 1
  assert_select "div   >   h2"
  assert_select "div>h2"
  assert_select "li[data-x=1]"
  assert_select "li[ data-x = \"1\" ]"
  assert_select "*", count: 9
  assert_select "ul > *", count: 2
  assert_select "li, li[data-x], h2", count: 3
  assert_select "h2 b", count: 1
  assert_select "h2 > b", count: 1
  assert_select "div > b", count: 0
  assert_select "DIV.card", count: 1
  assert_select "[DATA-X]", count: 1
  # Class and id are case-sensitive, as in HTML.
  assert_select ".Card", count: 0
  assert_select "#C1", count: 0
  # [class="card"] compares the whole value; .card one word of it.
  assert_select "[class=\"card\"]", count: 0
  assert_select "[class=\"card big\"]", count: 1
  # A value holding ], > and a comma, and an escaped quote.
  Cybertrain::Test.last_html = %(<i data-v="a], b > c"></i><i data-v='say "hi"'></i>)
  assert_select "i[data-v=\"a], b > c\"]", count: 1
  assert_select "i[data-v=\"say \\\"hi\\\"\"]", count: 1
end

test "the answer is the matched elements, in document order, each once" do
  html!
  matched = assert_select("li, ul li, [data-x]")
  assert_equal ["a", "b"], matched.map(&:node_text)
  assert_equal "1", matched[1].node_attr("data-x")
  assert_equal "", matched[0].node_attr("data-x")
  assert_equal "<li data-x=\"1\">b</li>", matched[1].node_html
  assert_equal "li", matched[0].node_tag
end

test "options and the positional second argument" do
  html!
  assert_select "li", minimum: 1, maximum: 2
  assert_select "h2", text: "Hello you"; assert_select "h2", text: /Hel+o/
  assert_select "h2", "Hello you"; assert_select "li", 2; assert_select "table", false
  assert_equal "Expected exactly 3 elements matching \"li\", found 2.\nHTML (first 500 characters):\n#{HTML[0, 500]}",
               assert_raises("AssertionFailed") { assert_select "li", count: 3 }
end

test "each option failing, with its message" do
  html!
  excerpt = "\nHTML (first 500 characters):\n#{HTML[0, 500]}"
  assert_equal "Expected at least 1 element matching \"h1\", found 0.#{excerpt}", assert_raises("AssertionFailed") { assert_select "h1" }
  assert_equal "Expected at least 1 element matching \"h2\" with text \"Hello\", found 0.#{excerpt}",
               assert_raises("AssertionFailed") { assert_select "h2", text: "Hello" }
  assert_equal "Expected at least 1 element matching \"h2\" with text /^you/, found 0.#{excerpt}",
               assert_raises("AssertionFailed") { assert_select "h2", text: /^you/ }
  assert_equal "Expected at least 3 elements matching \"li\", found 2.#{excerpt}", assert_raises("AssertionFailed") { assert_select "li", minimum: 3 }
  assert_equal "Expected at most 1 element matching \"li\", found 2.#{excerpt}", assert_raises("AssertionFailed") { assert_select "li", maximum: 1 }
  assert_equal "Expected between 3 and 4 elements matching \"li\", found 2.#{excerpt}",
               assert_raises("AssertionFailed") { assert_select "li", minimum: 3, maximum: 4 }
  assert_equal "Expected exactly 0 elements matching \"li\", found 2.#{excerpt}", assert_raises("AssertionFailed") { assert_select "li", false }
  assert_equal "Expected exactly 1 element matching \"li\", found 2.#{excerpt}", assert_raises("AssertionFailed") { assert_select "li", 1 }
  assert_equal "Expected at least 1 element matching \"li\" with text \"c\", found 0.#{excerpt}", assert_raises("AssertionFailed") { assert_select "li", "c" }
  assert_equal "Expected exactly 2 elements matching \"li\" with text \"a\", found 1.#{excerpt}",
               assert_raises("AssertionFailed") { assert_select "li", count: 2, text: "a" }
  assert_select "li", true
  assert_select "li", /\Ab\z/
  assert_select "li", count: 1, text: "a"
  assert_equal ["b"], assert_select("li", text: /b/).map(&:node_text)
end

test "text: collapses whitespace and strips; a Regexp sees the same text" do
  Cybertrain::Test.last_html = "<p>\n  Nice   post,\n\t really.  </p><p>a&nbsp;b</p>"
  assert_select "p", text: "Nice post, really."
  assert_select "p", text: /\ANice post, really\.\z/
  assert_select "p", text: "Nice   post,", count: 0
  # A no-break space is not whitespace to collapse.
  assert_select "p", text: "a b"
  assert_equal "Nice post, really.", Cybertrain::Test.squished_text(" Nice \n post,\r\n\freally. ")
  assert_equal "", Cybertrain::Test.squished_text(" \n ")
end

test "the excerpt is the first 500 characters" do
  long = "<p>#{"é" * 600}</p>"
  Cybertrain::Test.last_html = long
  failed_long = assert_raises("AssertionFailed") { assert_select "h1" }
  assert_equal "Expected at least 1 element matching \"h1\", found 0.\nHTML (first 500 characters):\n<p>#{"é" * 497}", failed_long
  Cybertrain::Test.last_html = ""
  assert_equal "Expected at least 1 element matching \"p\", found 0.\nHTML (first 500 characters):\n",
               assert_raises("AssertionFailed") { assert_select "p" }
end

test "each unsupported form fails with its message" do
  html!
  assert_equal "assert_select: pseudo-classes are not supported (selector: \"li:first-child\")", assert_raises("AssertionFailed") { assert_select "li:first-child" }
  assert_equal "assert_select: pseudo-classes are not supported (selector: \"li:not(.a)\")", assert_raises("AssertionFailed") { assert_select "li:not(.a)" }
  assert_equal "assert_select: pseudo-classes are not supported (selector: \"p::before\")", assert_raises("AssertionFailed") { assert_select "p::before" }
  assert_equal "assert_select: sibling combinators (+ and ~) are not supported (selector: \"h2 + ul\")", assert_raises("AssertionFailed") { assert_select "h2 + ul" }
  assert_equal "assert_select: sibling combinators (+ and ~) are not supported (selector: \"h2+ul\")", assert_raises("AssertionFailed") { assert_select "h2+ul" }
  assert_equal "assert_select: sibling combinators (+ and ~) are not supported (selector: \"h2 ~ ul\")", assert_raises("AssertionFailed") { assert_select "h2 ~ ul" }
  assert_equal "assert_select: attribute operators other than = are not supported (selector: \"a[href^=\\\"/x\\\"]\")",
               assert_raises("AssertionFailed") { assert_select "a[href^=\"/x\"]" }
  assert_equal "assert_select: attribute operators other than = are not supported (selector: \"a[href*=\\\"x\\\"]\")",
               assert_raises("AssertionFailed") { assert_select "a[href*=\"x\"]" }
  assert_equal "assert_select: attribute operators other than = are not supported (selector: \"a[class~=btn]\")",
               assert_raises("AssertionFailed") { assert_select "a[class~=btn]" }
  assert_equal "assert_select: attribute operators other than = are not supported (selector: \"a[href$=\\\"2\\\"]\")",
               assert_raises("AssertionFailed") { assert_select "a[href$=\"2\"]" }
  assert_equal "assert_select: attribute operators other than = are not supported (selector: \"a[lang|=en]\")",
               assert_raises("AssertionFailed") { assert_select "a[lang|=en]" }
  assert_equal "assert_select: attribute flags are not supported (selector: \"a[class=\\\"BTN\\\" i]\")",
               assert_raises("AssertionFailed") { assert_select "a[class=\"BTN\" i]" }
  assert_equal "assert_select: namespaces are not supported (selector: \"svg|a\")", assert_raises("AssertionFailed") { assert_select "svg|a" }
  assert_equal "assert_select: substitution values (?) are not supported (selector: \"li[data-x=?]\")",
               assert_raises("AssertionFailed") { assert_select "li[data-x=?]" }
  assert_equal "assert_select: the nested block form is not supported (selector: \"ul\")",
               assert_raises("AssertionFailed") { assert_select("ul") { assert_select "li" } }
end

test "a selector that is not one fails rather than matching nothing" do
  html!
  ["", " ", "div >", "> div", "div,", ",div", "div, ,p", "div > > p", "[", "[x", "[x=]", "[x=\"1\"", "[=1]", "div.", "#", "p*", "*p", "h2(", "li[x=\"1\"]x="].each do |bad|
    assert_equal "assert_select: invalid selector #{bad.inspect}", assert_raises("AssertionFailed") { assert_select bad }
  end
end

test "a wrong second argument is refused" do
  html!
  assert_includes assert_raises(ArgumentError) { assert_select "li", 1.5 }, "must be a String, a Regexp, an Integer, true or false"
  assert_includes assert_raises(ArgumentError) { assert_select "li", "a", text: "b" }, "give the text once"
end

test "real-world well-formed HTML" do
  Cybertrain::Test.last_html = %(<DIV title="a > b"><script>var s = "</div>";</script><br/><input type="text"><!-- <p> --><textarea><b></textarea></DIV>)
  assert_select "div[title=\"a > b\"]"; assert_select "textarea", text: "<b>"; assert_select "p", false
  assert_select "b", false
  assert_select "script", text: "var s = \"</div>\";"
  assert_select "div > input[type=text]"
end

test "the framework's own page: layout, form_with, a component, Turbo, svg" do
  Cybertrain::Test.last_html = PAGE
  assert_select "html[lang=en] > head > title", text: "Blog & more"
  assert_select "meta[name=\"csrf-token\"][content=\"abc+/=\"]"
  assert_select "head > script", count: 2
  assert_select "head > style", text: /p > b/
  # Tags inside script / style are text, not elements.
  assert_select "b", count: 1
  assert_select "p.notice", text: "Saved — ok"
  assert_select "turbo-frame#article_3[src=\"/x?a=1&b=2\"][loading=lazy] > b", text: "in"
  assert_select "turbo-stream[action=replace][target=article_3] > template > p", text: "T & U"
  assert_select "form.edit[action=\"/posts/7\"] > input[name=_method][value=patch]"
  assert_select "form.edit input[name=\"post[title]\"][value='A \"quoted\" <title>']"
  assert_select "input.field_with_errors.wide#post_title"
  assert_select "textarea#post_body", text: ""
  assert_select "label[for=post_title]", "Title"
  assert_select "input[type=submit][value=\"Update Post\"]"
  assert_select "div.comment#comment_7 > p", count: 2
  assert_select "div.comment > p", text: "Nice post, really."
  assert_select "div.comment strong", "Ann"
  assert_select "form.button_to[action=\"/articles/3/comments/7\"] button[type=submit]", "Delete"
  assert_select "svg > path[d=\"M0 0L10 10\"]"
  assert_select "svg > circle"
  assert_select "main > *", count: 6
  assert_select "body > main > form > input", count: 5
end

test "odd but well-formed HTML: unquoted, valueless and repeated attributes, entities, nesting, case, non-ASCII" do
  Cybertrain::Test.last_html = %(<P CLASS=a ID=x Data-Y=1 hidden data-z = "2" class="b">x &lt; y &gt; z &quot;q&quot; &#39;s&#39; &#x41;&#66; &amp;amp; &unknown; & a&b;</P>) +
                               %(<div><div><div class="in">deep</div></div></div><p title="日本語">ロシア &copy; café</p><input disabled value=v/1>)
  assert_select "p.a#x[data-y=\"1\"][hidden][data-z=\"2\"]"
  # The first of a repeated attribute wins, as in HTML.
  assert_select "p.b", count: 0
  assert_select "p#x", text: "x < y > z \"q\" 's' AB &amp; &unknown; & a&b;"
  assert_select "div", count: 3
  assert_select "div div div.in", count: 1
  assert_select "div > div > div", count: 1
  assert_select "div div", count: 2
  assert_select "p[title=\"日本語\"]", text: "ロシア © café"
  assert_select "input[disabled][value=\"v/1\"]"
  assert_select "[title=日本語]"
end

test "the reader's nodes: tag, attributes, text, html, children, parent" do
  read = Cybertrain::Test::HtmlReader.parse(%(<ul id="l"><li>a <b>1</b></li><!-- x --><li class="c">b</li></ul><br>t))
  assert_equal ["ul", "li", "b", "li", "br"], read.map(&:node_tag)
  assert_equal [-1, 0, 1, 0, -1], read.map(&:node_parent_index)
  assert_equal [0, 1, 2, 3, 4], read.map(&:node_index)
  assert_equal ["li", "li"], read[0].node_children.map(&:node_tag)
  assert_equal "a 1b", read[0].node_text
  assert_equal "<li>a <b>1</b></li>", read[1].node_html
  assert_equal "<br>", read[4].node_html
  assert_equal "", read[4].node_text
  assert_equal "c", read[3].node_attr("class")
  assert_equal "c", read[3].node_attr("CLASS")
  assert read[3].node_attr?("class")
  refute read[1].node_attr?("class")
  assert_equal ["id"], read[0].node_attr_names
  assert_equal 0, Cybertrain::Test::HtmlReader.parse("").size
  assert_equal 0, Cybertrain::Test::HtmlReader.parse("just text < 3 </ > &amp;").size
  assert_equal "a & b <c>", Cybertrain::Test::HtmlReader.decode_references("a &amp; b &lt;c&gt;")
  assert_equal "��&#xZZ;&#;", Cybertrain::Test::HtmlReader.decode_references("&#0;&#xD800;&#xZZ;&#;")
end

test "a malformed document fails with the byte offset" do
  Cybertrain::Test.last_html = "<div><p>x</div>"
  assert_includes assert_raises("AssertionFailed") { assert_select "p" }, "mismatched end tag </div> at byte 9 (open: <p>)"
end

test "each malformed shape fails with its offset, and the excerpt" do
  {
    "<div><p>x</div>" => "mismatched end tag </div> at byte 9 (open: <p>); HTML lets a page omit </p>, but this reader does not repair: write it",
    "<p>x</p></p>" => "unexpected end tag </p> at byte 8 (open: none)",
    "<ul><li>a</ul>" => "mismatched end tag </ul> at byte 9 (open: <li>); HTML lets a page omit </li>, but this reader does not repair: write it",
    "<div><p>x</p>" => "missing end tag </div> for <div> opened at byte 0",
    "<p>a<p>b</p>" => "missing end tag </p> for <p> opened at byte 0; HTML lets a page omit </p>, but this reader does not repair: write it",
    "<p><!-- x </p>" => "unterminated comment at byte 3",
    "<p class=\"a>x</p>" => "unterminated attribute value (class) in <p at byte 0",
    "<p class=a" => "unterminated tag <p at byte 0",
    "<p>x</p" => "unterminated end tag </p at byte 4",
    "<!DOCTYPE html" => "unterminated declaration at byte 0",
    "<div/><p>x</p>" => "self-closing <div/> at byte 0: only void elements (and svg / math content) close themselves; write <div></div>",
    "<script>x" => "missing end tag </script> for <script> opened at byte 0",
    "é<b>x</i>" => "mismatched end tag </i> at byte 6 (open: <b>)"
  }.each do |bad_html, problem|
    Cybertrain::Test.last_html = bad_html
    assert_equal "assert_select: the HTML could not be read: #{problem}\nHTML (first 500 characters):\n#{bad_html}",
                 assert_raises("AssertionFailed") { assert_select "p" }
  end
  # The reader itself raises Malformed.
  assert_equal "mismatched end tag </div> at byte 9 (open: <p>); HTML lets a page omit </p>, but this reader does not repair: write it",
               assert_raises(Cybertrain::Test::HtmlReader::Malformed) { Cybertrain::Test::HtmlReader.parse("<div><p>x</div>") }
end

test "a test that rendered nothing fails, whatever the last test left" do
  assert_equal false, Cybertrain::Test.last_html?
  assert_equal "", Cybertrain::Test.last_html
  assert_equal Cybertrain::Test::NOTHING_RENDERED, assert_raises("AssertionFailed") { assert_select "form", false }
  assert_equal "assert_select: No response yet. Request a page or call render_inline first.",
               assert_raises("AssertionFailed") { assert_select "div.error", count: 0 }
  # An unsupported selector is still named first.
  assert_includes assert_raises("AssertionFailed") { assert_select "p:first-child" }, "pseudo-classes are not supported"
  # A render or request in the same test (here: what they set) is read.
  Cybertrain::Test.last_html = "<h1>Welcome</h1><p class=notice>Saved</p>"
  assert Cybertrain::Test.last_html?
  assert_select "form", false
  assert_select "p.notice", "Saved"
end

test "the next test does not see the previous test's HTML" do
  assert_equal false, Cybertrain::Test.last_html?
  assert_equal Cybertrain::Test::NOTHING_RENDERED, assert_raises("AssertionFailed") { assert_select "p.notice", "Saved" }
  # A case driven by hand inside this one leaves this one's HTML alone.
  Cybertrain::Test.last_html = "<p>outer</p>"
  inner = Cybertrain::Test::Case.new("inner", -> { nil }, Cybertrain::Test::TopLevelFile.new(""))
  Cybertrain::Test.run_top_level_case(inner)
  assert_select "p", "outer"
end

test "empty comments, CDATA in svg, references beyond the basic five" do
  Cybertrain::Test.last_html = "<!--><p>x</p><!-- y --><!---><p>z</p><!---->"
  assert_select "p", count: 2
  Cybertrain::Test.last_html = "<svg><text><![CDATA[a > b <c>]]></text></svg><div><![CDATA[x > y]]></div>"
  assert_select "svg text", text: "a > b <c>"
  assert_select "c", false
  # Outside svg / math, CDATA is a bogus comment up to its first `>`.
  assert_select "div", text: "y]]>"
  Cybertrain::Test.last_html = "<p>K&ouml;ln &Eacute;t&eacute; &hearts; &check; &AMP; &#x80;&#x81; &yuml;&iexcl;</p>"
  assert_select "p", text: "Köln Été ♥ ✓ & €\u0081 ÿ¡"
  assert_equal "&nosuch; &hearts", Cybertrain::Test::HtmlReader.decode_references("&nosuch; &hearts")
end

test "count options given twice, negative or crossed are refused" do
  html!
  assert_includes assert_raises(ArgumentError) { assert_select "li", 2, count: 5 }, "give the count once, as the second argument (2) or as count:"
  assert_includes assert_raises(ArgumentError) { assert_select "li", false, minimum: 1 }, "give the count once, as the second argument (false)"
  assert_includes assert_raises(ArgumentError) { assert_select "li", true, maximum: 1 }, "give the count once"
  assert_equal "assert_select: count: must be 0 or more, got -1", assert_raises(ArgumentError) { assert_select "li", count: -1 }
  assert_equal "assert_select: minimum: must be 0 or more, got -2", assert_raises(ArgumentError) { assert_select "li", minimum: -2 }
  assert_equal "assert_select: count: must be 0 or more, got -3", assert_raises(ArgumentError) { assert_select "li", -3 }
  assert_equal "assert_select: minimum: 3 is above maximum: 2", assert_raises(ArgumentError) { assert_select "li", minimum: 3, maximum: 2 }
  # Text positionally and a count as options is fine.
  assert_select "li", "a", count: 1
end

test "a Regexp against text that is not UTF-8 fails the assertion" do
  Cybertrain::Test.last_html = "<p>a\xFFb</p>".dup.force_encoding("UTF-8")
  assert_equal "assert_select: the text of <p> at byte 0 is not valid UTF-8; a Regexp cannot match it",
               assert_raises("AssertionFailed") { assert_select "p", text: /a/ }
  assert_select "p", count: 1
end

test "selector messages: CSS escapes, and a flag only where a flag stands" do
  html!
  assert_equal "assert_select: CSS escapes (\\) are not supported (selector: \".md\\\\:flex\")", assert_raises("AssertionFailed") { assert_select ".md\\:flex" }
  assert_equal "assert_select: CSS escapes (\\) are not supported (selector: \"[a\\\\:b]\")", assert_raises("AssertionFailed") { assert_select "[a\\:b]" }
  assert_equal "assert_select: attribute flags are not supported (selector: \"a[class=btn s]\")", assert_raises("AssertionFailed") { assert_select "a[class=btn s]" }
  assert_equal "assert_select: invalid selector \"p[data-x=a b]\"", assert_raises("AssertionFailed") { assert_select "p[data-x=a b]" }
  assert_equal "assert_select: invalid selector \"p[data-x=\\\"a\\\" in]\"", assert_raises("AssertionFailed") { assert_select "p[data-x=\"a\" in]" }
end

test "the trees that differ from a browser's, as documented" do
  Cybertrain::Test.last_html = "<p><div>x</div></p><table><tr><td>1</td></tr></table>"
  assert_select "p > div", count: 1
  assert_select "table > tr", count: 1
  assert_select "table > tbody > tr", count: 0
end

Cybertrain::Test.run!
