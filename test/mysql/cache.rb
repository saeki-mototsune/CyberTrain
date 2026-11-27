require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/db/schema_dumper"
require "cybertrain/scheduler"
require "cybertrain/cache"
require "cybertrain/test"
require_relative "support/tables"
require_relative "support/services"

# test/cache.rb on MySQL, against the server CYBERTRAIN_TEST_MYSQL_URL names
# (script/test-mysql runs this program): the same tests and the same
# snapshot (test/cache.rb.expected's ok lines), so fetch, write with
# unless_exist, race_condition_ttl, increment, the typed readers and prune
# answer on MySQL what they answer on SQLite; then MySQL's own tests: a
# write and an increment inside a transaction roll back with it and are
# kept by its commit (cache_write_rolls_back), two threads on two
# connections incrementing one counter 500 times each count to 1000 and
# are each answered a distinct count (increment_is_atomic), the loser of
# two concurrent write(unless_exist: true) of one key answers false, and a
# counter below zero.
#
# What differs from the original is marked where it is:
# - the database: each DB.connect(":memory:") of the original is
#   MySQLServices.fresh_db (the framework tables dropped, so the next use
#   creates them); cybertrain_cache is the framework's own MySQL DDL
#   (DB::Dialect.cache_table_sql).
# - the program: the original requires the whole framework ("cybertrain"),
#   which does not compile on MySQL yet (cybertrain/mysql: the plan's Task
#   14), so it is the database layer, the scheduler and the cache. Without
#   cybertrain/jobs no feature runs periodic work, and the cache prunes on
#   its writes instead of registering its scheduled task; "exception: no
#   jobs" marks the assertions on that task, which check here that none is
#   registered and run the task's own code (CacheFeature#periodic).
# - "exception: shared database" where the original reads the whole schema
#   dump of a database that holds nothing else, or sqlite_master: here this
#   program's tables are looked for in the dump, and the table in
#   information_schema (DB::Dialect.table_exists?).

DB = Cybertrain::DB
Cache = Cybertrain::Cache
S = Cybertrain::Scheduler
Cast = Cybertrain::Cast

# What the blocks ran, and what a second caller saw, read back by the tests.
CALLS = Array.new(0) { "" }
SEEN = Array.new(0) { "" }

def calls_text
  CALLS.join(",")
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
      raise "upstream down" if Cybertrain::Clock.now.to_i > 0

      "never"
    end
  end
end

def prune_task_count
  n = 0
  S::TASKS.each { |t| n += 1 if t.task_name == "cybertrain cache prune" }
  n
end

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

OWN_TABLES = ["ct_cache_posts"]

def fresh_db
  MySQLServices.fresh_db(URL, OWN_TABLES)
end

fresh_db

test "fetch computes once and serves the value until it expires" do
  travel_to(Time.at(1000))
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
  travel_to(Time.at(1060))
  assert_equal "one", Cache.fetch("defillama/tvl", expires_in: 60) { "three" }
  assert Cache.exist?("defillama/tvl")
  travel_to(Time.at(1061))
  refute Cache.exist?("defillama/tvl")
  assert_nil Cache.read("defillama/tvl")
  assert_equal "three", Cache.fetch("defillama/tvl", expires_in: 60) { "three" }
  assert_equal "three", Cache.read("defillama/tvl")
  # expires_in: 0, the default, never expires; a block's non-String value
  # is stored as its to_s.
  assert_equal "forever", Cache.fetch("forever") { "forever" }
  assert_equal "42", Cache.fetch("number") { 42 }
  travel_to(Time.at(2_000_000_000))
  assert_equal "forever", Cache.read("forever")
  assert_equal "42", Cache.read("number")
  assert Cache.delete("forever")
  refute Cache.delete("forever")
  assert_nil Cache.read("forever")
  Cache.clear
  assert_equal 0, cache_rows
end

