require "cybertrain/test"
require "cybertrain/template"

# cybertrain/model links SQLite through FFI, so this program cannot run under
# CRuby: its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
#
# The models are hand-written Cybertrain::Model subclasses answering the
# generated hooks from case tables; nothing touches a database.

class Comment < Cybertrain::Model
  def initialize(author, body)
    super()
    @author = author
    @body = body
  end

  def model_name = "Comment"

  def read_attribute(name)
    case name
    when :id then @id
    when :author then @author
    when :body then @body
    else nil
    end
  end
end

class Post < Cybertrain::Model
  def initialize(id, title, body, created_at, comments)
    super()
    set_id(id)
    mark_persisted! if id > 0
    @title = title
    @body = body
    @created_at = created_at
    @comments = comments
  end

  def model_name = "Post"

  def read_attribute(name)
    case name
    when :id then @id
    when :title then @title
    when :body then @body
    when :created_at then @created_at
    else nil
    end
  end

  def read_association(name)
    case name
    when :comments then @comments
    else nil
    end
  end

  def call_view_method(name)
    case name
    when :summary then summary
    when :shouting then nil
    else nil
    end
  end

  def attribute_or_method?(name)
    case name
    when :id, :title, :body, :created_at, :comments, :summary, :shouting then true
    else false
    end
  end

  def summary = "#{@title[0, 5]}..."
end

# A value the interpreter has no method table for (Task 13's FormBuilder is
# one): calls on it go to HelperBase#call_object_method.
class Widget
  def label = "widget"
end

class TestHelpers < Cybertrain::Template::HelperBase
  def helper_call(name, args, kwargs, block, interp, env)
    case name
    when "raw" then Cybertrain::SafeString.new(interp.to_s_value(args[0]))
    when "shout" then interp.to_s_value(args[0]).upcase
    when "greet" then "Hello, #{interp.to_s_value(kwargs["name"])}#{interp.to_s_value(kwargs["punct"])}"
    when "count_args" then "#{args.size}/#{kwargs.size}"
    when "boom" then raise Cybertrain::Template::RuntimeError, "helper exploded"
    when "plain" then raise "plain runtime"
    when "arg_err" then raise ArgumentError, "bad argument"
    when "key_err" then raise KeyError, "key not found: :x"
    when "missing" then raise Cybertrain::Template::MissingTemplate, "Missing template posts/_nope.html.erb"
    when "bad_partial" then Cybertrain::Template::Template.parse("\n<% if x %>", "posts/_bad")
    when "widget" then Widget.new
    when "partial"
      partial = Cybertrain::Template::Template.parse(interp.to_s_value(args[0]), "posts/_row")
      Cybertrain::SafeString.new(interp.render(partial, env))
    when "wrap"
      if block.nil?
        "no block"
      else
        Cybertrain::SafeString.new("<div>#{interp.capture(block, env, "arg")}</div>")
      end
    else super(name, args, kwargs, block, interp, env)
    end
  end

  def call_object_method(recv, name_sym, name_str, args, kwargs)
    case recv
    when Widget
      case name_sym
      when :label then return recv.label
      when :explode then raise "widget broke"
      end
    end
    super(recv, name_sym, name_str, args, kwargs)
  end
end

def render(src, env = new_env)
  template = Cybertrain::Template::Template.parse(src, "posts/show")
  Cybertrain::Template::Interpreter.new(TestHelpers.new).render(template, env)
end

# Every template error is a Cybertrain::Template::RuntimeError carrying the
# template location, never a bare ::RuntimeError.
def runtime_error(src, env = new_env)
  assert_raises("Cybertrain::Template::RuntimeError") { render(src, env) }
end

# Every environment starts from new_env, a Hash<String, value>, and gets
# more keys assigned: a literal like { "s" => "x" } would be a
# Hash<String, String> and give the interpreter's env parameter a second
# static type.
def new_env
  env = {}
  env["title"] = "Hello"
  env["n"] = 7
  env["x"] = 2.5
  env["flag"] = true
  env["nothing"] = nil
  env
end

def with(env, key, value)
  env[key] = value
  env
end

T0 = Time.utc(2026, 9, 25, 14, 30, 5)

def sample_post
  comments = [Comment.new("ann", "First!"), Comment.new("bob", "<b>bold</b>")]
  Post.new(7, "Spinel & Ruby", nil, T0, comments)
end

