require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/db/schema_dumper"
require "cybertrain/lease"
require "cybertrain/test"
require_relative "support/tables"
require_relative "support/services"

# test/lease.rb on MySQL, against the server CYBERTRAIN_TEST_MYSQL_URL names
# (script/test-mysql runs this program): the same tests and the same
# snapshot (test/lease.rb.expected's ok lines), so Lease.acquire takes a
# free lease, refuses another holder until it expires, renews and hands
# over on MySQL as on SQLite, then MySQL's own test of why acquire reads
# the holder back rather than its `changes` (DB::Dialect.lease_acquire).
#
# What differs from the original is marked where it is:
# - the database: each test starts with MySQLServices.fresh_db (the
#   framework tables dropped, so the next use creates them, as SQLite's
#   DB.connect(":memory:") starts empty); the cybertrain_* tables are the
#   framework's own MySQL DDL (DB::Dialect.lease_table_sql).
# - "exception: shared database" where the original reads the whole schema
#   dump of a database that holds nothing else: here only this program's
#   tables are looked for in it.

DB = Cybertrain::DB
Lease = Cybertrain::Lease

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

OWN_TABLES = ["ct_lease_posts"]

def fresh_db
  MySQLServices.fresh_db(URL, OWN_TABLES)
end

fresh_db

test "a free lease is taken; another holder waits for it to expire; the holder renews" do
  assert Lease.acquire("scheduler", "a", 100, ttl: 30)
  assert_equal "a", Lease.lease_holder("scheduler")
  assert_equal 130, Lease.lease_expires_at("scheduler")
  refute Lease.acquire("scheduler", "b", 110, ttl: 30)
  assert_equal "a", Lease.lease_holder("scheduler")
  assert Lease.acquire("scheduler", "a", 110, ttl: 30)
  assert_equal 140, Lease.lease_expires_at("scheduler")
  # Not yet expired at 140 itself; expired at 141.
  refute Lease.acquire("scheduler", "b", 140, ttl: 30)
  assert Lease.acquire("scheduler", "b", 141, ttl: 30)
  assert_equal "b", Lease.lease_holder("scheduler")
  refute Lease.acquire("scheduler", "a", 142, ttl: 30)
end

test "a renewal moves the expiry: at 131 the lease renewed at 110 is still held" do
  fresh_db
  assert Lease.acquire("scheduler", "a", 100, ttl: 30)
  refute Lease.acquire("scheduler", "b", 110, ttl: 30)
  assert Lease.acquire("scheduler", "a", 110, ttl: 30)
  refute Lease.acquire("scheduler", "b", 131, ttl: 30)
  assert Lease.acquire("scheduler", "b", 141, ttl: 30)
end

test "release frees the lease at once, and only for its holder" do
  fresh_db
  assert Lease.acquire("scheduler", "b", 100, ttl: 30)
  Lease.release("scheduler", "a")
  assert_equal "b", Lease.lease_holder("scheduler")
  refute Lease.acquire("scheduler", "a", 101, ttl: 30)
  Lease.release("scheduler", "b")
  assert_equal "", Lease.lease_holder("scheduler")
  assert_equal 0, Lease.lease_expires_at("scheduler")
  assert Lease.acquire("scheduler", "a", 101, ttl: 30)
end

test "leases of different names are independent" do
  fresh_db
  assert Lease.acquire("scheduler", "a", 100, ttl: 30)
  assert Lease.acquire("other", "b", 100, ttl: 30)
  assert_equal "a", Lease.lease_holder("scheduler")
  assert_equal "b", Lease.lease_holder("other")
end

test "install! is idempotent and the table stays out of the schema dump" do
  fresh_db
  Lease.install!
  Lease.install!
  assert Lease.acquire("scheduler", "a", 100, ttl: 30)
  Lease.install!
  assert_equal "a", Lease.lease_holder("scheduler")
  DB.with { |c| c.exec_script("CREATE TABLE ct_lease_posts (id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, title MEDIUMTEXT)") }
  # exception: shared database (the original: "posts" is the whole dump).
  assert_equal "ct_lease_posts", MySQLServices.dumped(["cybertrain_leases", "ct_lease_posts"])
end

test "acquire without a database is a DB::Error" do
  DB.disconnect
  assert_includes assert_raises("DB::Error") { Lease.acquire("scheduler", "a", 100, ttl: 30) }, "not connected"
end

# MySQL's own: the upsert's `changes`, which SQLite's acquire answers by,
# cannot tell "acquired" from "held by someone else" on MySQL. The session
# sets CLIENT_FOUND_ROWS (changes counts the rows matched), and an INSERT
# ... ON DUPLICATE KEY UPDATE then counts 1 for a new row, 2 for an
# updated one, and 1 for a found row set to its own values: a new lease
# and a lease another holder keeps both count 1, and a renewal that moves
# nothing counts 1 too. So DB::Dialect.lease_acquire reads the holder back.
test "the acquire upsert's changes count 1 both for a new lease and for one another holder keeps" do
  fresh_db
  Lease.install!
  counts = Array.new(0) { 0 }
  DB.with do |c|
    [["a", 130, 100], ["a", 130, 100], ["a", 140, 110], ["b", 140, 120], ["b", 171, 141]].each do |row|
      c.execute(DB::Dialect::LEASE_ACQUIRE_SQL, Cybertrain::Cast.binds("scheduler", row[0], row[1], row[2]))
      counts << c.changes
    end
  end
  # new, renewed unchanged, renewed, kept by "a" (refused), taken over
  assert_equal [1, 1, 2, 1, 2], counts
  assert_equal "b", Lease.lease_holder("scheduler")
  assert_equal 171, Lease.lease_expires_at("scheduler")
  # What acquire answers for the same five calls, from the read-back.
  fresh_db
  answers = Array.new(0) { false }
  answers << Lease.acquire("scheduler", "a", 100, ttl: 30)
  answers << Lease.acquire("scheduler", "a", 100, ttl: 30)
  answers << Lease.acquire("scheduler", "a", 110, ttl: 30)
  answers << Lease.acquire("scheduler", "b", 120, ttl: 20)
  answers << Lease.acquire("scheduler", "b", 141, ttl: 30)
  assert_equal [true, true, true, false, true], answers
end

Cybertrain::Test.run!