test "write with unless_exist answers false for a live row and true after it expired" do
  travel_to(Time.at(1000))
  assert Cache.write("import-lock", "1", expires_in: 300, unless_exist: true)
  refute Cache.write("import-lock", "2", expires_in: 300, unless_exist: true)
  assert_equal "1", Cache.read("import-lock")
  travel_to(Time.at(1300))
  refute Cache.write("import-lock", "2", expires_in: 300, unless_exist: true)
  travel_to(Time.at(1301))
  assert Cache.write("import-lock", "3", expires_in: 300, unless_exist: true)
  assert_equal "3", Cache.read("import-lock")
  # A row that never expires is never overwritten by unless_exist.
  assert Cache.write("pinned", "a")
  refute Cache.write("pinned", "b", unless_exist: true)
  assert_equal "a", Cache.read("pinned")
  # A plain write always replaces, expiry included.
  assert Cache.write("pinned", "c", expires_in: 5)
  assert_equal "c", Cache.read("pinned")
  travel_to(Time.at(1307))
  assert_nil Cache.read("pinned")
end

test "race_condition_ttl lets one caller recompute while the other reads the stale value" do
  travel_to(Time.at(5000))
  CALLS.clear
  SEEN.clear
  assert Cache.write("tvl", "old", expires_in: 10)
  travel_to(Time.at(5011))
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
  travel_to(Time.at(5022))
  assert_equal "again", Cache.fetch("tvl", expires_in: 10) { "again" }
  # A missing row with a block always computes.
  assert_equal "fresh", Cache.fetch("missing", race_condition_ttl: 30) { "fresh" }
end

test "fetch whose block raises writes nothing" do
  travel_to(Time.at(3000))
  CALLS.clear
  assert Cache.write("rates", "old", expires_in: 10)
  travel_to(Time.at(3011))
  assert_includes failing_fetch("rates", 30), "upstream down"
  # The stale row was extended for race_condition_ttl seconds, no more.
  assert_equal "old", Cache.read("rates")
  travel_to(Time.at(3041))
  assert_equal "old", Cache.read("rates")
  travel_to(Time.at(3042))
  assert_nil Cache.read("rates")
  assert_includes failing_fetch("nothing", 0), "upstream down"
  assert_nil Cache.read("nothing")
  refute Cache.exist?("nothing")
  assert_equal "raise,raise", calls_text
end

test "increment creates and adds, with an expiry" do
  travel_to(Time.at(4000))
  assert_equal 1, Cache.increment("hits")
  assert_equal 6, Cache.increment("hits", by: 5)
  assert_equal 4, Cache.increment("hits", by: -2)
  assert_equal "4", Cache.read("hits")
  assert_equal 1, Cache.increment("rate", expires_in: 60)
  travel_to(Time.at(4050))
  # Without expires_in the expiry stays.
  assert_equal 2, Cache.increment("rate")
  travel_to(Time.at(4061))
  assert_nil Cache.read("rate")
  # An expired counter starts again from by, with a new expiry.
  assert_equal 3, Cache.increment("rate", by: 3, expires_in: 60)
  # With expires_in a live counter keeps its expiry: the window is fixed
  # from the counter's start (4061 + 60), not moved by each call.
  travel_to(Time.at(4100))
  assert_equal 4, Cache.increment("rate", expires_in: 60)
  travel_to(Time.at(4121))
  assert_equal "4", Cache.read("rate")
  travel_to(Time.at(4122))
  refute Cache.exist?("rate")
  # A live counter with no expiry takes the one given.
  assert_equal 6, Cache.increment("hits", by: 2, expires_in: 10)
  travel_to(Time.at(4132))
  assert_equal "6", Cache.read("hits")
  travel_to(Time.at(4133))
  refute Cache.exist?("hits")
  # A value that is not a number counts as 0.
  assert Cache.write("word", "abc")
  assert_equal 2, Cache.increment("word", by: 2)
end

test "fetch_hash / fetch_array / fetch_int parse what they stored and recover from a corrupt cell" do
  travel_to(Time.at(6000))
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
  travel_to(Time.at(6061))
  assert_equal 2, Cast.int(Cache.fetch_hash("prices/eth", expires_in: 60) { { "usd" => 2 } }["usd"])
  assert_equal 1, Cache.fetch_array("tags", expires_in: 60) { ["c"] }.size
  assert_equal 9, Cache.fetch_int("count", expires_in: 60) { 9 }
end

