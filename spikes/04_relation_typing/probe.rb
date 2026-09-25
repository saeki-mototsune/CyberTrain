# SPIKE (throwaway): how does --emit-rbs report attr_accessor ivar types?
class R
  attr_accessor :a, :s, :sn, :t
end
r = R.new
r.a = 5
r.s = "x"
r.sn = nil
r.sn = "y" if ARGV.size > 0
r.t = Time.at(0)
x = r.a
puts x + 1
