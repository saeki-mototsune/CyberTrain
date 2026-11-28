# Cybertrain::DB::Connection on MySQL, against a real server: the URL is
# CYBERTRAIN_TEST_MYSQL_URL (script/mysql-dev starts mysql:8.0 at
# --default-time-zone=+09:00 and prints it; script/test-mysql runs this
# program). The tables are this program's own (ct_*), dropped and created
# by each test; no database is created or dropped.
#
# SPINEL_WORKERS is read when the first Thread.new starts the scheduler, so
# it is set before anything else (spikes/NOTES.md rule 22): with one OS
# worker, slow_query_does_not_block_worker shows that a query waiting on
# the server leaves the worker free for the other green threads.
ENV["SPINEL_WORKERS"] = "1"

require "cybertrain/db/base"
require "cybertrain/db/mysql"
require "cybertrain/test"

DB = Cybertrain::DB

URL = ENV.fetch("CYBERTRAIN_TEST_MYSQL_URL", "")
if URL.empty?
  puts "skipped: CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)"
  exit 2
end

def connect
  DB::Connection.new(URL)
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# The URL with its parameters replaced by `params` (and its password by
# `password` unless that is ""): the server's host, port and database.
def url_with(params, password = "")
  url = Cybertrain::DB::MySQL::Url.parse(URL)
  secret = password.empty? ? url.url_password : password
  "mysql://#{url.url_user}:#{secret}@#{url.url_host}:#{url.port}/#{url.database}?#{params}"
end

# A row value execute_models answered as a Time (a fixed Time otherwise,
# which no assertion here expects).
def time_value(value)
  case value
  when Time then value
  else Time.at(0, 7).utc
  end
end

def epoch_us_of(time)
  time.to_i * 1_000_000 + time.usec
end

def count_rows(conn, table)
  conn.execute("SELECT COUNT(*) AS n FROM #{table}")[0]["n"]
end

# The class and message of what the statement raised, or "nothing raised".
def failure(conn, sql, binds = [])
  got = "nothing raised"
  begin
    conn.execute(sql, binds)
  rescue Cybertrain::DB::Error => e
    got = "#{e.class.name}: #{e.message}"
  end
  got
end

def connect_failure(url)
  got = "nothing raised"
  begin
    DB::Connection.new(url).close
  rescue Cybertrain::DB::Error => e
    got = "#{e.class.name}: #{e.message}"
  end
  got
end

test "crud_roundtrip" do
  conn = connect
  conn.exec_script("DROP TABLE IF EXISTS ct_posts; " \
                   "CREATE TABLE ct_posts (id BIGINT AUTO_INCREMENT PRIMARY KEY, title VARCHAR(255) NOT NULL, views INT)")
  assert_equal [], conn.execute("INSERT INTO ct_posts (title, views) VALUES (?, ?)", ["hello", 3])
  assert_equal 1, conn.changes
  assert_equal 1, conn.last_insert_id
  conn.execute("INSERT INTO ct_posts (title, views) VALUES (?, ?)", ["draft", nil])
  assert_equal 2, conn.last_insert_id
  rows = conn.execute("SELECT id, title, views FROM ct_posts ORDER BY id")
  assert_equal [{ "id" => 1, "title" => "hello", "views" => 3 }, { "id" => 2, "title" => "draft", "views" => nil }], rows
  # A SELECT keeps the last write's counts, as SQLite's do.
  assert_equal 1, conn.changes
  assert_equal 2, conn.last_insert_id

  conn.execute("UPDATE ct_posts SET views = views + 1 WHERE id = ?", [1])
  assert_equal 1, conn.changes
  # A matched row that keeps its value still counts (CLIENT_FOUND_ROWS).
  conn.execute("UPDATE ct_posts SET title = ? WHERE id = ?", ["hello", 1])
  assert_equal 1, conn.changes
  conn.execute("UPDATE ct_posts SET views = 0")
  assert_equal 2, conn.changes
  assert_equal [{ "views" => 0 }], conn.execute("SELECT views FROM ct_posts WHERE title = ?", ["hello"])

  conn.execute("DELETE FROM ct_posts WHERE id = ?", [2])
  assert_equal 1, conn.changes
  assert_equal 1, count_rows(conn, "ct_posts")
  # An INSERT that makes no id leaves the last one.
  conn.exec_script("CREATE TEMPORARY TABLE ct_plain (v INT)")
  conn.execute("INSERT INTO ct_plain (v) VALUES (?)", [7])
  assert_equal 2, conn.last_insert_id

  # The same statement many times runs prepared once.
  i = 0
  while i < 50
    assert_equal [{ "n" => i + 1 }], conn.execute("SELECT ? + 1 AS n", [i])
    i += 1
  end
  before = conn.statements_run
  conn.execute("SELECT 1 AS one")
  conn.exec_script("SELECT 1; SELECT 2")
  assert_equal before + 1, conn.statements_run
  assert_equal 65_535, conn.variable_limit
  assert_equal false, conn.in_transaction?
  # BEGIN cannot be prepared (1295): with no binds it runs as a query.
  conn.execute("BEGIN")
  assert_equal true, conn.in_transaction?
  conn.execute("ROLLBACK")
  assert_equal false, conn.in_transaction?

  assert_equal false, conn.closed?
  assert_nil conn.close
  assert_equal true, conn.closed?
  assert_nil conn.close
  assert_equal "connection closed (sql: SELECT 1)", assert_raises("Cybertrain::DB::Error") { conn.execute("SELECT 1") }
  assert_equal "connection closed (changes)", assert_raises("Cybertrain::DB::Error") { conn.changes }
