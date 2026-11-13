require "cybertrain/core"
require "cybertrain/cache"
require "cybertrain/test"

# Cybertrain::Cache without jobs (the optional-subsystems design, section
# 4): no scheduler runs its prune, so a write prunes the expired rows itself:
# the first write of the process, and the first once
# Config#cache_prune_interval (300 s by default) has passed since the last
# prune, at most one batch (Cache::PRUNE_BATCH, 1000 rows) per write; a full
# batch leaves the clock, so the next write continues. Both writing paths do it:
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

# Rows expired long ago, inserted behind the cache's back: `count` of them
# named "#{prefix}N", expires_at 500.
def insert_expired(prefix, count)
  Cache.ensure_installed
  DB.with do |c|
    c.execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?) " \
              "INSERT INTO cybertrain_cache (key, value, expires_at, updated_at) SELECT ? || i, 'v', 500, 0 FROM n",
              Cybertrain::Cast.binds(count, prefix))
  end
  nil
end

DB.connect(":memory:")

test "the cache is a feature with a periodic prune, and nothing schedules it" do
  assert Cybertrain::Features.feature_loaded?("cache")
  refute Cybertrain::Features.feature_loaded?("jobs")
  refute Cybertrain::Features.periodic_scheduler?
end

test "the first write of a process prunes, one batch per write" do
  CLOCK[0] = 1000
  insert_expired("x", 1500)
  assert_equal 1500, cache_rows
  # The first write deletes a full batch and leaves the clock...
  assert Cache.write("keep", "k")
  assert_equal 501, cache_rows
  # ...so the next one continues, whatever the interval.
  CLOCK[0] = 1001
  assert Cache.write("a", "a")
  assert_equal 2, cache_rows
  # The rest was less than a batch: the clock is 1001 now.
  CLOCK[0] = 1002
  assert Cache.write("b", "b", expires_in: 1)
  insert_expired("y", 3)
  assert_equal 6, cache_rows
end

test "a write prunes once the interval has passed since the last prune" do
  # 299 s after 1001 are not the interval.
  CLOCK[0] = 1300
  assert Cache.write("c", "c")
  assert_equal 7, cache_rows
  # 300 s: this write deletes the three y rows and "b" (expired after 1003).
  CLOCK[0] = 1301
  assert Cache.write("d", "d", expires_in: 5)
  assert_equal 4, cache_rows
  assert_nil Cache.read("b")
  assert_equal "k", Cache.read("keep")
end

test "an increment prunes too" do
  # "d" expires after 1306; the next prune is due at 1601.
  CLOCK[0] = 1600
  assert_equal 1, Cache.increment("hits", expires_in: 1)
  assert_equal 5, cache_rows
  CLOCK[0] = 1601
  assert_equal 1, Cache.increment("more")
  # Of "d" (expires_at 1306) and "hits" (1601, still live at 1601), only
  # "d" goes; "more" is added.
  assert_equal 5, cache_rows
  assert_nil Cache.read("d")
end

test "a clock that went backwards makes a prune due" do
  insert_expired("z", 2)
  assert_equal 7, cache_rows
  CLOCK[0] = 1200
  assert Cache.write("e", "e")
  assert_equal 6, cache_rows
  # The prune's clock is 1200 now: a second later nothing is due.
  insert_expired("w", 1)
  CLOCK[0] = 1201
  assert Cache.write("f", "f")
  assert_equal 8, cache_rows
end

test "a failing prune is logged and the write goes on" do
  DB.with do |c|
    c.execute("CREATE TRIGGER refuse_prune BEFORE DELETE ON cybertrain_cache BEGIN SELECT RAISE(ABORT, 'prune refused'); END")
  end
  CLOCK[0] = 1501
  assert Cache.write("g", "g")
  assert_equal "g", Cache.read("g")
  # The failed prune moved the clock: the next write does not try again
  # (no second warning).
  CLOCK[0] = 1502
  assert_equal 1, Cache.increment("h")
  assert_equal 10, cache_rows
  DB.with { |c| c.execute("DROP TRIGGER refuse_prune") }
end

Cybertrain::Test.run!
