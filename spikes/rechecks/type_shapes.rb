# Reduced shapes only: NOTES 7 to 11, 14, 26, 29, 34, 35, 37, 39, 41, 43 and
# two parts of 46, one section each, in one program. Each section
# says what it leaves out. For 11 and 37 only the output is compared: the cost
# those rules are about shows in the generated C, not here.

# 7: a Time assigned directly to an ivar that starts as nil.
class Rec
  attr_accessor :at, :name, :n
  def initialize
    @at = nil
    @name = nil
    @n = nil
  end
  def stamp(t); @at = t; end
end
rec = Rec.new
puts rec.at.nil?
rec.at = Time.at(1_700_000_000).utc
puts rec.at.to_i
puts rec.at.year
rec2 = Rec.new
rec2.stamp(Time.at(1_600_000_000).utc)
puts rec2.at.to_i
rec2.name = "x"; rec2.n = 5
puts rec2.name, rec2.n
rec3 = Rec.new
puts rec3.at.nil?
puts(rec3.at ? "set" : "nil")

# 8: `when Array` and `when Hash` before `when Time`, with Times from an
# Array and from a Hash.
def kind(v)
  case v
  when Array then "array(#{v.size})"
  when Hash then "hash"
  when String then "string"
  when Integer then "int"
  when Time then "time #{v.to_i}"
  else "other"
  end
end
vals = [Time.at(1_700_000_000), [1, 2], { "a" => 1 }, "s", 3, nil, Time.at(5)]
vals.each { |v| puts kind(v) }
mixed = { "t" => Time.at(7), "a" => [1] }
mixed.each { |k, v| puts k + " " + kind(v) }
puts vals[0].is_a?(Array)
puts(Array === vals[6])

# 9: empty containers in ivars without an element seed.
class Node
  attr_reader :v
  def initialize(v); @v = v; end
end
class Holder
  attr_reader :nodes, :index, :names
  def initialize
    @nodes = []
    @index = {}
    @names = []
  end
  def add(n); @nodes << n; @index[n.v] = n; @names << n.v; end
end
holder = Holder.new
puts holder.nodes.size, holder.index.size
holder.add(Node.new("a")); holder.add(Node.new("b"))
puts holder.nodes[1].v
puts holder.index["a"].v
puts holder.names.join(",")
holder.nodes.each { |n| puts n.v.upcase }
puts holder.index.key?("zz")
empty = Holder.new
puts empty.nodes.empty?, empty.index.empty?
empty.nodes.each { |n| puts n.v }
puts empty.index["q"].nil?

# 10/34: one method name on unrelated classes meeting in a polymorphic
# receiver.
class ColumnIndex
  attr_reader :cols
  def initialize(c); @cols = c; end
end
class Frame
  def initialize(b); @b = b; end
  def body = @b          # Array of Integer
  def add_index(c) = ColumnIndex.new(c)
end
class Page
  def initialize(b); @b = b; end
  def body = @b          # String
  def add_index(c) = [c, c]
end
frame = Frame.new([1, 2, 3]); page = Page.new("hello")
puts frame.body.sum
puts page.body.upcase
puts frame.add_index("x").cols
puts page.add_index("y").size
things = [frame, page]
things.each do |t|
  b = t.body
  case b
  when String then puts "S " + b
  when Array then puts "A " + b.size.to_s
  end
end

# 34: one method name on unrelated classes with different return types, no
# polymorphic receiver.
class NamedIndex; attr_reader :name; def initialize(n); @name = n; end; end
class Table
  def initialize; @ix = [NamedIndex.new("seed")]; @ix.clear; end
  def add_index(cols) = (i = NamedIndex.new(cols.join("_")); @ix << i; i)
end
class Migration
  def initialize; @ops = [["", ""]]; @ops.clear; end
  def add_index(table, cols) = (@ops << [table, cols.join(",")]; @ops)
end
class Status; def status = 200; end
class Migrator; def status = ["up", "down"]; end
class Cli; def self.status = "ok"; end
table = Table.new
puts table.add_index(["a", "b"]).name
migration = Migration.new
puts migration.add_index("posts", ["x"]).size
puts Status.new.status + 1
puts Migrator.new.status.join("/")
puts Cli.status.upcase
puts "#{table.add_index(["c"])}".empty?

# 11: locals initialised to nil and later given a String and an Integer.
def pick(flag)
  s = nil
  n = nil
  if flag
    s = "yes"
    n = 3
  end
  out = +""
  out << (s.nil? ? "none" : s)
  out << ":" << (n.nil? ? "-" : (n + 1).to_s)
  out
end
puts pick(true)
puts pick(false)

# 14: `include?` on a polymorphic receiver with a polymorphic argument.
def member?(coll, x) = coll.include?(x)
colls = ["abc", [1, 2, 3], { "k" => 1 }, ["a", "b"], (1..5)]
args = ["b", 2, "k", "b", 3]
colls.each_with_index { |v, i| puts member?(v, args[i]) }
puts member?("abc", "z")
puts member?([1, 2], "1")

# 29: `String#include?` with a polymorphic argument beside a class with
# `to_s`/`to_str`, and a nullable Hash iterated into a String sink.
class SafeText
  def initialize(s); @s = s; end
  def to_s = @s
  def to_str = @s
  def include?(x) = @s.include?(x.to_s)
end
def has?(recv, needle)
  case recv
  when String then recv.include?(needle)
  when Array then recv.include?(needle)
  else false
  end
