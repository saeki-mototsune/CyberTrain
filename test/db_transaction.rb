require "cybertrain/db"
require "cybertrain/test"

# Connection#transaction must leave the connection in autocommit mode (and
# @transaction_depth at 0) however its block ends: normally, by an exception,
# or by a non-local exit (return / break). This program links SQLite through
# FFI, so its snapshot must come from the compiled binary (NOTES rule 23); the
# committed one was first captured under CRuby with an FFI shim -- run
# script/regen-snapshot test/db_transaction.rb on a Spinel machine.
# (throw/catch and Exception subclasses are deliberately not exercised: the
# repo has no precedent for them compiling under Spinel.)

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

def leave_by_return(conn)
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["returned"])
    return 7
  end
  8
end

test "return from inside a transaction rolls back and leaves autocommit on" do
  conn = posts_db
  assert_equal 7, leave_by_return(conn)
  assert_equal 0, post_count(conn)
  assert clean?(conn)
  conn.transaction { conn.execute("INSERT INTO posts (title) VALUES (?)", ["after"]) }
  assert_equal 1, post_count(conn)
  conn.close
end

test "break out of a transaction rolls back and leaves autocommit on" do
  conn = posts_db
  [1, 2, 3].each do |n|
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["n#{n}"])
      break if n == 1
    end
    break
  end
  assert_equal 0, post_count(conn)
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
