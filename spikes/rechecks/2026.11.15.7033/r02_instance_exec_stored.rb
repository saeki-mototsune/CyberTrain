class C
  def x = 7
end
module Reg
  @blocks = []
  def self.add(&block)
    @blocks << block
    nil
  end
  def self.blocks = @blocks
end
Reg.add { x }
Reg.blocks.each { |b| puts C.new.instance_exec(&b) }
