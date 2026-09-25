# SPIKE (throwaway): can an ivar be String|nil without becoming poly (RBS sidecar / local)?
class C
  attr_accessor :s, :t
  def initialize
    @s = nil
    @t = nil
  end
end
c = C.new
c.s = "x" if ARGV.size == 0
c.t = Time.at(100) if ARGV.size == 0
puts c.s.inspect
puts c.t.inspect; puts c.t.nil?
l = nil
l = "y" if ARGV.size == 0
puts l.inspect