test "literals" do
  assert_equal "1|2.5|str|sym||true|false", render("<%= 1 %>|<%= 2.5 %>|<%= 'str' %>|<%= :sym %>|<%= nil %>|<%= true %>|<%= false %>")
  assert_equal "-3|[1, &quot;a&quot;, nil]", render("<%= -3 %>|<%= [1, \"a\", nil] %>")
  assert_equal "2|1", render("<%= [1, 2].size %>|<%= { a: 1 }.size %>")
end

test "string interpolation" do
  assert_equal "Hello, world 8!", render("<%= \"\#{title}, world \#{n + 1}!\" %>", new_env)
  assert_equal "a&lt;b&gt;", render("<%= \"a\#{s}\" %>", with(new_env, "s", "<b>"))
end

test "ivar and lvar lookup" do
  env = new_env
  assert_equal "Hello Hello 7", render("<%= @title %> <%= title %> <%= @n %>", env)
  assert_equal "[]", render("[<%= @missing %>]", env)
end

test "an unknown local is a helper call" do
  assert_equal "0/0", render("<%= count_args %>")
  assert_equal "posts/show:1: undefined helper 'nope'", runtime_error("<%= nope %>")
end

test "arithmetic" do
  env = new_env
  assert_equal "9 5 14 3 1", render("<%= n + 2 %> <%= n - 2 %> <%= n * 2 %> <%= n / 2 %> <%= n % 2 %>", env)
  assert_equal "-4 -1", render("<%= -7 / 2 %> <%= 7 - 8 %>")
  assert_equal "9.5 5.0 1.25", render("<%= n + x %> <%= x * 2 %> <%= x / 2 %>", env)
  assert_equal "ab", render("<%= 'a' + 'b' %>")
  assert_equal "11", render("<%= 1 + 2 * 5 %>")
end

test "comparison" do
  env = new_env
  assert_equal "true false true true false", render("<%= n > 2 %> <%= n < 2 %> <%= n >= 7 %> <%= x <= 2.5 %> <%= 'b' < 'a' %>", env)
  assert_equal "true false true", render("<%= n == 7 %> <%= title == 'x' %> <%= nothing != 1 %>", env)
end

test "boolean operators and truthiness" do
  env = new_env
  assert_equal "7 false Hello", render("<%= flag && n %> <%= nothing && n || false %> <%= nothing || title %>", env)
  assert_equal "false true true", render("<%= !flag %> <%= !nothing %> <%= !false %>", env)
  assert_equal "yes", render("<% if 0 %>yes<% end %>")
  assert_equal "yes", render("<% if '' %>yes<% end %>")
  assert_equal "no", render("<% if nothing %>yes<% else %>no<% end %>", env)
  assert_equal "big", render("<%= n > 5 ? 'big' : 'small' %>", env)
end

test "if / elsif / else / unless" do
  src = "<% if n == 1 %>one<% elsif n == 7 %>seven<% else %>other<% end %>"
  assert_equal "seven", render(src, new_env)
  assert_equal "other", render(src, with(new_env, "n", 3))
  assert_equal "shown", render("<% unless nothing %>shown<% end %>", new_env)
  assert_equal "else", render("<% unless flag %>x<% else %>else<% end %>", new_env)
end

test "each over an Array" do
  env = with(new_env, "items", ["a", "<b>", "c"])
  assert_equal "[a][&lt;b&gt;][c]", render("<% items.each do |item| %>[<%= item %>]<% end %>", env)
  assert_equal "0:a 1:&lt;b&gt; 2:c ", render("<% items.each_with_index do |item, i| %><%= i %>:<%= item %> <% end %>", env)
  refute env.key?("item")
end

test "each over a Hash" do
  env = with(new_env, "counts", { "apples" => 3, "pears" => 0 })
  assert_equal "apples=3;pears=0;", render("<% counts.each do |name, n| %><%= name %>=<%= n %>;<% end %>", env)
end

test "block parameters shadow and are restored" do
  env = with(with(new_env, "item", "outer"), "items", [1, 2])
  assert_equal "12outer", render("<% items.each do |item| %><%= item %><% end %><%= item %>", env)
end

test "each on a non-collection is a RuntimeError" do
  assert_equal "posts/show:2: undefined method 'each' for Integer", runtime_error("\n<% n.each do |x| %><% end %>", new_env)
end

test "assignment" do
  assert_equal "3", render("<% total = 1 %><% total = total + 2 %><%= total %>")
end

