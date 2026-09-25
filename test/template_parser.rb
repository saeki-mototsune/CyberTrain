require "cybertrain/test"
require "cybertrain/template/lexer"
require "cybertrain/template/parser"

Parser = Cybertrain::Template::Parser

def parse(src)
  nodes = Parser.parse(Cybertrain::Template::Lexer.tokenize(src, "t"), "t")
  Cybertrain::Template.sexp_list(nodes)
end

# The expression inside one <%= %> tag, as an s-expression.
def expr(src)
  parse("<%= #{src} %>").delete_prefix("(out ").delete_suffix(")")
end

test "text and output" do
  assert_equal "(text \"a\") (out x) (text \"b\") (raw y)", parse("a<%= x %>b<%== y %>")
end

test "comments produce no nodes" do
  assert_equal "(text \"a\")", parse("<%# note %>a")
  assert_equal "(text \"a\")", parse("<% # a Ruby comment %>a")
end

test "literals" do
  assert_equal "1", expr("1")
  assert_equal "1000", expr("1_000")
  assert_equal "2.5", expr("2.5")
  assert_equal "\"hi\"", expr("\"hi\"")
  assert_equal "\"it's\"", expr("'it\\'s'")
  assert_equal ":title", expr(":title")
  assert_equal "nil", expr("nil")
  assert_equal "true", expr("true")
  assert_equal "false", expr("false")
  assert_equal "[1 \"a\" :b]", expr("[1, \"a\", :b]")
  assert_equal "[]", expr("[]")
  assert_equal "{a: 1, b: \"x\"}", expr("{ a: 1, b: \"x\" }")
  assert_equal "(- 0 x)", expr("-x")
  assert_equal "-3", expr("-3")
end

test "string escapes and interpolation" do
  assert_equal "\"a\\nb\\\"c\"", expr("\"a\\nb\\\"c\"")
  assert_equal "(str \"Hello, \" (.name @user) \"!\")", expr("\"Hello, \#{@user.name}!\"")
  refute expr("'no \#{x}'").start_with?("(str")
  assert_equal "(str (+ a 1))", expr("\"\#{a + 1}\"")
end

test "variables" do
  assert_equal "@post", expr("@post")
  assert_equal "post", expr("post")
end

test "precedence: a + b * c" do
  assert_equal "(+ a (* b c))", expr("a + b * c")
  assert_equal "(* (+ a b) c)", expr("(a + b) * c")
  assert_equal "(- (- a b) c)", expr("a - b - c")
  assert_equal "(+ (% a b) (/ c d))", expr("a % b + c / d")
end

test "precedence: !x && y" do
  assert_equal "(&& (! x) y)", expr("!x && y")
  assert_equal "(|| a (&& b c))", expr("a || b && c")
  assert_equal "(! (.empty? x))", expr("!x.empty?")
end

test "precedence: a == b ? x : y" do
  assert_equal "(?: (== a b) \"x\" \"y\")", expr("a == b ? \"x\" : \"y\"")
  assert_equal "(&& (== a 1) (< b 2))", expr("a == 1 && b < 2")
  assert_equal "(!= (<= a b) (>= c d))", expr("a <= b != c >= d")
  assert_equal "(?: a b (?: c d e))", expr("a ? b : c ? d : e")
end

test "method calls with args, kwargs and safe navigation" do
  assert_equal "(.title @post)", expr("@post.title")
  assert_equal "(.strftime (.created_at @post) \"%Y\")", expr("@post.created_at.strftime(\"%Y\")")
  assert_equal "(&.name (.author post))", expr("post.author&.name")
  assert_equal "(.empty? (.errors @post))", expr("@post.errors.empty?")
  assert_equal "(.link_to _ \"Show\" (.post_path _ post) class: \"btn\")", expr("link_to(\"Show\", post_path(post), class: \"btn\")")
  assert_equal "(.form_with _ model: @post url: \"/posts\")", expr("form_with(model: @post, url: \"/posts\")")
  assert_equal "(.csrf_meta_tags _)", expr("csrf_meta_tags()")
end

test "calls without parentheses" do
  assert_equal "(.link_to _ \"Show\" post)", expr("link_to \"Show\", post")
  assert_equal "(.text_field f :title class: \"wide\")", expr("f.text_field :title, class: \"wide\"")
  assert_equal "(.render _ \"form\" post: @post)", expr("render \"form\", post: @post")
  assert_equal "(.yield _ :title)", expr("yield :title")
  assert_equal "(.yield _)", expr("yield")
  assert_equal "(.pluralize _ (.size (.comments @post)) \"comment\")", expr("pluralize @post.comments.size, \"comment\"")
