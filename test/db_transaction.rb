require "stringio"
require "cybertrain/db"
require "cybertrain/logger"
require "cybertrain/test"

# A pooled connection must come back in autocommit mode (and with
# @transaction_depth at 0) however a `transaction` block ends: normally, by an
# exception, or by leaving a BEGIN open that the method never saw, which
# Pool#with cleans up through Connection#abandon_transaction!. This program
# links SQLite through FFI, so its snapshot must come from the compiled binary
# (NOTES rule 23); the committed one was first captured under CRuby with an
# FFI shim -- run script/regen-snapshot test/db_transaction.rb on a Spinel
# machine. Not exercised on purpose: `return` from inside the block (under
# Spinel it ends the block, not the enclosing method), `break` out of the
# block (Spinel refuses it at compile time -- "unsupported expression:
# BreakNode" -- now that the yield sits inside a rescue), throw/catch and
# Exception subclasses (no precedent for them compiling under Spinel).

DB = Cybertrain::DB

def posts_db
  conn = DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);")
  conn
end

def post_count(conn)
  conn.execute("SELECT COUNT(*) AS n FROM posts")[0]["n"]
end

# True when the connection is back in autocommit mode: a manual BEGIN is
# accepted (a leaked BEGIN refuses it with "cannot start a transaction
# within a transaction"). Deliberately no `transaction` call in here: every
# call of that method in this file keeps the exact shapes test/db_sqlite.rb
# compiles with (NOTES rule 32 -- a call from an unusual block nesting gave
# "assigning to 'volatile sp_RbVal' from incompatible type 'sp_Exception *'"
# at its rescue clauses, CI on PR #10).
def clean?(conn)
  begin_ok = true
  begin
    conn.exec_script("BEGIN")
    conn.exec_script("ROLLBACK")
  rescue DB::Error
    begin_ok = false
  end
  begin_ok
end

# What a block that escapes `transaction` past its rescue would leave behind:
# autocommit off, nothing to COMMIT it. Done by hand, since under Spinel no
# such escape even compiles. Returns the rows visible inside the checkout.
def leave_begin_open(conn)
  conn.exec_script("BEGIN")
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["open"])
  post_count(conn)
end

# A write on the next checkout autocommits again (no `transaction` here, see
# clean?).
def insert_after(conn)
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["after"])
  post_count(conn)
end

# Every DB.with block here is a one-line call into a method, the shape
# test/db_sqlite.rb compiles with.
test "a BEGIN left open inside a checkout is rolled back, and logged, when the connection comes back" do
  log = StringIO.new
  Cybertrain.logger = Cybertrain::Logger.new(log, :info)
  DB.connect(":memory:")
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  assert_equal "", log.string
  # Still inside the checkout the row is there: the BEGIN stays open until
  # the connection goes back, which is what makes the pool the place to
  # clean up -- and the only place that can say the writes are gone.
  assert_equal 1, DB.with { |c| leave_begin_open(c) }
  assert_includes log.string, "[WARN] rolled back a transaction left open on a pooled connection"
  assert_equal 0, DB.with { |c| post_count(c) }
  assert DB.with { |c| clean?(c) }
  assert_equal 1, DB.with { |c| insert_after(c) }
  assert log.string.lines.size == 1, "a clean check-in logs nothing"
  DB.disconnect
end

# A logger whose IO is gone, as at shutdown: the warning cannot be written.
# Returns nil like Logger#warn (same name, same type: NOTES rule 10).
class BrokenLogger < Cybertrain::Logger
  def warn(msg)
    raise "log IO closed" unless msg.empty?
    nil
  end
end

test "a BEGIN run and rolled back by hand is a clean check-in: no warning" do
  log = StringIO.new
  Cybertrain.logger = Cybertrain::Logger.new(log, :info)
  DB.connect(":memory:")
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  DB.with { |c| c.exec_script("BEGIN"); c.exec_script("ROLLBACK") }
  assert_equal "", log.string
  DB.disconnect
end

# The message of whatever a leaked BEGIN raises through the broken logger
# ("" when nothing was raised, which is the expected outcome: check_in drops
# the logging failure). A method of its own rather than
# `assert_raises { DB.with { ... } }`: with the checkout nested in another
# block, Spinel typed the block's return path wrongly in the generated C
# ("incompatible types when returning type 'sp_RbVal' but 'sp_int' was
# expected"), NOTES rule 32 again.
def leak_through_broken_logger
  message = ""
  begin
    DB.with { |c| leave_begin_open(c) }
  rescue RuntimeError => e
    message = e.message
  end
  message
end

