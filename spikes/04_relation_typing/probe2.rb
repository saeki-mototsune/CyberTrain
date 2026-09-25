# SPIKE (throwaway): which ways of setting a String ivar keep it typed String?
class A
  attr_accessor :s
end
a = A.new
a.s = "x"
puts a.s

class B
  attr_accessor :s
  def initialize
    @s = ""
  end
end
b = B.new
b.s = "x"
puts b.s

class C
  attr_accessor :s
  def initialize
    @s = nil
  end
end
c = C.new
c.s = "x"
puts c.s.inspect

class D
  attr_accessor :s
end
d = D.new
d.s = "x" + ARGV.size.to_s
puts d.s

class E
  attr_accessor :n
  def initialize
    @n = nil
  end
end
e = E.new
e.n = 5
puts e.n.inspect
