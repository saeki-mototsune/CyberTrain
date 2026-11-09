require "cybertrain"
require "cybertrain/cache"
require "cybertrain/test"

# Cybertrain::Cache: fetch computes once and serves the value until it
# expires; write with unless_exist refuses only a live row;
# race_condition_ttl lets one caller recompute an expired value while the
# others read the stale one; a raising block writes nothing; increment
# counts with an expiry; the typed readers parse what they stored and read
# a corrupt cell as empty; prune removes only expired rows, from the
# scheduler task requiring the file registers once; and the table is made
# on first use and left out of the schema dump. Time comes from an
# injected clock (CLOCK), so nothing sleeps. Compiled with the whole
# framework (NOTES rule 41); it links SQLite through FFI, so its snapshot
# comes from the compiled binary (rule 23).

DB = Cybertrain::DB
Cache = Cybertrain::Cache
S = Cybertrain::Scheduler
Cast = Cybertrain::Cast

# The injected clock's epoch seconds, set by each test (a constant: NOTES
# rule 64).
CLOCK = [1000]
Cache.clock = -> { CLOCK[0] }

# What the blocks ran, and what a second caller saw, read back by the tests.
CALLS = Array.new(0) { "" }
SEEN = Array.new(0) { "" }

def calls_text
  CALLS.join(",")
end

def dumped_tables
  DB.with { |c| DB::SchemaDumper.table_names(c) }
end

def cache_rows
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_cache") }
  Cast.int(rows[0]["n"])
end

# A second caller of an expired key while the first recomputes it (called
# from the first caller's block).
def second_caller
  SEEN << Cache.fetch("tvl", expires_in: 10, race_condition_ttl: 30) do
    CALLS << "b"
    "from b"
  end
  nil
end

# A fetch whose block raises; the message of what it raised.
def failing_fetch(key, ttl)
  assert_raises("RuntimeError") do
    Cache.fetch(key, expires_in: 10, race_condition_ttl: ttl) do
      CALLS << "raise"
      raise "upstream down" if CLOCK[0] > 0

      "never"
    end
  end
end

def prune_task_count
  n = 0
  S::TASKS.each { |t| n += 1 if t.task_name == "cybertrain cache prune" }
  n
end

DB.connect(":memory:")

test "fetch computes once and serves the value until it expires" do
  CLOCK[0] = 1000
  CALLS.clear
  first = Cache.fetch("defillama/tvl", expires_in: 60) do
    CALLS << "a"
    "one"
  end
  second = Cache.fetch("defillama/tvl", expires_in: 60) do
    CALLS << "b"
    "two"
  end
  assert_equal "one", first
  assert_equal "one", second
  assert_equal "a", calls_text
  CLOCK[0] = 1060
  assert_equal "one", Cache.fetch("defillama/tvl", expires_in: 60) { "three" }
  assert Cache.exist?("defillama/tvl")
  CLOCK[0] = 1061
  refute Cache.exist?("defillama/tvl")
  assert_nil Cache.read("defillama/tvl")
  assert_equal "three", Cache.fetch("defillama/tvl", expires_in: 60) { "three" }
  assert_equal "three", Cache.read("defillama/tvl")
  # expires_in: 0, the default, never expires; a block's non-String value
  # is stored as its to_s.
  assert_equal "forever", Cache.fetch("forever") { "forever" }
  assert_equal "42", Cache.fetch("number") { 42 }
  CLOCK[0] = 2_000_000_000
  assert_equal "forever", Cache.read("forever")
  assert_equal "42", Cache.read("number")
  assert Cache.delete("forever")
  refute Cache.delete("forever")
  assert_nil Cache.read("forever")
  Cache.clear
  assert_equal 0, cache_rows
end