test "prune removes only expired rows; the scheduler task is registered once" do
  fresh_db
  travel_to(Time.at(7000))
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
  # exception: no jobs (the original: the task is registered once, every
  # 300 s, and a second registration adds nothing).
  refute Cybertrain::Features.periodic_scheduler?
  assert_equal 0, prune_task_count
  Cache.register_prune_task
  assert_equal 0, prune_task_count
  assert_equal 300, Cybertrain::CacheFeature.new.periodic_interval
  # The task prunes at the clock's now.
  travel_to(Time.at(7101))
  # exception: no jobs (the original runs the registered task).
  assert_nil Cybertrain::CacheFeature.new.periodic(0)
  assert_equal 1, cache_rows
  assert_equal "k", Cache.read("keep")
end

test "the table is created on first use and left out of the schema dump" do
  fresh_db
  # exception: shared database (the original: the dump is empty).
  assert_equal "", MySQLServices.dumped(["cybertrain_cache", "ct_cache_posts"])
  refute DB.with { |c| DB::Dialect.table_exists?(c, "cybertrain_cache") }
  assert_nil Cache.read("anything")
  Cache.install!
  Cache.install!
  # exception: shared database (the original reads sqlite_master).
  assert DB.with { |c| DB::Dialect.table_exists?(c, "cybertrain_cache") }
  DB.with { |c| c.exec_script("CREATE TABLE ct_cache_posts (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, title MEDIUMTEXT)") }
  # exception: shared database (the original: "posts" is the whole dump).
  assert_equal "ct_cache_posts", MySQLServices.dumped(["cybertrain_cache", "ct_cache_posts"])
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

# ---- MySQL's own ----------------------------------------------------------

# A write and an increment in a transaction that raises, in a method body
# (NOTES rule 45), as test/jobs.rb's enqueue_then_raise.
def write_then_raise
  DB.transaction do |c|
    Cache.write("rolled", "x")
    Cache.increment("rolled/n", by: 5)
    raise "roll it back"
  end
  nil
end

def write_and_commit
  DB.transaction do |c|
    Cache.write("kept", "y")
    Cache.increment("kept/n", by: 5)
    Cache.increment("kept/n", by: 2)
  end
  nil
end

test "cache_write_rolls_back" do
  fresh_db
  travel_to(Time.at(8000))
  # Created outside the transaction: MySQL's CREATE TABLE would commit it.
  Cache.install!
  assert_raises("RuntimeError") { write_then_raise }
  assert_nil Cache.read("rolled")
  assert_nil Cache.read("rolled/n")
  assert_equal 0, cache_rows
  write_and_commit
  assert_equal "y", Cache.read("kept")
  assert_equal "7", Cache.read("kept/n")
  # The increment answered inside the transaction (its own statement, no
  # transaction of its own nested in the caller's).
  assert_equal 8, Cache.increment("kept/n")
end

# The counts one thread was answered (constants: NOTES rule 64).
COUNTS_A = Array.new(0) { 0 }
COUNTS_B = Array.new(0) { 0 }

def increment_times(n, into)
  i = 0
  while i < n
    into << Cache.increment("atomic")
    i += 1
  end
  nil
end

# The brief's two threads, each 500 increments of one key. DB's pool has
# two connections (MySQLServices.fresh_db), each thread's increment checks
# one out, and a query waiting on the server leaves the OS worker to the
# other thread (test/mysql/connection.rb's slow_query_does_not_block_worker),
# so the two threads' statements reach the server interleaved.
test "increment_is_atomic" do
  fresh_db
  travel_to(Time.at(8000))
  Cache.install!
  a = Thread.new { increment_times(500, COUNTS_A) }
  b = Thread.new { increment_times(500, COUNTS_B) }
  a.join
  b.join
  assert_equal "1000", Cache.read("atomic")
  assert_equal 500, COUNTS_A.size
  assert_equal 500, COUNTS_B.size
  # Each increment was answered the count it made: 1..1000, each once.
  all = Array.new(0) { 0 }
  COUNTS_A.each { |n| all << n }
  COUNTS_B.each { |n| all << n }
  sorted = all.sort
  expected = Array.new(0) { 0 }
  k = 1
  while k <= 1000
    expected << k
    k += 1
  end
  assert sorted == expected, "the counts answered were not 1..1000 once each"
  # Interleaved: neither thread was answered only its own 500 in a row.
  refute COUNTS_A == expected[0, 500] && COUNTS_B == expected[500, 500]
  refute COUNTS_B == expected[0, 500] && COUNTS_A == expected[500, 500]
