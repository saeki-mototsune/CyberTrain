require "cybertrain/db"
require "cybertrain/test"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB

def posts_db
  conn = DB::Connection.new(":memory:")
  conn.exec_script(
    "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, " \
    "views INTEGER, rating REAL, published INTEGER, published_at TEXT);"
  )
  conn
end

def post_count(conn)
  conn.execute("SELECT COUNT(*) AS n FROM posts")[0]["n"]
end

test "creates a table" do
  conn = posts_db
  rows = conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'posts'")
  assert_equal 1, rows.size
  assert_equal "posts", rows[0]["name"]
  conn.close
end

test "binds Integer, Float, String, nil, true and Time and reads back Ruby types" do
  conn = posts_db
  at = Time.utc(2026, 9, 24, 12, 30, 5)
  conn.execute(
    "INSERT INTO posts (title, views, rating, published, published_at) VALUES (?, ?, ?, ?, ?)",
    ["hello", 10, 4.5, true, at]
  )
  conn.execute("INSERT INTO posts (title, views, rating, published) VALUES (?, ?, ?, ?)",
               ["draft", nil, nil, false])
  rows = conn.execute("SELECT title, views, rating, published, published_at FROM posts ORDER BY id")
  row = rows[0]
  assert_equal "String", row["title"].class.name
  assert_equal "hello", row["title"]
  assert_equal "Integer", row["views"].class.name
  assert_equal 10, row["views"]
  assert_equal "Float", row["rating"].class.name
  assert_equal 4.5, row["rating"]
  assert_equal 1, row["published"]
  assert_equal "2026-09-24T12:30:05Z", row["published_at"]
  draft = rows[1]
  assert_nil draft["views"]
  assert_nil draft["rating"]
  assert_equal 0, draft["published"]
  assert_nil draft["published_at"]
  conn.close
end

test "a Time bind in another zone is stored as the UTC ISO string" do
  conn = posts_db
  at = Time.new(2026, 9, 24, 21, 0, 0, "+09:00")
  conn.execute("INSERT INTO posts (title, published_at) VALUES (?, ?)", ["tokyo", at])
  assert_equal "2026-09-24T12:00:00Z", conn.execute("SELECT published_at FROM posts")[0]["published_at"]
  conn.close
end

test "round-trips unicode text" do
  conn = posts_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["こんにちは、世界 — café ☕"])
  assert_equal "こんにちは、世界 — café ☕", conn.execute("SELECT title FROM posts")[0]["title"]
  conn.close
end

test "changes counts the rows touched by the last UPDATE" do
  conn = posts_db
  conn.execute("INSERT INTO posts (title, views) VALUES (?, ?)", ["a", 1])
  conn.execute("INSERT INTO posts (title, views) VALUES (?, ?)", ["b", 1])
  conn.execute("INSERT INTO posts (title, views) VALUES (?, ?)", ["c", 2])
  conn.execute("UPDATE posts SET views = views + 1 WHERE views = ?", [1])
  assert_equal 2, conn.changes
  conn.close
end

test "last_insert_id returns the new row id" do
  conn = posts_db
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["first"])
  assert_equal 1, conn.last_insert_id
  conn.execute("INSERT INTO posts (title) VALUES (?)", ["second"])
  assert_equal 2, conn.last_insert_id
  conn.close
end

test "a syntax error raises DB::Error including the SQL" do
  conn = posts_db
  message = assert_raises("Cybertrain::DB::Error") { conn.execute("SELEC nonsense FROM posts") }
  assert_includes message, "syntax error"
  assert_includes message, "(sql: SELEC nonsense FROM posts)"
  message = assert_raises("Cybertrain::DB::Error") { conn.exec_script("CREATE TABLE posts (id INTEGER);") }
  assert_includes message, "already exists"
  conn.close
end

test "transaction commits" do
  conn = posts_db
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["one"])
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["two"])
  end
  assert_equal 2, post_count(conn)
  conn.close
end

test "transaction rolls back when the block raises and re-raises" do
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
  conn.close
end

test "nested transaction joins the outer one" do
  conn = posts_db
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["outer"])
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["inner"])
    end
  end
  assert_equal 2, post_count(conn)
  assert_raises("RuntimeError") do
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["outer"])
      conn.transaction do
        conn.execute("INSERT INTO posts (title) VALUES (?)", ["inner"])
        raise "inner failure"
      end
    end
  end
  assert_equal 2, post_count(conn)
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["after"])
  end
  assert_equal 3, post_count(conn)
  conn.close
end

