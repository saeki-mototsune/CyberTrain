require "cybertrain/test"
require "cybertrain/db"
require "cybertrain/db/normalizer"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

def normalize_db
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY, created_at DATETIME, note TEXT)")
  cells = ["2026-10-05T09:00:00Z", "2026-10-05 09:00:00.12", "2026-10-05T09:00:00+09:00",
           "2026-10-05 09:00:00.123456", "garbage"]
  cells.each do |cell|
    conn.execute("INSERT INTO posts (created_at, note) VALUES (?, ?)", [cell, "2026-10-05T09:00:00Z"])
  end
  conn.execute("INSERT INTO posts (created_at, note) VALUES (NULL, 'none')")
  conn
end

def created_ats(conn)
  out = Array.new(0) { "" }
  conn.execute("SELECT created_at FROM posts WHERE created_at IS NOT NULL ORDER BY id").each do |r|
    out << r["created_at"].to_s
  end
  out
end

test "normalize rewrites every non-canonical datetime once, leaves canonical rows, and is idempotent" do
  conn = normalize_db
  first = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 1, first.size
  assert_equal "posts", first[0][0].to_s
  assert_equal "created_at", first[0][1].to_s
  assert_equal 3, first[0][2].to_i
  assert_equal 1, first[0][3].to_i
  assert_equal ["2026-10-05 09:00:00.000000", "2026-10-05 09:00:00.120000",
                "2026-10-05 00:00:00.000000", "2026-10-05 09:00:00.123456", "garbage"], created_ats(conn)
  notes = conn.execute("SELECT note FROM posts WHERE id = 1")
  assert_equal "2026-10-05T09:00:00Z", notes[0]["note"].to_s
  second = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 1, second.size
  assert_equal 0, second[0][2].to_i
  assert_equal 1, second[0][3].to_i
  conn.close
end

test "normalized values sort with Rails-format values by time" do
  conn = normalize_db
  Cybertrain::DB::Normalizer.run(conn)
  rows = conn.execute("SELECT created_at FROM posts WHERE created_at LIKE '2026-10-05 09:00:00.%' ORDER BY created_at")
  assert_equal "2026-10-05 09:00:00.000000", rows[0]["created_at"].to_s
  assert_equal "2026-10-05 09:00:00.123456", rows[rows.size - 1]["created_at"].to_s
  conn.close
end

test "a table without an id column is normalized by rowid" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE tags (name TEXT, seen_at DATETIME)")
  conn.execute("INSERT INTO tags VALUES ('a', '2026-10-05T09:00:00Z')")
  report = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 1, report.size
  assert_equal "tags", report[0][0].to_s
  assert_equal 1, report[0][2].to_i
  assert_equal "2026-10-05 09:00:00.000000", conn.execute("SELECT seen_at FROM tags")[0]["seen_at"].to_s
  conn.close
end

test "a duplicated id does not make one row overwrite another" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE dup (id INTEGER, at DATETIME)")
  conn.execute("INSERT INTO dup VALUES (1, '2026-10-05T09:00:00Z')")
  conn.execute("INSERT INTO dup VALUES (1, '2026-10-06T10:00:00Z')")
  report = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 2, report[0][2].to_i
  rows = conn.execute("SELECT at FROM dup ORDER BY rowid")
  assert_equal "2026-10-05 09:00:00.000000", rows[0]["at"].to_s
  assert_equal "2026-10-06 10:00:00.000000", rows[1]["at"].to_s
  conn.close
end

test "WITHOUT ROWID tables and tables declaring _rowid_ are reported and left untouched" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE nr (k TEXT PRIMARY KEY, at DATETIME) WITHOUT ROWID ;")
  conn.exec_script("CREATE TABLE sh (_rowid_ INTEGER, at DATETIME)")
  conn.execute("INSERT INTO nr VALUES ('a', '2026-10-05T09:00:00Z')")
  conn.execute("INSERT INTO sh VALUES (1, '2026-10-05T09:00:00Z')")
  report = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 2, report.size
  assert_equal "nr", report[0][0].to_s
  assert_equal(-1, report[0][2].to_i)
  assert_equal Cybertrain::DB::Normalizer::WITHOUT_ROWID, report[0][3].to_i
  assert_equal "sh", report[1][0].to_s
  assert_equal(-1, report[1][2].to_i)
  assert_equal Cybertrain::DB::Normalizer::DECLARES_ROWID, report[1][3].to_i
  assert_equal "2026-10-05T09:00:00Z", conn.execute("SELECT at FROM nr")[0]["at"].to_s
  assert_equal "2026-10-05T09:00:00Z", conn.execute("SELECT at FROM sh")[0]["at"].to_s
  conn.close
end

test "a cell that only looks canonical to LIKE is rewritten and a canonical one is left alone" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE ev (id INTEGER PRIMARY KEY, at DATETIME)")
  conn.execute("INSERT INTO ev (at) VALUES ('2026-10-05 09:00:00.12345Z')")
  conn.execute("INSERT INTO ev (at) VALUES ('2026-10-05 09:00:00.123456')")
  report = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 1, report[0][2].to_i
  assert_equal 0, report[0][3].to_i
  rows = conn.execute("SELECT at FROM ev ORDER BY id")
  assert_equal "2026-10-05 09:00:00.123450", rows[0]["at"].to_s
  assert_equal "2026-10-05 09:00:00.123456", rows[1]["at"].to_s
  conn.close
end

test "reserved-word and odd table and column names are quoted" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE \"order\" (id INTEGER PRIMARY KEY, \"when\" DATETIME, \"a-b\" DATETIME)")
  conn.execute("INSERT INTO \"order\" (\"when\", \"a-b\") VALUES ('2026-10-05T09:00:00Z', NULL)")
  report = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 2, report.size
  assert_equal "2026-10-05 09:00:00.000000", conn.execute("SELECT \"when\" FROM \"order\"")[0]["when"].to_s
  conn.close
end

test "a datetime(6) column is normalized like DATETIME" do
  conn = Cybertrain::DB::Connection.new(":memory:")
  conn.exec_script("CREATE TABLE events (id INTEGER PRIMARY KEY, at datetime(6), label varchar)")
  conn.execute("INSERT INTO events (at, label) VALUES ('2026-10-05T09:00:00Z', '2026-10-05T09:00:00Z')")
  conn.execute("INSERT INTO events (at, label) VALUES ('2026-10-05 09:00:00.12', 'x')")
  report = Cybertrain::DB::Normalizer.run(conn)
  assert_equal 1, report.size
  assert_equal "at", report[0][1].to_s
  assert_equal 2, report[0][2].to_i
  rows = conn.execute("SELECT at, label FROM events ORDER BY id")
  assert_equal "2026-10-05 09:00:00.000000", rows[0]["at"].to_s
  assert_equal "2026-10-05 09:00:00.120000", rows[1]["at"].to_s
  assert_equal "2026-10-05T09:00:00Z", rows[0]["label"].to_s
  conn.close
end

Cybertrain::Test.run!
