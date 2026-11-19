# Reduced shapes only: NOTES 51, 55 and the parts of 86 that match CRuby.
# One program, so the three shapes are inferred together. Not here, because
# they still differ on 2026.11.04.7026: a Float Range behind `when Range`
# and a Range of Time (differing/float_range_boxed.rb).

# 51: one class's readers, each doing `key.to_s`, called with Symbol and
# String keys in one program; `keys` on that class, on a Hash and on another
# class, also through an Array holding all three. The rule was seen in
# test/router.rb with the framework's Params, not in a class this small.
class Tree
  def initialize
    @h = { "" => "" }
    @h.delete("")
    @l = { "" => [""] }
    @l.delete("")
  end

  def set(k, v)
    @h[k.to_s] = v
    nil
  end

  def [](key) = @h[key.to_s]
  def key?(key) = @h.key?(key.to_s)
  def keys = @h.keys

  def set_list(k, v)
    @l[k] = v
    nil
  end

  def list(k) = @l[k]
end

class Errors
  def initialize
    @e = ["a"]
  end

  def keys = @e
end

t = Tree.new
t.set(:id, "1")
t.set("f", "2")
puts t[:id].to_s, t["f"].to_s, t.key?(:id), t.key?("f"), t.key?(:zz)
puts t.keys.inspect
h = { "x" => 1, :y => 2 }
puts h.keys.inspect
puts Errors.new.keys.inspect
[t, h, Errors.new].each { |o| puts o.keys.size }

# 55: an append through a value read out of a container reaches the stored
# String: through a reader method, through a list element, through a Hash
# and an Array directly, and through a boxed value narrowed by `case`.
w = Tree.new
w.set("id", +"1")
w["id"] << "2"
puts w["id"]
w.set_list("k", [+"a"])
w.list("k")[0] << "x"
puts w.list("k")[0]
plain = { "a" => +"1" }
plain["a"] << "2"
puts plain["a"]
arr = [+"q"]
arr[0] << "r"
puts arr[0]
mixed = { "s" => +"1", "n" => 1 }
v = mixed["s"]
case v
when String then v << "9"
end
puts mixed["s"]

# 86: an Integer Range and a String Range held in a Hash value, or passed
# through a parameter that also takes other types, are matched by
# `when Range`; both read back their ends directly, and so does a Float one.
def kind(x)
  case x
  when Range then "range"
  when Array then "array"
  else "other"
  end
end

def ends_of(x)
  case x
  when Range then [x.begin, x.end]
  else []
  end
end

ranges = { "i" => (1..3), "s" => ("a".."c"), "a" => [1] }
puts kind(ranges["i"]), kind(ranges["s"]), kind(ranges["a"])
puts ends_of(1..3).inspect, ends_of("a".."z").inspect, ends_of([1]).inspect
puts (1.5..2.5).begin, ("a".."c").end, (1.5..2.5).cover?(2.0)
