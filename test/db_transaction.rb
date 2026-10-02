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

# The message of the RuntimeError a leaked BEGIN raises through the broken
# logger ("" when nothing was raised). A method of its own rather than
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

test "the connection goes back to the pool even when the leak warning cannot be logged" do
  Cybertrain.logger = BrokenLogger.new
  DB.connect(":memory:")
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  assert_equal "log IO closed", leak_through_broken_logger
  # The ":memory:" pool has one connection: a leak would park this forever.
  assert_equal 0, DB.with { |c| post_count(c) }
  assert DB.with { |c| clean?(c) }
  DB.disconnect
  Cybertrain.logger = Cybertrain::Logger.new
end

test "abandon_transaction! leaves a clean connection alone" do
  conn = posts_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["kept"])
  conn.abandon_transaction!
  assert_equal 1, post_count(conn)
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

Cybertrain::Test.run!
