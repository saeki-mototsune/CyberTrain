require "cybertrain/db"
require "cybertrain/test"

# A pooled connection must come back in autocommit mode (and with
# @transaction_depth at 0) however a `transaction` block ends: normally, by an
# exception, or by `break`, which the method's rescue never sees and
# Pool#with cleans up through Connection#abandon_transaction!. This program
# links SQLite through FFI, so its snapshot must come from the compiled binary
# (NOTES rule 23); the committed one was first captured under CRuby with an
# FFI shim -- run script/regen-snapshot test/db_transaction.rb on a Spinel
# machine. Not exercised on purpose: `return` from inside the block (under
# Spinel it ends the block, not the enclosing method), throw/catch and
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

# True when the connection is back in autocommit mode with depth 0: a raising
# transaction rolls back (a stuck depth would treat it as nested and keep the
# row) and a manual BEGIN is accepted (a leaked BEGIN refuses it).
def clean?(conn)
  before = post_count(conn)
  begin
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["probe"])
      raise "probe"
    end
  rescue StandardError
    nil
  end
  rolled_back = post_count(conn) == before
  begin_ok = true
  begin
    conn.exec_script("BEGIN")
    conn.exec_script("ROLLBACK")
  rescue DB::Error
    begin_ok = false
  end
  rolled_back && begin_ok
end

test "a transaction left by break is rolled back when the pooled connection comes back" do
  DB.connect(":memory:")
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);") }
  DB.with do |c|
    # The `break` sits inside an each: Spinel compiles a block's `break`
    # only within an iterator ("unsupported expression: BreakNode" for a
    # bare one, CI on PR #10); the shape is the one test/db_sqlite.rb uses.
    [1].each do |_|
      c.transaction do
        c.execute("INSERT INTO posts (title) VALUES (?)", ["broken"])
        break
      end
    end
    # Still inside the checkout: the BEGIN is open until the connection
    # goes back, which is what makes the pool the right place to clean up.
    assert_equal 1, post_count(c)
  end
  DB.with do |c|
    assert_equal 0, post_count(c)
    assert clean?(c)
    c.transaction { c.execute("INSERT INTO posts (title) VALUES (?)", ["after"]) }
    assert_equal 1, post_count(c)
  end
  DB.disconnect
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

test "a nested non-local exit leaves the outer transaction usable" do
  conn = posts_db
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["outer"])
    [1].each do |n|
      conn.transaction do
        conn.execute("INSERT INTO posts (title) VALUES (?)", ["inner#{n}"])
        break
      end
    end
  end
  assert_equal 2, post_count(conn)
  assert clean?(conn)
  conn.close
end

Cybertrain::Test.run!