test "a local first assigned inside a block is local to the block" do
  env = with(new_env, "list", [1, 2, 3])
  assert_equal "posts/show:1: undefined helper 'y'", runtime_error("<% list.each do |x| %><% y = x %><% end %><%= y %>", env)
  refute env.key?("y")
  # Fresh in every iteration, as in Ruby: the second pass sees nil.
  assert_equal "[set][][]", render("<% list.each do |x| %><% if x == 1 %><% z = 'set' %><% end %>[<%= z %>]<% end %>", env)
  # A local that exists before the block is the same variable inside it.
  assert_equal "6", render("<% sum = 0 %><% list.each do |x| %><% sum = sum + x %><% end %><%= sum %>", env)
  assert_equal "<div>1</div>", render("<%= wrap do |v| %><% w = 1 %><%= w %><% end %>", env)
  refute env.key?("w")
end

test "a Ruby comment filling a code tag is ignored" do
  assert_equal "ab", render("a<% # a comment %>b")
  assert_equal "ab", render("a<%   # indented %>b")
end

test "Time methods (Time before Array)" do
  env = with(with(new_env, "t", T0), "times", [T0])
  assert_equal "2026 9 25 14 30 5", render("<%= t.year %> <%= t.month %> <%= t.day %> <%= t.hour %> <%= t.min %> <%= t.sec %>", env)
  assert_equal "2026-09-25 14:30", render("<%= t.strftime('%Y-%m-%d %H:%M') %>", env)
  assert_equal "2026", render("<% times.each do |tt| %><%= tt.year %><% end %>", env)
  assert_equal "posts/show:1: undefined method 'first' for Time", runtime_error("<%= t.first %>", env)
end

test "String, Integer, Float, Array and Hash methods" do
  env = with(with(new_env, "s", "  Hi There "), "list", [3, 1, 2])
  env = with(with(env, "h", { "k" => "v" }), "e", [])
  assert_equal "hi there|HI THERE|Hi there|11", render("<%= s.strip.downcase %>|<%= s.strip.upcase %>|<%= s.strip.capitalize %>|<%= s.length %>", env)
  assert_equal "true true false 42", render("<%= s.include?('Hi') %> <%= s.strip.start_with?('Hi') %> <%= s.end_with?('x') %> <%= '42'.to_i %>", env)
  assert_equal "3 2 2|1|3 true false", render("<%= list.first %> <%= list.last %> <%= list.reverse.join('|') %> <%= list.include?(2) %> <%= e.any? %>", env)
  assert_equal "v v true 1 d", render("<%= h['k'] %> <%= h[:k] %> <%= h.key?(:k) %> <%= h.size %> <%= h.fetch('z', 'd') %>", env)
  assert_equal "true 5 3.0 3", render("<%= 0.zero? %> <%= -5.abs %> <%= 2.5.round.to_f %> <%= 2.6.floor + 1 %>", env)
  assert_equal "true false", render("<%= e.empty? %> <%= s.blank? %>", env)
end

test "safe navigation" do
  assert_equal "[]", render("[<%= nothing&.upcase %>]", new_env)
  assert_equal "HELLO", render("<%= title&.upcase %>", new_env)
end

test "Model dispatch: read_attribute, read_association, call_view_method" do
  env = with(new_env, "post", sample_post)
  assert_equal "Spinel &amp; Ruby", render("<%= @post.title %>", env)
  assert_equal "7 7 true false", render("<%= post.id %> <%= post.to_param %> <%= post.persisted? %> <%= post.new_record? %>", env)
  assert_equal "[]", render("[<%= post.body %>]", env)
  assert_equal "2025", render("<%= post.created_at.year - 1 %>", env)
  assert_equal "Spine...", render("<%= post.summary %>", env)
  assert_equal "[]", render("[<%= post.shouting %>]", env)
  src = "<% post.comments.each do |c| %><%= c.author %>: <%= c.body %>\n<% end %>"
  assert_equal "ann: First!\nbob: &lt;b&gt;bold&lt;/b&gt;\n", render(src, env)
  assert_equal "2", render("<%= post.comments.size %>", env)
end

test "errors.full_messages" do
  post = sample_post
  post.errors.add(:title, "can't be blank")
  post.errors.add(:body, "is too short")
  env = with(new_env, "post", post)
  src = "<% if post.errors.any? %><%= post.errors.count %>:<% post.errors.full_messages.each do |m| %> <%= m %>;<% end %><% end %>"
  assert_equal "2: Title can&#39;t be blank; Body is too short;", render(src, env)
  assert_equal "can&#39;t be blank true false", render("<%= post.errors[:title].first %> <%= post.errors.key?(:body) %> <%= post.errors.empty? %>", env)
end

