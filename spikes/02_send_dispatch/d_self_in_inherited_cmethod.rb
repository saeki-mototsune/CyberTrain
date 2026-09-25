# SPIKE (throwaway): inside an inherited (not overridden) class method called via self.class, is `self`/`name` the subclass?
class Base
  REG = { "Base" => ["b"], "Kid" => ["k"] }
  def self.who; name; end
  def self.who_self; self.name; end
  def self.chain; out = []; k = self; while k; out << k.name; break if k == Base; k = k.superclass; end; out; end
  def self.regs; REG[name] || []; end
  def via_class; "#{self.class.who} #{self.class.who_self} #{self.class.chain.inspect} #{self.class.regs.inspect}"; end
end
class Kid < Base; end
puts Kid.who, Kid.chain.inspect, Kid.regs.inspect
puts Kid.new.via_class
puts Base.new.via_class
