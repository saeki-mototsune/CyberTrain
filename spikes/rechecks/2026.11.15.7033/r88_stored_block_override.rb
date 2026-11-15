class Base
  @cbs = []
  def self.cbs = @cbs
  def self.add(&block)
    Base.cbs << block
    nil
  end
  def hook = nil
  def run
    out = "none"
    Base.cbs.each do |cb|
      v = cb.call(self)
      out = v.to_s
    end
    out
  end
end
class Sub < Base
  add { |r| r.hook }
  def hook = "sub"
end
puts Sub.new.run.inspect