# The checks of the test below, in a method so the test block itself holds
# only the begin/ensure that restores the logger (NOTES rule 32: the fewer
# yielding calls inside a block with its own ensure, the better).
def pool_survives_broken_logger
  DB.connect(":memory:")
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  # The logger's "log IO closed" does not escape check_in (it would replace
  # whatever the block was propagating), so nothing is raised here.
  assert_equal "", leak_through_broken_logger
  # The leaked BEGIN was still rolled back: its row is gone.
  # The ":memory:" pool has one connection: a leak would park this forever.
  assert_equal 0, DB.with { |c| post_count(c) }
  assert DB.with { |c| clean?(c) }
  DB.disconnect
  nil
end

test "a logger that fails while check-in reports a leaked BEGIN is swallowed and the connection still goes back" do
  Cybertrain.logger = BrokenLogger.new
  begin
    pool_survives_broken_logger
  ensure
    # Restored even when an assertion above fails, or every later test that
    # trips a pool warning would die with "log IO closed".
    Cybertrain.logger = Cybertrain::Logger.new
  end
  # Not the begin/ensure's value: as a block's last expression it does not
  # type under Spinel ("incompatible types when returning type 'sp_RbVal'").
  nil
end

# A file-backed database for the reopen test: closing the one ":memory:"
# connection would drop the database itself, which is exactly why the pool
# never closes that one.
REOPEN_DB = "tmp/db_transaction_reopen.sqlite3"

def remove_reopen_db
  [REOPEN_DB, REOPEN_DB + "-wal", REOPEN_DB + "-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

test "a slot whose connection was closed is reopened on the next checkout" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  remove_reopen_db
  DB.connect(REOPEN_DB, size: 1)
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  assert_equal 1, DB.with { |c| insert_after(c) }
  # What check_in does after a failed ROLLBACK: the slot's connection is
  # closed. The next checkout must not get a closed handle.
  DB.with { |c| c.close }
  assert_equal 1, DB.with { |c| post_count(c) }
  assert DB.with { |c| clean?(c) }
  DB.disconnect
  remove_reopen_db
end

# The error the next checkout raises once the one :memory: connection was
# closed ("" when it did not raise). A method, not an assert_raises block
# around DB.with (NOTES rule 32).
def checkout_after_close
  message = ""
  begin
    DB.with { |c| post_count(c) }
  rescue DB::Error => e
    message = e.message
  end
  message
end

test "a closed :memory: connection is an error on the next checkout, never a fresh database" do
  DB.connect(":memory:")
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  DB.with { |c| c.close }
  assert_includes checkout_after_close, "the in-memory or temporary connection was closed"
  # And again: the slot stays in the pool, the error repeats, nothing hangs.
  assert_includes checkout_after_close, "the in-memory or temporary connection was closed"
  DB.disconnect
end

# The error a checkout raises on a pool that close_all shut down ("" when it
# did not raise). A method, not an assert_raises block around Pool#with
# (NOTES rule 32).
def checkout_after_close_all(pool)
  message = ""
  begin
    pool.with { |c| 1 }
  rescue DB::Error => e
    message = e.message
  end
  message
end

test "a pool that close_all shut down refuses every checkout instead of reopening" do
  pool = DB::Pool.new(":memory:")
  pool.close_all
  assert_equal "pool closed", checkout_after_close_all(pool)
  # And again: it raises before touching the queue, so it cannot hang.
  assert_equal "pool closed", checkout_after_close_all(pool)
end

test "every in-memory or temporary spelling is a one-connection, non-reopenable pool" do
  assert_equal 1, DB::Pool.new(":memory:", 4).size
  assert_equal 1, DB::Pool.new("file::memory:", 4).size
  assert_equal 1, DB::Pool.new("file:x?mode=memory&cache=shared", 4).size
  assert_equal 1, DB::Pool.new("", 4).size
  assert DB::Connection.private_database?(":memory:")
  assert DB::Connection.private_database?("")
  assert DB::Connection.private_database?("file::memory:?cache=shared")
  assert DB::Connection.private_database?("file:x?mode=memory")
  refute DB::Connection.private_database?("storage/dev.sqlite3")
  refute DB::Connection.private_database?("file:storage/dev.sqlite3")
  refute DB::Connection.private_database?("memory.sqlite3")
  # A closed connection on such a pool is an error, not a fresh empty database.
  pool = DB::Pool.new("file::memory:", 4)
  pool.with { |c| c.close }
  assert_includes checkout_after_close_all(pool), "the in-memory or temporary connection was closed"
end

test "a private connection (any spelling) opens, works and is not put in WAL" do
  [":memory:", "file::memory:?cache=shared", "file:x?mode=memory", ""].each do |path|
    conn = DB::Connection.new(path)
    conn.exec_script("CREATE TABLE t (id INTEGER PRIMARY KEY); INSERT INTO t DEFAULT VALUES;")
    assert_equal 1, conn.execute("SELECT COUNT(*) AS n FROM t")[0]["n"]
    refute conn.execute("PRAGMA journal_mode")[0]["journal_mode"].to_s == "wal"
    conn.close
  end
end

# Two slots closed at once: A still checked out when user code closes it, B
# checked out inside it and closed too. B goes back first, so the queue holds
# B then A. Each reopen must replace its own entry in the pool's list: the
# pool afterwards serves `size` distinct working connections and close_all
# closes all of them. Named methods hold the nested checkouts (rules 32/45),
# and only behaviour is observed (no instance_variable_get, rule 1).
def close_inner_and_outer(pool, outer)
  pool.with { |inner| (outer.close; inner.close; 0) }
end

def close_two_slots(pool)
  pool.with { |outer| close_inner_and_outer(pool, outer) }
end

# 0 when the second checkout got the same connection as the first, else the
# post count seen through both (2 * the rows inserted).
def distinct_second_checkout(pool, first)
  pool.with { |second| second.equal?(first) ? 0 : post_count(first) + post_count(second) }
end

def distinct_checkouts(pool)
  pool.with { |first| distinct_second_checkout(pool, first) }
end

test "two closed slots, one checked out and one queued, are both reopened and both closed by close_all" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  remove_reopen_db
  pool = DB::Pool.new(REOPEN_DB, 2)
  assert_equal 2, pool.size
  pool.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  assert_equal 1, pool.with { |c| insert_after(c) }
  close_two_slots(pool)
  # Each checkout reopens the closed slot it pops.
  assert_equal 1, pool.with { |c| post_count(c) }
  assert_equal 1, pool.with { |c| post_count(c) }
  assert pool.with { |c| clean?(c) }
  # Both slots serve at once, as two different working connections.
  assert_equal 2, distinct_checkouts(pool)
  # close_all succeeds on the reopened list, the pool refuses afterwards, and
  # a second close_all is harmless.
  pool.close_all
  assert_equal "pool closed", checkout_after_close_all(pool)
  pool.close_all
  remove_reopen_db
end

test "abandon_transaction! leaves a clean connection alone and says so" do
  conn = posts_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["kept"])
  assert conn.abandon_transaction! == :clean, "a clean connection reports :clean"
  assert_equal 1, post_count(conn)
  conn.exec_script("BEGIN")
  assert conn.abandon_transaction! == :rolled_back, "an open BEGIN reports :rolled_back"
  assert conn.abandon_transaction! == :clean, "and the connection is clean again"
  assert clean?(conn)
  conn.close
