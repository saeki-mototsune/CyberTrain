# SPIKE (throwaway): same as repro_segv.rb with an abstract stub in Base -> compiles
class V
  attr_reader :attr
  def initialize(a) = (@attr = a)
end
class Base
  def read_attribute(n) = nil   # WORKAROUND: abstract stub in base
  def check
    list.each { |v| puts read_attribute(v.attr).inspect }
  end
end
class A < Base
  L = []
  def list = L
  def read_attribute(n) = (n == :x ? 1 : nil)
end
A::L << V.new(:x)
A.new.check