end

test "types_roundtrip" do
  conn = connect
  conn.exec_script("DROP TABLE IF EXISTS ct_types; CREATE TABLE ct_types (id BIGINT AUTO_INCREMENT PRIMARY KEY, " \
                   "c_string VARCHAR(255), c_text MEDIUMTEXT, c_integer INT, c_bigint BIGINT, c_boolean TINYINT(1), " \
                   "c_decimal DECIMAL(10,2), c_float DOUBLE, c_date DATE, c_datetime DATETIME(6), c_json JSON, " \
                   "c_binary LONGBLOB)")
  blob = String.new
  blob << "a"
  blob << 0.chr
  blob << 255.chr
  blob << 0.chr
  blob << "z"
  blob.force_encoding("BINARY")
  text = "line one\nline two: #{"x" * 70_000}"
  conn.execute("INSERT INTO ct_types (c_string, c_text, c_integer, c_bigint, c_boolean, c_decimal, c_float, c_date, " \
               "c_datetime, c_json, c_binary) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
               ["héllo 🍣", text, -42, 9_007_199_254_740_993, true, 1234.5, 3.25, Date.new(2026, 3, 1),
                Time.utc(2026, 3, 1, 12, 34, 56, 123_456), "{\"b\": [1, 2], \"a\": \"x\"}", DB::Blob.new(blob)])
  conn.execute("INSERT INTO ct_types (c_boolean) VALUES (?)", [false])
  conn.execute("INSERT INTO ct_types (c_string) VALUES (?)", [nil])
  rows = conn.execute("SELECT * FROM ct_types ORDER BY id")
  row = rows[0]
  # string: VARCHAR(255), String, UTF-8 (four-byte characters included)
  assert_equal ["héllo 🍣", "UTF-8"], [row["c_string"], row["c_string"].to_s.encoding.to_s]
  # text: MEDIUMTEXT, String
  assert_equal [text.bytesize, true], [row["c_text"].to_s.bytesize, row["c_text"] == text]
  # integer / bigint: INT / BIGINT, Integer (past 2**53 exactly)
  assert_equal [-42, 9_007_199_254_740_993], [row["c_integer"], row["c_bigint"]]
  # boolean: TINYINT(1), Integer 0/1
  assert_equal [1, 0], [row["c_boolean"], rows[1]["c_boolean"]]
  # decimal: DECIMAL(10,2), Float
  assert_equal [1234.5, "Float"], [row["c_decimal"], row["c_decimal"].class.name]
  # float: DOUBLE, Float
  assert_equal 3.25, row["c_float"]
  # date: DATE, String
  assert_equal "2026-03-01", row["c_date"]
  # datetime: DATETIME(6), the text SQLite stores (execute)
  assert_equal "2026-03-01 12:34:56.123456", row["c_datetime"]
  # json: JSON, String as MySQL normalised it
  assert_equal "{\"a\": \"x\", \"b\": [1, 2]}", row["c_json"]
  # binary: LONGBLOB, the bytes as they are (NUL and 0xFF included)
  got = row["c_binary"].to_s
  assert_equal [5, 0, 255, true], [got.bytesize, got.getbyte(1), got.getbyte(2), got == blob]
  # NULL: nil in every column
  nulls = rows[2]
  assert_equal [nil, nil, nil, nil, nil, nil, nil, nil, nil, nil],
               [nulls["c_string"], nulls["c_text"], nulls["c_integer"], nulls["c_bigint"], nulls["c_decimal"],
                nulls["c_float"], nulls["c_date"], nulls["c_datetime"], nulls["c_json"], nulls["c_binary"]]
  conn.close
