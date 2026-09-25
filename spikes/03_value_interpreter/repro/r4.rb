# SPIKE (throwaway): repro - polymorphic read_attribute returning Time/String/Integer/nil/Array via base-class dispatch
class Model
  def read_attribute(name) = nil
end
class P < Model
  def initialize(t, c) ; @t = t; @c = c; @s = "str"; @i = 3; @n = nil; end
  def read_attribute(name)
    case name
    when :t then @t
    when :s then @s
    when :i then @i
    when :n then @n
    else nil
    end
  end
  def read_association(name) = @c
end
class Q < Model
  def read_attribute(name) = name == :x ? "q" : nil
end
def show(v)
  case v
  when Time then "Time #{v.year}"
  when String then "String #{v}"
  when Integer then "Int #{v}"
  when Array then "Array #{v.size}"
  when nil then "nil"
  else "other"
  end
end
def get(m, sym)
  case m
  when Model
    v = m.read_attribute(sym)
    v
  else nil
  end
end
ms = [P.new(Time.at(1_700_000_000), [1,2]), Q.new]
[:t, :s, :i, :n].each { |s| puts show(get(ms[0], s)) }
puts show(get(ms[1], :x))
x = ms[0]
puts show(x.read_association(:c)) if x.is_a?(P)
