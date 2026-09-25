# SPIKE (throwaway): Time|nil loses nil in ivars -- which formulation keeps nil?
class C
  attr_accessor :ti
  def initialize
    @ti = nil
  end
  def t = @ti ? Time.at(@ti) : nil
  def t_or_nil
    return nil if @ti.nil?
    Time.at(@ti)
  end
end
c = C.new
c.ti = 100 if ARGV.size == 0
puts "ivar-int nil?=#{c.ti.nil?}"
puts "method ternary nil?=#{c.t.nil?}"
puts "method guard nil?=#{c.t_or_nil.nil?}"
l = nil
l = Time.at(100) if ARGV.size == 0
puts "local nil?=#{l.nil?}"
h = {}
h[:t] = Time.at(100) if ARGV.size == 0
puts "hash-miss nil?=#{h[:t].nil?}"
class P
  attr_accessor :tp
  def initialize
    @tp = nil
  end
end
pp1 = P.new
pp1.tp = Time.at(100) if ARGV.size == 0
pp1.tp = "str" if ARGV.size == 99
puts "poly-forced nil?=#{pp1.tp.nil?}"
