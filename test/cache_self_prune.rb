require "cybertrain/core"
require "cybertrain/cache"
require "cybertrain/test"

# Cybertrain::Cache without jobs (the optional-subsystems design, section
# 4): no scheduler runs its prune, so a write prunes the expired rows itself
# once Config#cache_prune_interval (300 s by default) has passed since the
# last prune, counted from the first write. Both writing paths do it:
# Cache.write (and so fetch) and Cache.increment (rate limiting's
# counters). Time comes from an injected clock (CLOCK), so nothing sleeps.
# test/cache.rb, which requires the whole framework, keeps the scheduled
# prune. It links SQLite through FFI, so its snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Cache = Cybertrain::Cache

# The injected clock's epoch seconds (a constant: NOTES rule 64).
CLOCK = [1000]
Cache.clock = -> { CLOCK[0] }

def cache_rows
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_cache") }
  Cybertrain::Cast.int(rows[0]["n"])
end

DB.connect(":memory:")

test "the cache is a feature with a periodic prune, and nothing schedules it" do
  assert Cybertrain::Features.feature_loaded?("cache")
  refute Cybertrain::Features.feature_loaded?("jobs")
  refute Cybertrain::Features.periodic_scheduler?
end

test "a write prunes the expired rows once the interval has passed since the last prune" do
  CLOCK[0] = 1000
  # The first write starts the count; it prunes nothing.
  assert Cache.write("old", "o", expires_in: 10)
  assert Cache.write("keep", "k")
  assert_equal 2, cache_rows
  # "old" expired after 1010, but 299 s are not the interval.
  CLOCK[0] = 1299
  assert Cache.write("a", "a")
  assert_equal 3, cache_rows
  # 300 s after the first write: this write prunes.
  CLOCK[0] = 1300
  assert Cache.write("b", "b", expires_in: 5)
  assert_equal 3, cache_rows
  assert_nil Cache.read("old")
  assert_equal "k", Cache.read("keep")
  # "b" expires after 1305; the next prune is due at 1600.
  CLOCK[0] = 1599
  assert_equal 1, Cache.increment("hits", expires_in: 1)
  assert_equal 4, cache_rows
end

test "an increment prunes too" do
  CLOCK[0] = 1600
  assert_equal 1, Cache.increment("more")
  # Of "b" (expires_at 1305) and "hits" (1600, still live at 1600), only
  # "b" goes; "more" is added.
  assert_equal 4, cache_rows
  assert_nil Cache.read("b")
end

Cybertrain::Test.run!