end

test "indexing" do
  assert_equal "([] params :id)", expr("params[:id]")
  assert_equal "([] (.errors @post) :title)", expr("@post.errors[:title]")
  assert_equal "(.first ([] h \"k\"))", expr("h[\"k\"].first")
end

test "each with one and two vars" do
  src = "<% @posts.each do |post| %><%= post.title %><% end %>"
  assert_equal "(each @posts |post| ((out (.title post))))", parse(src)
  src = "<% @counts.each do |name, n| %><%= name %>=<%= n %><% end %>"
  assert_equal "(each @counts |name, n| ((out name) (text \"=\") (out n)))", parse(src)
  src = "<% items.each_with_index do |item, i| %><%= i %><% end %>"
  assert_equal "(each_with_index items |item, i| ((out i)))", parse(src)
end

test "if / elsif / else" do
  src = "<% if a %>A<% elsif b %>B<% elsif c %>C<% else %>D<% end %>"
  assert_equal "(if a ((text \"A\")) (elsif b ((text \"B\"))) (elsif c ((text \"C\"))) (else (text \"D\")))", parse(src)
  assert_equal "(if (.any? x) ((text \"y\")))", parse("<% if x.any? %>y<% end %>")
end

test "unless / else" do
  assert_equal "(unless a ((text \"x\")) (else (text \"y\")))", parse("<% unless a %>x<% else %>y<% end %>")
end

test "nested blocks" do
  src = "<% if @posts.any? %>\n<% @posts.each do |p| %>\n<% if p.published %>*<% end %>\n<% end %>\n<% end %>\n"
  assert_equal "(if (.any? @posts) ((each @posts |p| ((if (.published p) ((text \"*\"))) (text \"\\n\")))))", parse(src)
end

test "block call" do
  src = "<%= form_with(model: @post) do |f| %><%= f.label :title %><% end %>"
  assert_equal "(block (.form_with _ model: @post) |f| ((out (.label f :title))))", parse(src)
  src = "<% content_for :title do %>Hi<% end %>"
  assert_equal "(block (.content_for _ :title) || ((text \"Hi\")))", parse(src)
end

test "statements and assignment" do
  assert_equal "(stmt (.touch x))", parse("<% x.touch %>")
  assert_equal "(= total 0) (out total)", parse("<% total = 0 %><%= total %>")
end

def syntax_error(src)
  assert_raises("SyntaxError") { Parser.parse(Cybertrain::Template::Lexer.tokenize(src, "posts/show"), "posts/show") }
end

test "syntax error: if without end" do
  assert_equal "posts/show:2: 'if' without 'end'", syntax_error("<p>\n<% if x %>\nyes\n")
  assert_equal "posts/show:1: 'each' without 'end'", syntax_error("<% xs.each do |x| %>")
end

test "syntax error: if without condition" do
  assert_equal "posts/show:3: 'if' without a condition", syntax_error("\n\n<% if %>x<% end %>")
end

test "syntax error: unknown token" do
  assert_equal "posts/show:2: unexpected character '$'", syntax_error("a\n<%= post.title $ 1 %>")
  assert_equal "posts/show:1: unexpected end of expression in 'a +'", syntax_error("<%= a + %>")
  assert_equal "posts/show:1: unexpected ')' in 'foo(1))'", syntax_error("<%= foo(1)) %>")
end

test "syntax error: stray end, else and elsif" do
  assert_equal "posts/show:1: 'end' without an opening block", syntax_error("<% end %>")
  assert_equal "posts/show:1: 'else' without 'if'", syntax_error("<% else %>")
  assert_equal "posts/show:1: 'elsif' without 'if'", syntax_error("<% xs.each do |x| %><% elsif y %><% end %>")
  assert_equal "posts/show:1: 'elsif' after 'else'", syntax_error("<% if a %><% else %><% elsif b %><% end %>")
end

test "syntax error: unsupported constructs" do
  assert_equal "posts/show:1: unterminated string", syntax_error("<%= \"abc %>")
  assert_equal "posts/show:1: constants are not supported: 'Time'", syntax_error("<%= Time.now %>")
  assert_equal "posts/show:1: blocks are only supported on each, each_with_index and helper calls", syntax_error("<% xs.map do |x| %><% end %>")
  assert_equal "posts/show:1: empty <%= %> tag", syntax_error("<%= %>")
end

Cybertrain::Test.run!