end

test "datetime_utc_on_non_utc_server" do
  conn = connect
  # The server's own zone is +09:00; the session's is UTC.
  zones = conn.execute("SELECT @@global.time_zone AS server, @@session.time_zone AS session")
  assert_equal [{ "server" => "+09:00", "session" => "+00:00" }], zones
  assert_equal [{ "same" => 1 }], conn.execute("SELECT NOW(6) = UTC_TIMESTAMP(6) AS same")
  conn.exec_script("DROP TABLE IF EXISTS ct_times; " \
                   "CREATE TABLE ct_times (id INT PRIMARY KEY, at DATETIME(6), ts TIMESTAMP(6) NULL)")
  conn.exec_script("INSERT INTO ct_times VALUES (1, '2026-03-01 12:34:56.123456', '2026-03-01 12:34:56.123456')")
  at = Time.utc(2026, 3, 1, 12, 34, 56, 123_456)
  conn.execute("INSERT INTO ct_times VALUES (?, ?, ?)", [2, at, at])
  conn.execute("INSERT INTO ct_times VALUES (?, ?, ?)", [3, "1970-01-01 00:00:00.000001", nil])
  # execute_models answers a UTC Time with the microseconds, as SQLite's
  # does: the epoch it stands for is the stored UTC value.
  rows = conn.execute_models("SELECT id, at, ts FROM ct_times ORDER BY id")
  [0, 1].each do |i|
    assert_equal i + 1, rows[i]["id"]
    ["at", "ts"].each do |column|
      t = time_value(rows[i][column])
      assert_equal [1_772_368_496_123_456, 123_456, true], [epoch_us_of(t), t.usec, t.utc?]
    end
  end
  assert_equal [1, true, nil], [epoch_us_of(time_value(rows[2]["at"])), time_value(rows[2]["at"]).utc?, rows[2]["ts"]]
  # execute answers the text.
  assert_equal [{ "at" => "2026-03-01 12:34:56.123456", "ts" => "2026-03-01 12:34:56.123456" }],
               conn.execute("SELECT at, ts FROM ct_times WHERE id = ?", [2])
  # The TIMESTAMP is the UTC instant: the server's epoch for it.
  assert_equal [{ "us" => 1_772_368_496_123_456.0 }],
               conn.execute("SELECT UNIX_TIMESTAMP(ts) * 1000000 AS us FROM ct_times WHERE id = ?", [1])
  # Every connection sets the session: a second one reads the same.
  other = connect
  assert_equal 1_772_368_496_123_456, epoch_us_of(time_value(other.execute_models("SELECT ts FROM ct_times WHERE id = 2")[0]["ts"]))
  other.close
  assert_equal 1_772_368_496_123_456, DB::Connection.epoch_us("2026-03-01 12:34:56.123456")
  not_datetime = DB::Connection::NOT_DATETIME
  assert_equal [0, not_datetime, not_datetime], [DB::Connection.epoch_us("1970-01-01 00:00:00.000000"),
                             DB::Connection.epoch_us("0000-00-00 00:00:00.000000"), DB::Connection.epoch_us("2026-03-01")]
  conn.close
end

