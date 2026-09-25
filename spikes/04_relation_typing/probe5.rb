# SPIKE (throwaway): minimal repro of Time|nil ivar losing nil
class Q
  attr_accessor :t
  def initialize
    @t = nil
  end
end
q = Q.new
q.t = Time.at(100) if ARGV.size == 0
puts "attr nil?=#{q.t.nil?}"
class Q2
  attr_accessor :t
end
q2 = Q2.new
q2.t = Time.at(100) if ARGV.size == 0
puts "attr-noinit nil?=#{q2.t.nil?}"
class Q3
  def initialize
    @t = nil
  end
  def t = @t
  def set(v)
    @t = v
  end
end
q3 = Q3.new
q3.set(Time.at(100)) if ARGV.size == 0
puts "explicit nil?=#{q3.t.nil?}"