end
needles = ["ell", SafeText.new("lo"), 3, "zz"]
puts has?("hello", needles[0])
puts has?("hello", needles[1])
puts has?([1, 2, 3], needles[2])
puts has?("hello", needles[3])
puts SafeText.new("abc").include?("b")
pairs = nil
pairs = { "a" => 1, "b" => 2 } if needles.size > 1
joined = +""
pairs.each { |k, v| joined << k << "=" << v.to_s << ";" }
puts joined

# 37: a Symbol-keyed Integer Hash constant looked up with a polymorphic key.
CODES = { ok: 200, created: 201, not_found: 404 }
def status_code(v)
  case v
  when Integer then v
  when Symbol then CODES[v]
  else 500
  end
end
keys = [:ok, 302, :not_found, "x"]
total = 0
keys.each { |k| total += status_code(k) }
puts total
puts status_code(:created) + 1

# 39: `+` with a `case` whose branches both construct the result, the value
# travelling as a keyword argument.
class SafeString
  def initialize(s); @s = s; end
  def to_s = @s
  def +(other)
    case other
    when SafeString then SafeString.new(@s + other.to_s)
    else SafeString.new(@s + other.to_s.gsub("<", "&lt;"))
    end
  end
end
def show(label:, body:) = puts(label.to_s + "|" + body.to_s)
bold = SafeString.new("<b>")
show(label: bold + SafeString.new("<i>"), body: bold + "<x>")

# 41: an Array-valued `attr_accessor :target` beside a String `target`. The
# rule was seen in the whole framework and never reduced.
class TextNode; attr_reader :t; def initialize(t); @t = t; end; end
class Tag
  attr_accessor :target
  def initialize; @target = [TextNode.new("a")]; end
end
class RequestHead
  def initialize(t); @target = t; end
  def target = @target
  def path = target.split("?")[0]
end
tag = Tag.new
tag.target << TextNode.new("b")
puts tag.target.size
puts tag.target[1].t
head = RequestHead.new("/x?y=1")
puts head.target
puts head.path

# 43: `def body=` on one class beside `attr_accessor :body` on others, boxed
# receivers.
class Response
  attr_accessor :body
  def initialize; @body = ""; end
end
class Post
  def initialize; @body = ""; end
  def body = @body
  def body=(v); @body = v.to_s.strip; end
end
class Counter
  attr_accessor :body
  def initialize; @body = 0; end
end
writers = [Response.new, Post.new]
writers.each { |t| t.body = " hi " }
writers.each { |t| puts "[" + t.body + "]" }
response = Response.new
response.body = "direct"
puts response.body

# 43: a writer calling a cast helper. `Stamped#at=` is given a Time and a
# String, `TimeOnly#at=` only ever a Time; both share the helper.
module Cast
  def self.time_or_nil(v)
    case v
    when Time then v
    when String then (v.empty? ? nil : Time.at(v.to_i).utc)
    when Integer then Time.at(v).utc
    else nil
    end
  end
end
class Stamped
  def initialize; @at = Cast.time_or_nil(nil); end
  def at = @at
  def at=(v); @at = Cast.time_or_nil(v); end
end
class TimeOnly
  def initialize; @at = Cast.time_or_nil(nil); end
  def at = @at
  def at=(v); @at = Cast.time_or_nil(v); end
end
stamped = Stamped.new
puts stamped.at.nil?
stamped.at = Time.at(1_700_000_000).utc
puts stamped.at.to_i
from_text = Stamped.new
from_text.at = "1600000000"
puts from_text.at.to_i
time_only = TimeOnly.new
puts time_only.at.nil?
time_only.at = Time.at(1_700_000_000).utc
puts time_only.at.to_i
five = Time.at(5).utc
puts Cast.time_or_nil(five).to_i

# 46: a Hash literal of Strings later given an Integer and an Array, and
# 5,000 small frames on a Thread (not the depth of nested template renders).
def nest(n) = n == 0 ? 0 : 1 + nest(n - 1)
deep = Thread.new { nest(5000) }
puts deep.value
grown = { "a" => "x", "b" => "y" }
grown["n"] = 5
grown["l"] = [1, 2]
puts grown["n"] + 1
puts grown["l"].size
puts grown["a"].upcase

# 26: `obj.attr += x` inside a block and a lambda.
class Acc; attr_accessor :n; def initialize; @n = 0; end; end
acc = Acc.new
[1, 2, 3].each { |x| acc.n += x }
puts acc.n
add_ten = ->(o) { o.n += 10 }
add_ten.call(acc)
puts acc.n
acc.n ||= 5
acc.n -= 1
puts acc.n

# 35: `obj[k] = v` on a parameter behind a chain of `call(env)` objects. The
# rule was seen in the whole framework and never reduced.
class Session
  def initialize; @h = { "" => "" }; @h.delete(""); end
  def []=(k, v); @h[k] = v; end
  def [](k) = @h[k]
end
class Mw
  def initialize(app); @app = app; end
  def call(env); @app.call(env); end
end
class Csrf
  def initialize(app); @app = app; end
  def call(env)
    stamp(env["session"])
    @app.call(env)
  end
  def stamp(session); session["csrf"] = "tok"; end
end
class App
  def call(env) = [200, env["session"]["csrf"].to_s]
end
chain = Mw.new(Csrf.new(Mw.new(App.new)))
env = { "session" => Session.new }
answer = chain.call(env)
puts answer[0], answer[1]
plain = { "a" => 1 }
def bump(h); h["b"] = 2; end
bump(plain)
puts plain.size