end

test "a StandardError rolls back, re-raises and leaves autocommit on" do
  conn = posts_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["kept"])
  message = assert_raises("RuntimeError") do
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["lost"])
      raise "boom"
    end
  end
  assert_equal "boom", message
  assert_equal 1, post_count(conn)
  assert clean?(conn)
  conn.close
end

test "a normal completion commits" do
  conn = posts_db
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["one"])
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["two"])
  end
  assert_equal 2, post_count(conn)
  assert clean?(conn)
  conn.close
end

test "a nested transaction joins the outer one and an inner raise rolls everything back" do
  conn = posts_db
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["outer"])
    conn.transaction { conn.execute("INSERT INTO posts (title) VALUES (?)", ["inner"]) }
  end
  assert_equal 2, post_count(conn)
  assert_raises("RuntimeError") do
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["outer2"])
      conn.transaction do
        conn.execute("INSERT INTO posts (title) VALUES (?)", ["inner2"])
        raise "inner"
      end
    end
  end
  assert_equal 2, post_count(conn)
  assert clean?(conn)
  conn.close
end

# A `break`/`return` out of an outer block (CRuby only) cannot be driven
# portably: Spinel refuses to compile the `break`, and a `return` there just
# ends the block and commits (NOTES rules 44, 50). What both runtimes share
# is checked here: a normal, a raised and another normal transaction in a
# row, and abandon_transaction! leaving the connection able to start a
# transaction again after a BEGIN run by hand.
test "a transaction after a normal or a raised one, and after abandon_transaction!, still commits" do
  conn = posts_db
  conn.transaction { conn.execute("INSERT INTO posts (title) VALUES (?)", ["one"]) }
  assert_raises("RuntimeError") do
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["lost"])
      raise "boom"
    end
  end
  conn.transaction { conn.execute("INSERT INTO posts (title) VALUES (?)", ["two"]) }
  assert_equal 2, post_count(conn)
  leave_begin_open(conn)
  assert conn.abandon_transaction! == :rolled_back, "the hand-run BEGIN is rolled back"
  conn.transaction { conn.execute("INSERT INTO posts (title) VALUES (?)", ["three"]) }
  assert_equal 3, post_count(conn)
  assert clean?(conn)
  conn.close
end

Cybertrain::Test.run!