test "transaction_rollback" do
  conn = connect
  conn.exec_script("DROP TABLE IF EXISTS ct_accounts; " \
                   "CREATE TABLE ct_accounts (id INT PRIMARY KEY, balance INT NOT NULL) ENGINE=InnoDB")
  message = assert_raises("RuntimeError") do
    conn.transaction do
      conn.execute("INSERT INTO ct_accounts VALUES (?, ?)", [1, 100])
      assert_equal true, conn.in_transaction?
      raise "boom"
    end
  end
  assert_equal "boom", message
  assert_equal 0, count_rows(conn, "ct_accounts")
  assert_equal false, conn.in_transaction?

  conn.transaction do
    conn.execute("INSERT INTO ct_accounts VALUES (?, ?)", [1, 100])
    conn.transaction { conn.execute("INSERT INTO ct_accounts VALUES (?, ?)", [2, 50]) }
  end
  assert_equal 2, count_rows(conn, "ct_accounts")

  conn.begin!(immediate: true)
  conn.execute("UPDATE ct_accounts SET balance = balance - ? WHERE id = ?", [30, 1])
  conn.begin!
  conn.execute("UPDATE ct_accounts SET balance = balance + ? WHERE id = ?", [30, 2])
  conn.rollback!
  assert_equal true, conn.in_transaction?
  conn.rollback!
  assert_equal false, conn.in_transaction?
  assert_equal [{ "balance" => 100 }, { "balance" => 50 }], conn.execute("SELECT balance FROM ct_accounts ORDER BY id")
  assert_equal "commit!: no transaction is open on this connection", assert_raises("Cybertrain::DB::Error") { conn.commit! }

  # What the pool does with a BEGIN left open.
  assert_equal :clean, conn.abandon_transaction!
  conn.exec_script("BEGIN; DELETE FROM ct_accounts")
  assert_equal :rolled_back, conn.abandon_transaction!
  assert_equal 2, count_rows(conn, "ct_accounts")

  # Through the pool: DB.transaction rolls back and re-raises.
  DB.connect(URL, size: 2)
  assert_raises("RuntimeError") do
    DB.transaction do |c|
      c.execute("UPDATE ct_accounts SET balance = 0")
      raise "pool boom"
    end
  end
  assert_equal [{ "n" => 150 }], DB.with { |c| c.execute("SELECT SUM(balance) AS n FROM ct_accounts") }
  DB.transaction { |c| c.execute("UPDATE ct_accounts SET balance = 75") }
  assert_equal [{ "n" => 150 }], DB.with { |c| c.execute("SELECT CAST(SUM(balance) AS SIGNED) AS n FROM ct_accounts") }
  DB.disconnect
  conn.close
end

# The victim's half of a deadlock, `conn` already holding row 2 in its
# transaction: `holder` takes rows 1, 3 and 4 (more than the victim has
# written) and waits for row 2 in a thread, and `conn` asks for row 1. The
# holder commits. What conn's statement raised, as failure says it.
def deadlock_victim(conn, holder)
  holder.begin!
  holder.execute("UPDATE ct_locks SET v = v + 1 WHERE id IN (1, 3, 4)")
  waiting = Thread.new { holder.execute("UPDATE ct_locks SET v = v + 1 WHERE id = 2") }
  sleep 0.3
  got = failure(conn, "UPDATE ct_locks SET v = v + 1 WHERE id = 1")
  waiting.join
  holder.commit!
  got
end

# A deadlock rolls the victim's whole transaction back: what it runs next
# is refused, as the SQLite Connection refuses after SQLite rolled back on
# its own, until it ends the transaction. The holder updates row 1 and
# then waits for row 2 in a thread; the victim, holding row 2, asks for row
# 1. The victim has written less, so InnoDB picks it.
test "a deadlock leaves the transaction gone until it is ended" do
  conn = connect
  conn.exec_script("DROP TABLE IF EXISTS ct_locks; CREATE TABLE ct_locks (id INT PRIMARY KEY, v INT) ENGINE=InnoDB; " \
                   "INSERT INTO ct_locks VALUES (1, 0), (2, 0), (3, 0), (4, 0)")
  holder = connect
  holder.begin!
  holder.execute("UPDATE ct_locks SET v = v + 1 WHERE id IN (1, 3, 4)")
  conn.begin!
  conn.execute("UPDATE ct_locks SET v = v + 1 WHERE id = 2")
  waiting = Thread.new { holder.execute("UPDATE ct_locks SET v = v + 1 WHERE id = 2") }
  sleep 0.3
  got = failure(conn, "UPDATE ct_locks SET v = v + 1 WHERE id = 1")
  waiting.join
  holder.commit!
  assert_equal true, got.start_with?("Cybertrain::DB::Deadlock: Deadlock found when trying to get lock")
  assert_equal true, got.end_with?("(MySQL 1213, 40001) (sql: UPDATE ct_locks SET v = v + 1 WHERE id = 1)")
  assert_equal false, conn.in_transaction?
  assert_equal "Cybertrain::DB::Error: the enclosing transaction is no longer open (MySQL rolled it back after an " \
               "error, or a statement committed it); the statement was not run (sql: SELECT 1)", failure(conn, "SELECT 1")
  assert_equal "transaction: the enclosing transaction is no longer open (MySQL rolled it back after an error, or a " \
               "statement committed it); nothing nested in it can be committed",
               assert_raises("Cybertrain::DB::Error") { conn.begin! }
  conn.rollback!
  assert_equal [{ "v" => 1 }, { "v" => 1 }], conn.execute("SELECT v FROM ct_locks WHERE id IN (1, 2) ORDER BY id")

  # A block that rescues the deadlock and ends normally: MySQL would answer
  # its COMMIT with OK (nothing is open), so commit! refuses it, as SQLite
  # refuses a COMMIT with no transaction, and the connection works after.
  victim = []
  message = assert_raises("Cybertrain::DB::Error") do
    conn.transaction do
      conn.execute("UPDATE ct_locks SET v = v + 10 WHERE id = 2")
      victim << deadlock_victim(conn, holder)
    end
  end
  assert_equal true, victim[0].start_with?("Cybertrain::DB::Deadlock: ")
  assert_equal "the enclosing transaction is no longer open (MySQL rolled it back after an error, or a statement " \
               "committed it); the statement was not run (sql: COMMIT)", message
  assert_equal [{ "one" => 1 }], conn.execute("SELECT 1 AS one")
  assert_equal false, conn.in_transaction?
  assert_equal [{ "v" => 2 }, { "v" => 2 }], conn.execute("SELECT v FROM ct_locks WHERE id IN (1, 2) ORDER BY id")
  holder.close
  conn.close
