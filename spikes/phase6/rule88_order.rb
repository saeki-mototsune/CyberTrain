# spikes/NOTES.md rule 88 reduced further (rule 104): the same stored
# block, `{ |r| r.hook }` called with an Early and a Late (both overriding
# Base#hook), written in three places. Only the block written in a
# subclass's body before that subclass's `def hook` is wrong, and it is
# wrong for every receiver: it is bound to Base#hook, not dispatched.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase6/):
#   ruby rule88_order.rb
#   spinel rule88_order.rb -o /tmp/rule88_order && /tmp/rule88_order
# Output under CRuby 3.3.6:
#   block in Early's body, before its def: early override, late override
#   block in Late's body, after its def: early override, late override
#   block at top level: early override, late override
# Output compiled (the first line differs):
#   block in Early's body, before its def: base stub, base stub
#   block in Late's body, after its def: early override, late override
#   block at top level: early override, late override
module Store
  CALLS = []

  def self.add(&block)
    CALLS << block
    nil
  end
end

class Base
  def hook
    "base stub"
  end
end

# The block is written in the subclass's body before the override's def.
class Early < Base
  Store.add { |r| r.hook }

  def hook
    "early override"
  end
end

class Late < Base
  def hook
    "late override"
  end

  # The same block, written after the override's def.
  Store.add { |r| r.hook }
end

# The same block at top level, after both classes.
Store.add { |r| r.hook }

objs = Array.new(0) { Base.new }
objs << Early.new
objs << Late.new
labels = ["in Early's body, before its def", "in Late's body, after its def", "at top level"]
i = 0
while i < Store::CALLS.size
  results = objs.map { |o| Store::CALLS[i].call(o) }
  puts "block #{labels[i]}: #{results.join(", ")}"
  i += 1
end
