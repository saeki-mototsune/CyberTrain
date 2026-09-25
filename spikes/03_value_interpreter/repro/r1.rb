# SPIKE (throwaway): repro - empty [] ivar through attr_accessor then << subclass objects
class Node; end
class A < Node; def initialize(t) = @t = t; def t = @t; end
class B < Node; def initialize(x) = @x = x; def x = @x; end
class Frame
  attr_accessor :body
  def initialize(body) = @body = body
end
root = []
f = Frame.new(root)
f.body << A.new("hi")
f.body << B.new(3)
root.each { |n| case n when A then puts n.t when B then puts n.x end }
