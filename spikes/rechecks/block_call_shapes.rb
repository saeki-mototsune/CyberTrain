# Reduced shapes only: NOTES 69. A method that takes `&block` and calls
# `block.call`, with an `ensure` or a `rescue` of its own, and a Proc passed
# two levels down as a plain parameter and called there with an instance of
# a user-defined class, whose method the block itself calls. The rule was
# seen in the framework (DB.transaction -> Pool -> Connection) and never
# reduced; this program has one such block and one class.

LOG = []

def with_ensure(&block)
  r = block.call(2)
  r
ensure
  LOG << "ensure"
end

def with_rescue(&block)
  block.call(3)
rescue StandardError => e
  LOG << "rescued #{e.message}"
  -1
end

class Greeter
  def hi = "hi"
end

def level_one(&block) = level_two(block)
def level_two(blk) = level_three(blk)
def level_three(blk) = blk.call(Greeter.new)

puts with_ensure { |x| x * 2 }
puts with_ensure { |x| x + 1 }
puts with_rescue { |x| raise "bad" if x > 2; x }
puts with_rescue { |x| x }
puts level_one { |g| g.hi }
puts LOG.inspect