test "a failed COMMIT rolls back and the next transaction works" do
  conn = posts_db
  conn.exec_script(
    "CREATE TABLE notes (id INTEGER PRIMARY KEY, post_id INTEGER, " \
    "FOREIGN KEY(post_id) REFERENCES posts(id) DEFERRABLE INITIALLY DEFERRED);"
  )
  message = assert_raises("Cybertrain::DB::Error") do
    conn.transaction do
      conn.execute("INSERT INTO notes (post_id) VALUES (?)", [42])
    end
  end
  assert_includes message, "FOREIGN KEY"
  assert_includes message, "(sql: COMMIT)"
  assert_equal 0, conn.execute("SELECT COUNT(*) AS n FROM notes")[0]["n"]
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["after"])
  end
  assert_equal 1, post_count(conn)
  conn.close
end

test "the block's exception survives when SQLite already rolled back" do
  conn = posts_db
  message = assert_raises("RuntimeError") do
    conn.transaction do
      conn.execute("INSERT INTO posts (title) VALUES (?)", ["gone"])
      conn.exec_script("ROLLBACK")
      raise "original failure"
    end
  end
  assert_equal "original failure", message
  assert_equal 0, post_count(conn)
  conn.transaction do
    conn.execute("INSERT INTO posts (title) VALUES (?)", ["after"])
  end
  assert_equal 1, post_count(conn)
  conn.close
end

test "PRAGMA table_info and foreign_key_list rows" do
  conn = posts_db
  conn.exec_script(
    "CREATE TABLE comments (id INTEGER PRIMARY KEY, post_id INTEGER NOT NULL, body TEXT, " \
    "FOREIGN KEY(post_id) REFERENCES posts(id));"
  )
  cols = conn.execute("PRAGMA table_info(posts)")
  assert_equal 6, cols.size
  assert_equal "id", cols[0]["name"]
  assert_equal "INTEGER", cols[0]["type"]
  assert_equal 1, cols[0]["pk"]
  assert_equal "title", cols[1]["name"]
  assert_equal "TEXT", cols[1]["type"]
  assert_equal "REAL", cols[3]["type"]
  fks = conn.execute("PRAGMA foreign_key_list(comments)")
  assert_equal 1, fks.size
  assert_equal "posts", fks[0]["table"]
  assert_equal "post_id", fks[0]["from"]
  assert_equal "id", fks[0]["to"]
  message = assert_raises("Cybertrain::DB::Error") do
    conn.execute("INSERT INTO comments (post_id, body) VALUES (?, ?)", [99, "orphan"])
  end
  assert_includes message, "FOREIGN KEY"
  conn.close
end

test "SELECT name, sql FROM sqlite_master" do
  conn = posts_db
  rows = conn.execute("SELECT name, sql FROM sqlite_master WHERE type = 'table' ORDER BY name")
  names = rows.map { |r| r["name"].to_s }
  assert_equal ["posts", "sqlite_sequence"], names
  assert_includes rows[0]["sql"].to_s, "CREATE TABLE posts"
  conn.close
end

test "close marks the connection closed" do
  conn = DB::Connection.new(":memory:")
  assert_equal ":memory:", conn.path
  refute conn.closed?
  conn.close
  assert conn.closed?
  conn.close
  assert conn.closed?
end

test "a closed connection raises instead of touching the freed handle" do
  conn = posts_db
  conn.close
  message = assert_raises("Cybertrain::DB::Error") { conn.execute("SELECT 1") }
  assert_equal "connection closed (sql: SELECT 1)", message
  message = assert_raises("Cybertrain::DB::Error") { conn.exec_script("SELECT 2") }
  assert_equal "connection closed (sql: SELECT 2)", message
  assert_raises("Cybertrain::DB::Error") { conn.changes }
  assert_raises("Cybertrain::DB::Error") { conn.last_insert_id }
  assert_raises("Cybertrain::DB::Error") { conn.transaction { conn.execute("SELECT 3") } }
end

test "an unopenable path raises with SQLite's error message" do
  message = assert_raises("Cybertrain::DB::Error") do
    DB::Connection.new("tmp/no_such_dir_db_sqlite/x.sqlite3")
  end
  assert_includes message, "tmp/no_such_dir_db_sqlite/x.sqlite3"
  assert_includes message, "unable to open database file"
end

# Open file descriptors of this process, -1 where /proc/self/fd does not
# exist (the leak check below then compares -1 with -1 and still passes).
def open_fd_count
  return -1 unless Dir.exist?("/proc/self/fd")
  Dir.children("/proc/self/fd").size
end

