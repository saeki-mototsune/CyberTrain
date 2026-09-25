# SPIKE (throwaway): alternatives for stored method objects - local Method, direct call, lambdas in Array
class Base
  def a; "a"; end
  def b; "b"; end
  def twice(x); x * 2; end
end
class Sub < Base
  def b; "sub-b"; end
end
s = Sub.new
m1 = s.method(:a)
puts m1.call
puts s.method(:b).call
tw = s.method(:twice)
puts tw.call(4)
ls = [-> { s.a }, -> { s.b }]
ls.each { |l| puts l.call }
h = { a: -> { s.a }, b: -> { s.b } }
puts h[:b].call
# lambda taking the receiver (no capture)
ops = [->(o) { o.a }, ->(o) { o.b }]
ops.each { |op| puts op.call(s) }
puts s.respond_to?(:b)
puts s.respond_to?(:nope)
x = [:b, :nope].map { |n| s.respond_to?(n) }
p x
