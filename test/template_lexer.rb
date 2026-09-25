require "cybertrain/test"
require "cybertrain/template/lexer"

Lexer = Cybertrain::Template::Lexer

def kinds(tokens)
  tokens.map { |t| t.kind.to_s }.join(" ")
end

def texts(tokens)
  tokens.map { |t| t.text }
end

test "plain text is one text token" do
  tokens = Lexer.tokenize("hello\nworld\n", "t")
  assert_equal "text", kinds(tokens)
  assert_equal "hello\nworld\n", tokens[0].text
  assert_equal 1, tokens[0].line
end

test "empty source has no tokens" do
  assert_equal 0, Lexer.tokenize("", "t").size
end

test "all tag kinds" do
  tokens = Lexer.tokenize("a<%= x %>b<%== y %>c<% z %>d<%# note %>e", "t")
  assert_equal "text output text output_raw text code text comment text", kinds(tokens)
  assert_equal ["a", "x", "b", "y", "c", "z", "d", "note", "e"], texts(tokens)
end

test "tag code is stripped" do
  tokens = Lexer.tokenize("<%=   post.title   %>", "t")
  assert_equal "post.title", tokens[0].text
end

test "line numbers count newlines before each token" do
  tokens = Lexer.tokenize("one\n<%= a %>\ntwo\nthree <%= b %>\n\n<%= c\n  %>x<%= d %>", "t")
  lines = tokens.map { |t| "#{t.kind}:#{t.line}" }.join(" ")
  assert_equal "text:1 output:2 text:2 output:4 text:4 output:6 text:7 output:7", lines
end

test "a code tag alone on its line swallows its indentation and newline" do
  src = "<ul>\n  <% if x %>\n  <li>a</li>\n  <% end %>\n</ul>\n"
  tokens = Lexer.tokenize(src, "t")
  assert_equal "text code text code text", kinds(tokens)
  assert_equal ["<ul>\n", "if x", "  <li>a</li>\n", "end", "</ul>\n"], texts(tokens)
end

test "a comment tag alone on its line is trimmed like a code tag" do
  tokens = Lexer.tokenize("a\n  <%# c %>\nb\n", "t")
  assert_equal ["a\n", "c", "b\n"], texts(tokens)
end

test "output tags are never trimmed automatically" do
  tokens = Lexer.tokenize("  <%= x %>\nb", "t")
  assert_equal ["  ", "x", "\nb"], texts(tokens)
end

test "a code tag sharing its line with text is not trimmed" do
  tokens = Lexer.tokenize("a <% if x %>b\n", "t")
  assert_equal ["a ", "if x", "b\n"], texts(tokens)
end

test "explicit <%- -%> trimming" do
  tokens = Lexer.tokenize("a\n    <%- x -%>\nb\n", "t")
  assert_equal "text code text", kinds(tokens)
  assert_equal ["a\n", "x", "b\n"], texts(tokens)
  tokens = Lexer.tokenize("<p>\n  <%= y -%>\n</p>", "t")
  assert_equal ["<p>\n  ", "y", "</p>"], texts(tokens)
end

test "<%% is a literal <% and %%> inside a tag is a literal %>" do
  tokens = Lexer.tokenize("a <%% b %> c", "t")
  assert_equal "text", kinds(tokens)
  assert_equal "a <% b %> c", tokens[0].text
  tokens = Lexer.tokenize("<%= \"50%%>\" %>", "t")
  assert_equal "output", kinds(tokens)
  assert_equal "\"50%>\"", tokens[0].text
end

test "unterminated tag is a SyntaxError with the line" do
  msg = assert_raises("SyntaxError") { Lexer.tokenize("a\nb <%= x\n", "posts/show") }
  assert_equal "posts/show:2: unterminated <% tag", msg
end

test "locals comment on line 1 declares strict locals" do
  tokens = Lexer.tokenize("<%# locals: (post:, title:) %>\n<%= post %>", "t")
  assert_equal "comment output", kinds(tokens)
  assert Lexer.strict_locals?(tokens)
  assert_equal ["post", "title"], Lexer.strict_locals(tokens, "t")
end

test "empty locals comment means no locals are allowed" do
  tokens = Lexer.tokenize("<%# locals: () %>\nhi", "t")
  assert Lexer.strict_locals?(tokens)
  assert_equal 0, Lexer.strict_locals(tokens, "t").size
end

test "no locals comment is not strict" do
  tokens = Lexer.tokenize("<%# just a note %>\nhi", "t")
  refute Lexer.strict_locals?(tokens)
  assert_equal 0, Lexer.strict_locals(tokens, "t").size
  tokens = Lexer.tokenize("\n<%# locals: (a:) %>", "t")
  refute Lexer.strict_locals?(tokens)
end

test "malformed locals comment is a SyntaxError" do
  tokens = Lexer.tokenize("<%# locals: (post, x:) %>", "p/_form")
  msg = assert_raises("SyntaxError") { Lexer.strict_locals(tokens, "p/_form") }
  assert_equal "p/_form:1: bad strict locals entry 'post' (expected name:)", msg
end

Cybertrain::Test.run!
