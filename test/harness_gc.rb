require "cybertrain/test"

# Regression: the harness kept its registered cases and counters in class
# variables (@@cases, @@assertions, @@failures). Spinel 2026.09.12 does not
# mark class variables for the garbage collector (spikes/NOTES.md rule 64),
# so a program that allocated a lot between registering its tests and
# calling run! (booting an application, running migrations) could have the
# cases Array swept and its memory reused: run! then iterated over whatever
# took its place (an Array of unrelated objects) and reported them as
# failing tests. Every line of the snapshot below says exactly which tests
# ran; the allocation in between must not change it.

# Stands in for the objects an application allocates before run! (a
# migration's operations, say): an Array of objects that are not test cases,
# shaped like the harness's own list so a freed one is a likely reuse.
class HarnessGcOperation
  attr_reader :kind, :table

  def initialize(kind, table)
    @kind = kind
    @table = table
  end
end

ran = Array.new(0) { "" }

test "the first registered test runs" do
  ran << "first"
  assert_equal ["first"], ran
end

test "the second registered test runs" do
  ran << "second"
  assert_equal ["first", "second"], ran
end

test "assertions counted before the allocation are kept" do
  ran << "third"
  assert true
  refute false
end

test "the last registered test sees every earlier one" do
  ran << "last"
  assert_equal ["first", "second", "third", "last"], ran
end

# Short-lived garbage only: nothing it allocates survives the call.
def harness_gc_churn(rounds)
  kept = 0
  r = 0
  while r < rounds
    ops = Array.new(0) { HarnessGcOperation.new("", "") }
    i = 0
    while i < 64
      ops << HarnessGcOperation.new("create_table", "t#{r}_#{i}")
      i += 1
    end
    row = { "id" => r, "name" => "row #{r}" }
    words = "a b c #{r}".split(" ")
    kept += ops.size + row.size + words.size
    r += 1
  end
  kept
end

# Lists of operations that stay reachable until the program ends.
def harness_gc_live(count)
  lists = Array.new(0) { Array.new(0) { HarnessGcOperation.new("", "") } }
  n = 0
  while n < count
    ops = Array.new(0) { HarnessGcOperation.new("", "") }
    ops << HarnessGcOperation.new("create_table", "live#{n}")
    ops << HarnessGcOperation.new("add_index", "live#{n}")
    lists << ops
    n += 1
  end
  lists
end

# Allocate far past the collector's threshold, force a collection, then
# build live objects (what an application holds when it calls run!): a freed
# cases Array would be the first memory they reuse.
churned = harness_gc_churn(4000)
GC.start
churned += harness_gc_churn(4000)
GC.start
live = harness_gc_live(32)
puts "allocated #{churned} objects before run!, #{live.size} still live"

Cybertrain::Test.run!
