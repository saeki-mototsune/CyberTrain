class Ctl
  def session = "sess"
end
class H
  def initialize(c)
    @c = c
  end
  def who = @c.session
end
module V
  @b = ->(c) { H.new(c) }
  def self.b = @b
end
puts V.b.call(Ctl.new).who
