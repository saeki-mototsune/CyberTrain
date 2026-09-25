# SPIKE (throwaway): minimal repro - base-class method calls subclass-only read_attribute(elem.attr) -> spinel codegen SIGSEGV (exit 139)
class V
  attr_reader :attr
  def initialize(a) = (@attr = a)
end
class Base
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