test "Params lookup" do
  params = Cybertrain::Params.new
  params.set_value("q", "<spinel>")
  env = with(new_env, "params", params)
  assert_equal "&lt;spinel&gt; true false", render("<%= params[:q] %> <%= params.key?('q') %> <%= params.key?(:x) %>", env)
end

test "unknown method is a RuntimeError with the template line" do
  env = with(with(new_env, "post", sample_post), "s", "x")
  assert_equal "posts/show:3: undefined method 'bogus' for Post", runtime_error("a\nb\n<%= post.bogus %>", env)
  assert_equal "posts/show:1: undefined method 'shout' for String", runtime_error("<%= s.shout %>", env)
  assert_equal "posts/show:2: undefined method 'upcase' for nil", runtime_error("\n<%= post.body.upcase %>", env)
  assert_equal "posts/show:1: undefined operation String + Integer", runtime_error("<%= s + 1 %>", env)
  assert_equal "posts/show:1: comparison of String with Integer failed", runtime_error("<%= s < 1 %>", env)
  assert_equal "posts/show:1: divided by 0", runtime_error("<%= 1 / 0 %>", env)
end

test "helper errors get the template line" do
  assert_equal "posts/show:2: helper exploded", runtime_error("\n<%= boom %>")
end

test "any StandardError from a helper is relocated to the template line" do
  assert_equal "posts/show:2: plain runtime", runtime_error("\n<%= plain %>")
  assert_equal "posts/show:1: bad argument", runtime_error("<%= arg_err %>")
  assert_equal "posts/show:1: key not found: :x", runtime_error("<% key_err %>")
  assert_equal "posts/show:3: Missing template posts/_nope.html.erb", runtime_error("\n\n<%= missing %>")
  assert_equal "posts/show:1: plain runtime", runtime_error("<%= wrap do |v| %><%= plain %><% end %>")
end

test "a template SyntaxError from a helper keeps its own location" do
  msg = assert_raises("Cybertrain::Template::SyntaxError") { render("<%= bad_partial %>") }
  assert_equal "posts/_bad:2: 'if' without 'end'", msg
end

test "object methods go to the helpers and their errors are relocated" do
  assert_equal "widget", render("<%= widget.label %>")
  assert_equal "posts/show:2: widget broke", runtime_error("\n<%= widget.explode %>")
  assert_equal "posts/show:1: undefined method 'nope' for Widget", runtime_error("<%= widget.nope %>")
end

test "a helper can render another template on the same interpreter" do
  assert_equal "<p><b>Hello</b></p>", render("<p><%= partial '<b><%= title %%></b>' %></p>")
  assert_equal "posts/_row:1: undefined method 'bogus' for String", runtime_error("\n<%= partial '<%= title.bogus %%>' %>")
  assert_equal "posts/show:2: undefined method 'bogus' for Integer", runtime_error("<%= partial 'x' %>\n<%= n.bogus %>")
end

test "helpers get args, kwargs and blocks" do
  assert_equal "SPINEL", render("<%= shout 'spinel' %>")
  assert_equal "Hello, Matz!", render("<%= greet(name: 'Matz', punct: '!') %>")
  assert_equal "2/1", render("<%= count_args 1, 2, k: 3 %>")
  assert_equal "<div>[arg]</div>", render("<%= wrap do |v| %>[<%= v %>]<% end %>")
  assert_equal "", render("<% wrap do |v| %>[<%= v %>]<% end %>")
end

test "escaping vs raw" do
  env = with(new_env, "html", "<i>\"q\" & 'a'</i>")
  assert_equal "&lt;i&gt;&quot;q&quot; &amp; &#39;a&#39;&lt;/i&gt;", render("<%= html %>", env)
  assert_equal "<i>\"q\" & 'a'</i>", render("<%== html %>", env)
  assert_equal "<i>\"q\" & 'a'</i>", render("<%= raw html %>", env)
  assert_equal "<b>", render("<%= '<b>'.html_safe %>")
end

test "nil prints nothing" do
  assert_equal "[]", render("[<%= nil %>]")
  assert_equal "[]", render("[<%== nothing %>]", new_env)
end

test "yield reads the layout content slots" do
  env = new_env
  env["__content"] = Cybertrain::SafeString.new("<p>page</p>")
  env["__content_title"] = "A & B"
  assert_equal "<title>A &amp; B</title><p>page</p>", render("<title><%= yield :title %></title><%= yield %>", env)
  assert_equal "[]", render("[<%= yield :missing %>]", env)
end

Cybertrain::Test.run!
