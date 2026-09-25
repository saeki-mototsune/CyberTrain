# SPIKE (throwaway): define_method(:literal), method(:literal) objects stored in an Array and called later, respond_to?(:literal)
class Base
  define_method(:greet) { "hello from #{self.class.name}" }
  define_method(:twice) { |x| x * 2 }
  def a; "a"; end
  def b; "b"; end
end
class Sub < Base
  define_method(:extra) { @v = 5; @v + 1 }
  def b; "sub-b"; end
end

s = Sub.new
puts s.greet
puts s.twice(21)
puts s.extra

ms = [s.method(:a), s.method(:b), s.method(:greet)]
ms.each { |m| puts m.call }
tw = s.method(:twice)
puts tw.call(4)

puts s.respond_to?(:extra)
puts s.respond_to?(:nope)
puts Base.new.respond_to?(:extra)
x = [:extra, :nope].map { |n| s.respond_to?(n) }
p x