test "write with unless_exist answers false for a live row and true after it expired" do
  CLOCK[0] = 1000
  assert Cache.write("import-lock", "1", expires_in: 300, unless_exist: true)
  refute Cache.write("import-lock", "2", expires_in: 300, unless_exist: true)
  assert_equal "1", Cache.read("import-lock")
  CLOCK[0] = 1300
  refute Cache.write("import-lock", "2", expires_in: 300, unless_exist: true)
  CLOCK[0] = 1301
  assert Cache.write("import-lock", "3", expires_in: 300, unless_exist: true)
  assert_equal "3", Cache.read("import-lock")
  # A row that never expires is never overwritten by unless_exist.
  assert Cache.write("pinned", "a")
  refute Cache.write("pinned", "b", unless_exist: true)
  assert_equal "a", Cache.read("pinned")
  # A plain write always replaces, expiry included.
  assert Cache.write("pinned", "c", expires_in: 5)
  assert_equal "c", Cache.read("pinned")
  CLOCK[0] = 1307
  assert_nil Cache.read("pinned")
end

test "race_condition_ttl lets one caller recompute while the other reads the stale value" do
  CLOCK[0] = 5000
  CALLS.clear
  SEEN.clear
  assert Cache.write("tvl", "old", expires_in: 10)
  CLOCK[0] = 5011
  value = Cache.fetch("tvl", expires_in: 10, race_condition_ttl: 30) do
    CALLS << "a"
    second_caller
    "new"
  end
  assert_equal "new", value
  assert_equal "old", SEEN.join(",")
  assert_equal "a", calls_text
  assert_equal "new", Cache.read("tvl")
  # Without race_condition_ttl every caller of an expired key recomputes.
  CLOCK[0] = 5022
  assert_equal "again", Cache.fetch("tvl", expires_in: 10) { "again" }
  # A missing row with a block always computes.
  assert_equal "fresh", Cache.fetch("missing", race_condition_ttl: 30) { "fresh" }
end

test "fetch whose block raises writes nothing" do
  CLOCK[0] = 3000
  CALLS.clear
  assert Cache.write("rates", "old", expires_in: 10)
  CLOCK[0] = 3011
  assert_includes failing_fetch("rates", 30), "upstream down"
  # The stale row was extended for race_condition_ttl seconds, no more.
  assert_equal "old", Cache.read("rates")
  CLOCK[0] = 3041
  assert_equal "old", Cache.read("rates")
  CLOCK[0] = 3042
  assert_nil Cache.read("rates")
  assert_includes failing_fetch("nothing", 0), "upstream down"
  assert_nil Cache.read("nothing")
  refute Cache.exist?("nothing")
  assert_equal "raise,raise", calls_text
end

test "increment creates and adds, with an expiry" do
  CLOCK[0] = 4000
  assert_equal 1, Cache.increment("hits")
  assert_equal 6, Cache.increment("hits", by: 5)
  assert_equal 4, Cache.increment("hits", by: -2)
  assert_equal "4", Cache.read("hits")
  assert_equal 1, Cache.increment("rate", expires_in: 60)
  CLOCK[0] = 4050
  # Without expires_in the expiry stays; with it, it is refreshed.
  assert_equal 2, Cache.increment("rate")
  CLOCK[0] = 4061
  assert_nil Cache.read("rate")
  # An expired counter starts again from by.
  assert_equal 3, Cache.increment("rate", by: 3, expires_in: 60)
  CLOCK[0] = 4100
  assert_equal 4, Cache.increment("rate", expires_in: 60)
  CLOCK[0] = 4160
  assert_equal "4", Cache.read("rate")
  CLOCK[0] = 4161
  refute Cache.exist?("rate")
  # A value that is not a number counts as 0.
  assert Cache.write("word", "abc")
  assert_equal 2, Cache.increment("word", by: 2)
end

