# Reduced shapes only: NOTES 1 to 6, 30, 31, 40 and 42, one section each, in
# one program. Each section says what it leaves out. A stored block given to
# `instance_exec` is still refused on 2026.11.04.7026 (NOTES status 2), so it
# is not here.

# 1: `public_send`, `send`, `respond_to?`, `instance_variable_get` and
# `const_get` with a non-literal name. Two methods, two ivars, two constants:
# not dispatch at application scale.
class Reflected
  def initialize; @a = 1; @b = "two"; end
  def alpha = "A"
  def beta(x) = "B#{x}"
end
module Reg; ONE = 1; TWO = 2; end
refl = Reflected.new
names = ["alpha", "beta"]
puts refl.public_send(names[0].to_sym)
puts refl.send(names[1], 3)
puts refl.respond_to?(names[0])
puts refl.respond_to?("gamma")
iv = ["@a", "@b"]
iv.each { |n| puts refl.instance_variable_get(n) }
["ONE", "TWO"].each { |n| puts Reg.const_get(n) }
puts Object.const_get("Reflected").new.alpha

# 2: `instance_eval(&blk)` of a block parameter given a literal block, and
# `instance_exec` with a literal block.
class Evaluated
  def initialize; @v = 5; end
  def run(&blk) = instance_eval(&blk)
  def direct = instance_exec(2) { |x| @v * x }
end
ev = Evaluated.new
puts ev.run { @v + 1 }
puts ev.direct

# 3: a base-class method calling a method only its subclasses define.
class AttrBase
  def show
    "v=" + read_attribute("a").to_s
  end
end
class AttrA < AttrBase
  def read_attribute(name) = "A:" + name
end
class AttrB < AttrBase
  def read_attribute(name) = "B:" + name
end
puts AttrA.new.show
puts AttrB.new.show

# 4: `self.class.foo` where not every subclass overrides `foo`.
class LabelBase
  def self.label = "base"
  def self.table = "bases"
  def describe = self.class.label + "/" + self.class.table
end
class LabelA < LabelBase
  def self.label = "a"
  def self.table = "as"
end
class LabelB < LabelBase
  def self.label = "b"
end
class LabelC < LabelBase
end
[LabelA.new, LabelB.new, LabelC.new].each { |x| puts x.describe }
puts LabelA.new.describe
puts LabelB.new.describe
puts LabelC.new.describe

# 4: an inherited class method reading `name`, called as `self.class.foo`.
class Named
  def self.who = name
  def self.table = who.downcase + "s"
  def self.chain = [who]
  def describe = self.class.who + "/" + self.class.table + "/" + self.class.chain[0]
end
class Entry < Named; end
class Person < Named
  def self.table = "people"
end
puts Entry.new.describe
puts Person.new.describe
puts Named.new.describe
[Entry.new, Person.new].each { |r| puts r.describe }

# 5: base chain methods returning `self`, subclasses with differently typed
# `first`.
class Relation
  def initialize; @w = [""]; @w.clear; end
  def where(s); @w << s; self; end
  def limit(n); @w << "L#{n}"; self; end
  def sql = @w.join(" ")
end
class Article
  attr_accessor :title
  def initialize(t); @title = t; end
end
class ArticleRelation < Relation
  def first = Article.new(sql)
  def only_articles = "articles:" + sql
end
class CountRelation < Relation
  def first = 42
end
rel = ArticleRelation.new.where("a").limit(3)
puts rel.only_articles
puts rel.first.title
counts = CountRelation.new.where("b")
puts counts.first + 1
puts ArticleRelation.new.where("x").where("y").first.title

# 6: `Method` objects in an Array and in a Hash.
class Calc
  def a(x) = x + 1
  def b(x) = x * 2
end
calc = Calc.new
meths = [calc.method(:a), calc.method(:b)]
meths.each { |m| puts m.call(5) }
by_name = { "a" => calc.method(:a) }
puts by_name["a"].call(10)

# 30: a stored block passing a Symbol to a parameter whose direct call sites
# pass Integers.
class Responder
  attr_reader :log
  def initialize; @log = +""; @blocks = [proc { |c| c.head(1) }]; @blocks.clear; end
  def head(status)
    case status
    when Integer then @log << "int:#{status};"
    when Symbol then @log << "sym:#{status};"
    else @log << "other;"
    end
  end
  def on(&blk); @blocks << blk; end
  def run; @blocks.each { |b| b.call(self) }; end
end
resp = Responder.new
resp.head(200)
resp.head(404)
resp.on { |x| x.head(:forbidden) }
resp.run
puts resp.log

# 31: `yield self` in a base-class method called on subclass instances.
class TapBase
  def tap_me
    yield self
    self
  end
  def name = "base"
end
class TapA < TapBase
  def name = "a"
  def only_a = "only a"
end
class TapB < TapBase
  def name = "b"
  def only_b = 7
end
TapA.new.tap_me { |x| puts x.name; puts x.only_a }
TapB.new.tap_me { |x| puts x.name; puts x.only_b + 1 }

# 40: an instance method named `call` with another arity beside `Proc#call`
# sites.
class HelperBase
  def call(name, args, kwargs, block, interp, env)
    "helper #{name} #{args.size} #{kwargs.size} #{env}"
  end
end
class Filters
  def initialize; @before = [proc { |c| c.note("seed") }]; @before.clear; @notes = [""]; @notes.clear; end
  def before_action(&blk); @before << blk; end
  def note(s); @notes << s; end
  def run; @before.each { |b| b.call(self) }; @notes.join(","); end
end
filters = Filters.new
filters.before_action { |x| x.note("one") }
filters.before_action { |x| x.note("two") }
puts filters.run
puts HelperBase.new.call("h", [1, 2], { "k" => 1 }, nil, nil, "env")
adder = ->(a, b) { a + b }
puts adder.call(1, 2)

# 42: a lambda literal, and a local holding one, passed as a keyword argument
# and called later.
class Views
  def initialize(url_resolver:); @r = url_resolver; end
  def url(name, args) = @r.call(name, args)
end
views = Views.new(url_resolver: ->(name, args) { "/#{name}/#{args.join('/')}" })
puts views.url("posts", ["1", "edit"])
held = ->(name, args) { name.to_s.upcase + args.size.to_s }
other_views = Views.new(url_resolver: held)
puts other_views.url(:sym, [1, 2, 3])