# Connection.new opens fine on a file that is not a database; the first
# PRAGMA is what fails ("file is not a database"). The half-built connection
# is never returned, so initialize has to close its handle: a Pool slot in
# quarantine reopens on every checkout, and a leak here is one descriptor
# per request until EMFILE.
def refused_by_pragma(path)
  DB::Connection.new(path)
  ""
rescue DB::Error => e
  e.message
end

test "a PRAGMA that fails in Connection.new closes the handle it opened" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/db_sqlite_not_a_database.txt"
  File.write(path, "this is not a SQLite database file, just text " * 40)
  message = refused_by_pragma(path)
  assert_includes message, "file is not a database"
  before = open_fd_count
  20.times { refused_by_pragma(path) }
  after = open_fd_count
  File.delete(path)
  assert_equal before, after
end

# Pool#initialize rescues a failed open, closes the slots already opened
# and re-raises. A file that is not a database fails every slot at its first
# PRAGMA, so here nothing is left to close: the test only exercises the
# rescue path and checks the error and the descriptors. (Slot k > 0 failing
# after slot 0 opened needs Connection.new stubbed; that was checked with a
# throwaway CRuby script, 30 descriptors leaked without the rescue, none with.)
def pool_refused(path)
  DB::Pool.new(path, 4)
  ""
rescue DB::Error => e
  e.message
end

test "a Pool that cannot open its connections raises and leaks no descriptor" do
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  path = "tmp/db_sqlite_pool_not_a_database.txt"
  File.write(path, "this is not a SQLite database file, just text " * 40)
  message = pool_refused(path)
  assert_includes message, "file is not a database"
  before = open_fd_count
  10.times { pool_refused(path) }
  after = open_fd_count
  File.delete(path)
  assert_equal before, after
end

test "DB.with before DB.connect raises not connected" do
  refute DB.connected?
  # Caught by hand: DB.with inlined straight into an assert_raises block
  # miscompiles under Spinel 2026.09.12 (C "returning sp_RbVal from a
  # function with result type sp_int").
  message = ""
  begin
    DB.with { |c| c.execute("SELECT 1").size }
  rescue DB::Error => e
    message = e.message
  end
  assert_includes message, "not connected"
end

test "DB.connect(\":memory:\") shares one database across DB.with calls" do
  pool = DB.connect(":memory:")
  assert_equal 1, pool.size
  DB.with { |c| c.exec_script("CREATE TABLE t (x INTEGER);") }
  5.times do |i|
    DB.with { |c| c.execute("INSERT INTO t (x) VALUES (?)", [i]) }
  end
  total = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM t")[0]["n"] }
  assert_equal 5, total
  DB.disconnect
  refute DB.connected?
end

POOL_PATH = "tmp/db_sqlite_test.sqlite3"

def reset_pool_file
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  [POOL_PATH, POOL_PATH + "-wal", POOL_PATH + "-shm"].each do |f|
    File.delete(f) if File.exist?(f)
  end
end

test "pool: 8 threads x 100 inserts through DB.with" do
  reset_pool_file
  pool = DB.connect(POOL_PATH, size: 4)
  assert DB.connected?
  assert_equal 4, pool.size
  DB.with { |c| c.exec_script("CREATE TABLE hits (id INTEGER PRIMARY KEY, worker INTEGER, seq INTEGER);") }
  mode = DB.with { |c| c.execute("PRAGMA journal_mode")[0]["journal_mode"].to_s }
  assert_equal "wal", mode
  threads = []
  8.times do |worker|
    threads << Thread.new do
      100.times do |seq|
        DB.with { |c| c.execute("INSERT INTO hits (worker, seq) VALUES (?, ?)", [worker, seq]) }
      end
    end
  end
  threads.each(&:join)
  total = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM hits")[0]["n"] }
  assert_equal 800, total
  per_worker = DB.with { |c| c.execute("SELECT COUNT(DISTINCT worker) AS n FROM hits")[0]["n"] }
  assert_equal 8, per_worker
  DB.disconnect
  refute DB.connected?
end

test "DB.connect, DB.with and DB.disconnect" do
  reset_pool_file
  refute DB.connected?
  pool = DB.connect(POOL_PATH, size: 2)
  assert_equal 2, pool.size
  assert DB.pool == pool
  DB.with { |c| c.exec_script("CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('hi');") }
  body = DB.with { |c| c.execute("SELECT body FROM notes")[0]["body"] }
  assert_equal "hi", body
  DB.disconnect
  refute DB.connected?
  reset_pool_file
end

Cybertrain::Test.run!