end

test "unique_violation_class" do
  conn = connect
  conn.exec_script("DROP TABLE IF EXISTS ct_children; DROP TABLE IF EXISTS ct_users; " \
                   "CREATE TABLE ct_users (id INT PRIMARY KEY, email VARCHAR(100) NOT NULL, UNIQUE KEY ct_users_email (email)); " \
                   "CREATE TABLE ct_children (id INT PRIMARY KEY, user_id INT NOT NULL, " \
                   "FOREIGN KEY (user_id) REFERENCES ct_users (id))")
  conn.execute("INSERT INTO ct_users VALUES (?, ?)", [1, "a@example.com"])
  sql = "INSERT INTO ct_users VALUES (?, ?)"
  assert_equal "Cybertrain::DB::UniqueViolation: Duplicate entry 'a@example.com' for key 'ct_users.ct_users_email' " \
               "(MySQL 1062, 23000) (sql: #{sql})", failure(conn, sql, [2, "a@example.com"])
  # utf8mb4_0900_bin: case and trailing spaces make another value.
  conn.execute(sql, [2, "A@example.com"])
  conn.execute(sql, [3, "a@example.com "])
  assert_equal "Cybertrain::DB::UniqueViolation: Duplicate entry '1' for key 'ct_users.PRIMARY' (MySQL 1062, 23000) (sql: #{sql})",
               failure(conn, sql, [1, "b@example.com"])
  assert_equal true, failure(conn, "INSERT INTO ct_children VALUES (?, ?)", [1, 99])
    .start_with?("Cybertrain::DB::ForeignKeyViolation: Cannot add or update a child row")
  conn.execute("INSERT INTO ct_children VALUES (?, ?)", [1, 1])
  assert_equal true, failure(conn, "DELETE FROM ct_users WHERE id = ?", [1])
    .start_with?("Cybertrain::DB::ForeignKeyViolation: Cannot delete or update a parent row")
  # Other server errors are DB::Error; the connection carries on after each.
  assert_equal "Cybertrain::DB::Error: Table 'cybertrain_test.ct_missing' doesn't exist (MySQL 1146, 42S02) (sql: SELECT * FROM ct_missing)",
               failure(conn, "SELECT * FROM ct_missing")
  assert_equal "Cybertrain::DB::Error: Column 'email' cannot be null (MySQL 1048, 23000) (sql: #{sql})", failure(conn, sql, [9, nil])
  script = "INSERT INTO ct_users VALUES (8, 'h@example.com'); INSERT INTO ct_users VALUES (8, 'i@example.com')"
  assert_equal "Duplicate entry '8' for key 'ct_users.PRIMARY' (MySQL 1062, 23000) (sql: #{script})",
               assert_raises("Cybertrain::DB::UniqueViolation") { conn.exec_script(script) }
  assert_equal "Cybertrain::DB::Error: Data too long for column 'email' at row 1 (MySQL 1406, 22001) (sql: #{sql})",
               failure(conn, sql, [10, "x" * 101])
  assert_equal 4, count_rows(conn, "ct_users")
  conn.close
