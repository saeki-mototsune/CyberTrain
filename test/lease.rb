require "cybertrain"
require "cybertrain/test"

# Cybertrain::Lease: a free lease is taken, another holder is refused
# until it expires, the holder renews its own, a released lease is free at
# once, install! can run twice, and the table stays out of the schema
# dump. Compiled with the whole framework (NOTES rule 41); it links SQLite
# through FFI, so its snapshot comes from the compiled binary (rule 23).

DB = Cybertrain::DB
Lease = Cybertrain::Lease

def dumped_tables
  DB.with { |c| DB::SchemaDumper.table_names(c) }
end

DB.connect(":memory:")

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
  DB.connect(":memory:")
  assert Lease.acquire("scheduler", "a", 100, ttl: 30)
  refute Lease.acquire("scheduler", "b", 110, ttl: 30)
  assert Lease.acquire("scheduler", "a", 110, ttl: 30)
  refute Lease.acquire("scheduler", "b", 131, ttl: 30)
  assert Lease.acquire("scheduler", "b", 141, ttl: 30)
end

test "release frees the lease at once, and only for its holder" do
  DB.connect(":memory:")
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
  DB.connect(":memory:")
  assert Lease.acquire("scheduler", "a", 100, ttl: 30)
  assert Lease.acquire("other", "b", 100, ttl: 30)
  assert_equal "a", Lease.lease_holder("scheduler")
  assert_equal "b", Lease.lease_holder("other")
end

test "install! is idempotent and the table stays out of the schema dump" do
  DB.connect(":memory:")
  Lease.install!
  Lease.install!
  assert Lease.acquire("scheduler", "a", 100, ttl: 30)
  Lease.install!
  assert_equal "a", Lease.lease_holder("scheduler")
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT);") }
  assert_equal "posts", dumped_tables.join(",")
end

test "acquire without a database is a DB::Error" do
  DB.disconnect
  assert_includes assert_raises("DB::Error") { Lease.acquire("scheduler", "a", 100, ttl: 30) }, "not connected"
end

Cybertrain::Test.run!