end

# What the second add answered (a constant: NOTES rule 64).
SECOND_ADD = Array.new(0) { true }

test "the loser of two concurrent adds of one key answers false" do
  fresh_db
  Cache.install!
  first = DB::Connection.new(URL)
  second = DB::Connection.new(URL)
  first.begin!
  assert DB::Dialect.cache_write(first, "lock", "first", 0, 9000, true)
  # The second add waits for the first's row lock, then finds the key
  # taken: a duplicate key, answered as "not written", not raised.
  other = Thread.new { SECOND_ADD << DB::Dialect.cache_write(second, "lock", "second", 0, 9000, true) }
  sleep 0.2
  assert SECOND_ADD.empty?
  first.commit!
  other.join
  assert_equal [false], SECOND_ADD
  assert_equal "first", Cache.read("lock")
  # The loser's connection is fine, and so is a transaction it had open.
  second.begin!
  refute DB::Dialect.cache_write(second, "lock", "again", 0, 9000, true)
  assert DB::Dialect.cache_write(second, "free", "z", 0, 9000, true)
  second.commit!
  assert_equal "z", Cache.read("free")
  first.close
  second.close
end

# What each of two transactional adds of one expired key answered, or the
# class of what it raised (a constant: NOTES rule 64).
EXPIRED_ADDS = Array.new(0) { "" }

# One add of the expired key "lease-like", inside a transaction held open
# for a moment after it, as a caller's would be.
def add_in_transaction(conn, value)
  conn.begin!
  answered = DB::Dialect.cache_write(conn, "lease-like", value, 0, 9000, true)
  sleep 0.2
  conn.commit!
  EXPIRED_ADDS << (answered ? "true" : "false")
  nil
rescue Cybertrain::DB::Error => e
  EXPIRED_ADDS << e.class.name
  conn.rollback!
  nil
end

# Two adds of one expired key, each in its own transaction on its own
# connection, at once: one replaces the row, the other waits for its lock
# and then finds it live. Neither may be a deadlock (an add that took a
# shared lock on the row and then upgraded it, as a plain INSERT's
# duplicate key followed by an UPDATE does, deadlocked here).
test "two transactional adds of one expired key: one answers true, the other false, no deadlock" do
  fresh_db
  Cache.install!
  assert DB.with { |c| DB::Dialect.cache_write(c, "lease-like", "old", 8010, 8000, false) }
  first = DB::Connection.new(URL)
  second = DB::Connection.new(URL)
  a = Thread.new { add_in_transaction(first, "first") }
  b = Thread.new { add_in_transaction(second, "second") }
  a.join
  b.join
  assert_equal ["false", "true"], EXPIRED_ADDS.sort
  travel_to(Time.at(9000))
  value = Cache.read("lease-like")
  assert value == "first" || value == "second", "the row is #{value.inspect}"
  # A live row inside a transaction: false, and the row as it was.
  first.begin!
  refute DB::Dialect.cache_write(first, "lease-like", "third", 0, 9000, true)
  first.commit!
  assert_equal value, Cache.read("lease-like")
  first.close
  second.close
end

test "a counter goes below zero and back, and by: 0 answers it unchanged" do
  fresh_db
  travel_to(Time.at(8000))
  assert_equal(-5, Cache.increment("neg", by: -5))
  assert_equal "-5", Cache.read("neg")
  assert_equal(-5, Cache.increment("neg", by: 0))
  assert_equal(-12, Cache.increment("neg", by: -7))
  assert_equal 3, Cache.increment("neg", by: 15)
  assert_equal 0, Cache.increment("zero", by: 0)
  assert_equal 0, Cache.increment("zero", by: 0)
  assert_equal "0", Cache.read("zero")
  # 2**62 - 1, the largest count the insert id carries back.
  big = 4_611_686_018_427_387_903
  assert_equal big, Cache.increment("big", by: big)
end

Cybertrain::Test.run!