test "fetch_hash / fetch_array / fetch_int parse what they stored and recover from a corrupt cell" do
  CLOCK[0] = 6000
  prices = Cache.fetch_hash("prices/eth", expires_in: 60) { { "usd" => 3000, "sym" => "ETH" } }
  assert_equal 3000, Cast.int(prices["usd"])
  assert_equal "ETH", Cast.str(prices["sym"])
  assert_equal "{\"usd\":3000,\"sym\":\"ETH\"}", Cache.read("prices/eth")
  again = Cache.fetch_hash("prices/eth", expires_in: 60) { { "usd" => 1 } }
  assert_equal 3000, Cast.int(again["usd"])
  tags = Cache.fetch_array("tags", expires_in: 60) { ["a", "b"] }
  assert_equal "a,b", tags.map { |t| Cast.str(t) }.join(",")
  assert_equal "[\"a\",\"b\"]", Cache.read("tags")
  assert_equal 7, Cache.fetch_int("count", expires_in: 60) { 7 }
  assert_equal 7, Cache.fetch_int("count", expires_in: 60) { 8 }
  assert_equal "7", Cache.read("count")
  # A corrupt cell reads as empty, and is recomputed once it expires.
  assert Cache.write("prices/eth", "{not json", expires_in: 60)
  assert Cache.write("tags", "{\"an\":\"object\"}", expires_in: 60)
  assert Cache.write("count", "99999999999999999999999", expires_in: 60)
  assert_equal 0, Cache.fetch_hash("prices/eth", expires_in: 60) { { "usd" => 2 } }.size
  assert_equal 0, Cache.fetch_array("tags", expires_in: 60) { ["c"] }.size
  assert_equal 0, Cache.fetch_int("count", expires_in: 60) { 9 }
  CLOCK[0] = 6061
  assert_equal 2, Cast.int(Cache.fetch_hash("prices/eth", expires_in: 60) { { "usd" => 2 } }["usd"])
  assert_equal 1, Cache.fetch_array("tags", expires_in: 60) { ["c"] }.size
  assert_equal 9, Cache.fetch_int("count", expires_in: 60) { 9 }
end

test "prune removes only expired rows; the scheduler task is registered once" do
  DB.connect(":memory:")
  CLOCK[0] = 7000
  assert Cache.write("keep", "k")
  assert Cache.write("live", "l", expires_in: 100)
  i = 0
  while i < 2500
    Cache.write("old/#{i}", "o", expires_in: 10)
    i += 1
  end
  assert_equal 2502, cache_rows
  assert_equal 0, Cache.prune(7010)
  assert_equal 2500, Cache.prune(7011)
  assert_equal 2, cache_rows
  assert_equal "k", Cache.read("keep")
  assert_equal "l", Cache.read("live")
  assert_equal 1, prune_task_count
  index = S.task_index("cybertrain cache prune")
  assert_equal 300, S::TASKS[index].task_interval
  # A second registration (a second require) adds nothing.
  Cache.register_prune_task
  assert_equal 1, prune_task_count
  # The task prunes at the clock's now.
  CLOCK[0] = 7101
  assert S.run_task(S::TASKS[index])
  assert_equal 1, cache_rows
  assert_equal "k", Cache.read("keep")
end

test "the table is created on first use and left out of the schema dump" do
  DB.connect(":memory:")
  assert_equal "", dumped_tables.join(",")
  assert_nil Cache.read("anything")
  Cache.install!
  Cache.install!
  rows = DB.with { |c| c.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cybertrain_cache'") }
  assert_equal 1, rows.size
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT);") }
  assert_equal "posts", dumped_tables.join(",")
end

test "cache_prune_interval: 300, CYBERTRAIN_CACHE_PRUNE_INTERVAL, at least 1" do
  assert_equal 300, Cybertrain::Config.new.cache_prune_interval
  ENV["CYBERTRAIN_CACHE_PRUNE_INTERVAL"] = "60"
  assert_equal 60, Cybertrain::Config.new.cache_prune_interval
  ENV["CYBERTRAIN_CACHE_PRUNE_INTERVAL"] = "often"
  assert_equal 300, Cybertrain::Config.new.cache_prune_interval
  ENV["CYBERTRAIN_CACHE_PRUNE_INTERVAL"] = "0"
  checked = Cybertrain::Config.new
  assert_equal 0, checked.cache_prune_interval
  assert_equal "cache_prune_interval must be at least 1 (got 0)", checked.scheduler_error
  ENV.delete("CYBERTRAIN_CACHE_PRUNE_INTERVAL")
end

Cybertrain::Test.run!