end

test "slow_query_does_not_block_worker" do
  conn = connect
  done = []
  ticks = []
  counter = Thread.new do
    while done.empty?
      sleep 0.05
      ticks << 1
    end
  end
  slept = []
  started = monotonic
  query = Thread.new { slept << conn.execute("SELECT SLEEP(1) AS s")[0]["s"] }
  query.join
  elapsed = monotonic - started
  done << true
  counter.join
  assert_equal [0], slept
  assert elapsed >= 0.95, "SLEEP(1) took #{elapsed.round(2)} s"
  assert ticks.size >= 10, "the other thread counted #{ticks.size} times while SLEEP(1) ran"
  conn.close
end

def prepared_count(conn)
  conn.execute("SHOW SESSION STATUS LIKE 'Prepared_stmt_count'")[0]["Value"].to_s.to_i
end

test "statement_cache_evicts" do
  conn = connect
  i = 0
  while i < 2000
    assert_equal [{ "v" => i + 7 }], conn.execute("SELECT ? + #{i} AS v", [7])
    i += 1
  end
  count = prepared_count(conn)
  assert count <= 256, "#{count} statements prepared"
  assert count >= 200, "only #{count} statements prepared"
  # An evicted statement is prepared again; a kept one still answers.
  assert_equal [{ "v" => 1 }], conn.execute("SELECT ? + 0 AS v", [1])
  assert_equal [{ "v" => 2001 }], conn.execute("SELECT ? + 1999 AS v", [2])
  assert prepared_count(conn) <= 256, "past 256 after a re-prepare"
  # The server drops a session's statements with it: a new session holds
  # its own SHOW alone.
  conn.close
  sleep 0.2
  fresh = connect
  assert_equal 1, prepared_count(fresh)
  fresh.close
end

test "a lost session is ConnectionLost, closes the connection and keeps the server's message" do
  # The server ends an idle session with an unprompted ERR (4031).
  idle = connect
  idle.exec_script("SET SESSION wait_timeout = 1")
  sleep 2.5
  got = failure(idle, "SELECT 1")
  assert_equal "Cybertrain::DB::ConnectionLost: The client was disconnected by the server because of inactivity. See " \
               "wait_timeout and interactive_timeout for configuring this behavior. (MySQL 4031, HY000) (sql: SELECT 1)", got
  assert_equal true, idle.closed?
  assert_equal :clean, idle.abandon_transaction!

  # KILL: the server closes without a word.
  victim = connect
  id = victim.execute("SELECT CONNECTION_ID() AS id")[0]["id"]
  killer = connect
  killer.exec_script("KILL CONNECTION #{id}")
  killer.close
  assert_equal true, failure(victim, "SELECT 1").start_with?("Cybertrain::DB::ConnectionLost: ")
  assert_equal true, victim.closed?

  # read_timeout bounds each wait for the server: the stream is then out
  # of step, so the connection closes itself.
  slow = DB::Connection.new(url_with("ssl_mode=disabled&read_timeout=1"))
  got = failure(slow, "SELECT SLEEP(3)")
  assert_equal true, got.start_with?("Cybertrain::DB::ConnectionLost: ")
  assert_equal true, got.end_with?("reading timed out after 1s (sql: SELECT SLEEP(3))")
  assert_equal true, slow.closed?
end

test "a refused login or an unreachable server never shows the password" do
  got = connect_failure(url_with("ssl_mode=disabled", "not-the-pw-xyzzy"))
  assert_equal true, got.start_with?("Cybertrain::DB::Error: ")
  assert_equal true, got.include?("Access denied for user 'root'")
  assert_equal false, got.include?("xyzzy")
  closed_port = connect_failure("mysql://root:not-the-pw-xyzzy@127.0.0.1:1/x?ssl_mode=disabled&connect_timeout=2")
  assert_equal "Cybertrain::DB::ConnectionLost: 127.0.0.1:1: connection refused", closed_port
  assert_equal "Cybertrain::DB::Error: MySQL URL: unknown ssl_mode 'none' (use verify or disabled)",
               connect_failure("mysql://root:not-the-pw-xyzzy@127.0.0.1/x?ssl_mode=none")
end

Cybertrain::Test.run!
