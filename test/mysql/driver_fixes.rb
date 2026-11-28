# The MySQL driver's fixes from the review of the adapter, against a real
# server (the URL is CYBERTRAIN_TEST_MYSQL_URL, as in test/mysql/
# connection.rb): what the pool logs about a MySQL target, the raw COMMIT
# of a transaction MySQL rolled back, DATETIME values before 1970, and the
# statement cache at its limit. The tables are this program's own (ct_df_*).
ENV["SPINEL_WORKERS"] = "1"

require "stringio"
require "cybertrain/config"
require "cybertrain/logger"
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

def kill_session(id)
  killer = connect
  killer.exec_script("KILL CONNECTION #{id}")
  killer.close
  nil
end

# A checkout that leaves a BEGIN open and whose session is killed before
# check-in, where the ROLLBACK then finds the connection lost.
def leave_begin_on_killed_session
  DB.with do |c|
    c.exec_script("BEGIN")
    kill_session(c.execute("SELECT CONNECTION_ID() AS id")[0]["id"].to_s)
  end
  nil
end

test "the pool's log line after a lost ROLLBACK names the server without the password" do
  password = Cybertrain::DB::MySQL::Url.parse(URL).url_password
  assert_equal false, password.empty?
  log = StringIO.new
  Cybertrain.logger = Cybertrain::Logger.new(log, :info)
  DB.connect(URL, size: 1)
  leave_begin_on_killed_session
  Cybertrain.logger = Cybertrain::Logger.new
  line = log.string
  assert_includes line, "could not roll back a transaction left open on a pooled connection; closed it, " \
                        "the next checkout reopens #{Cybertrain::DB::MySQL::Url.parse(URL)}"
  # As the URL spells it (the test server's password, "cybertrain", is also
  # a part of its database's name).
  assert_equal false, line.include?(":#{password}@")
  assert_equal false, DB.pool.inspect.include?(":#{password}@")
  assert_includes DB.pool.inspect, Cybertrain::DB::MySQL::Url.parse(URL).to_s
  # The next checkout reopens the slot.
  assert_equal 1, DB.with { |c| c.execute("SELECT 1 AS one") }[0]["one"]
  DB.disconnect
end

# The class and message of what the statement raised, or "nothing raised".
def failure(conn, sql)
  got = "nothing raised"
  begin
    conn.execute(sql)
  rescue Cybertrain::DB::Error => e
    got = "#{e.class.name}: #{e.message}"
  end
  got
end

def script_failure(conn, sql)
  got = "nothing raised"
  begin
    conn.exec_script(sql)
  rescue Cybertrain::DB::Error => e
    got = "#{e.class.name}: #{e.message}"
  end
  got
end

# conn holds row 2 in an open transaction; the holder takes rows 1, 3, 4
# and waits for row 2 in a thread, then conn asks for row 1: InnoDB picks
# conn, which wrote less, and rolls its whole transaction back. What conn's
# statement raised.
def deadlock_victim(conn, holder)
  holder.begin!
  holder.execute("UPDATE ct_df_locks SET v = v + 1 WHERE id IN (1, 3, 4)")
  waiting = Thread.new { holder.execute("UPDATE ct_df_locks SET v = v + 1 WHERE id = 2") }
  sleep 0.3
  got = failure(conn, "UPDATE ct_df_locks SET v = v + 1 WHERE id = 1")
  waiting.join
  holder.commit!
  got
end

GONE = "Cybertrain::DB::Error: the enclosing transaction is no longer open (MySQL rolled it back after an error, " \
       "or a statement committed it); the statement was not run"

test "a raw COMMIT after MySQL rolled the transaction back is refused, as commit! refuses it" do
  conn = connect
  conn.exec_script("DROP TABLE IF EXISTS ct_df_locks; CREATE TABLE ct_df_locks (id INT PRIMARY KEY, v INT) ENGINE=InnoDB; " \
                   "INSERT INTO ct_df_locks VALUES (1, 0), (2, 0), (3, 0), (4, 0)")
  holder = connect
  conn.execute("BEGIN")
  conn.execute("UPDATE ct_df_locks SET v = v + 10 WHERE id = 2")
  assert_equal true, deadlock_victim(conn, holder).start_with?("Cybertrain::DB::Deadlock: ")
  # MySQL would answer this COMMIT with OK, though nothing is committed.
  assert_equal "#{GONE} (sql: COMMIT)", failure(conn, "COMMIT")
  # The COMMIT ended the lost transaction: the connection works after it.
  assert_equal [{ "one" => 1 }], conn.execute("SELECT 1 AS one")
  assert_equal false, conn.in_transaction?
  assert_equal [{ "v" => 1 }], conn.execute("SELECT v FROM ct_df_locks WHERE id = 2")

  # The same through exec_script, with a statement after the COMMIT: the
  # whole script is refused, not run as if the COMMIT had committed.
  conn.exec_script("BEGIN")
  conn.execute("UPDATE ct_df_locks SET v = v + 10 WHERE id = 2")
  assert_equal true, deadlock_victim(conn, holder).start_with?("Cybertrain::DB::Deadlock: ")
  assert_equal "#{GONE} (sql: COMMIT; INSERT INTO ct_df_locks VALUES (5, 0))",
               script_failure(conn, "COMMIT; INSERT INTO ct_df_locks VALUES (5, 0)")
  assert_equal [{ "n" => 4 }], conn.execute("SELECT COUNT(*) AS n FROM ct_df_locks")
  # A bare ROLLBACK still answers nothing to do.
  conn.exec_script("BEGIN")
  conn.execute("UPDATE ct_df_locks SET v = v + 10 WHERE id = 2")
  assert_equal true, deadlock_victim(conn, holder).start_with?("Cybertrain::DB::Deadlock: ")
  assert_equal [], conn.execute("ROLLBACK")
  assert_equal [{ "one" => 1 }], conn.execute("SELECT 1 AS one")
  conn.exec_script("DROP TABLE ct_df_locks")
  holder.close
  conn.close
end

# A row value execute_models answered as a Time (a fixed Time otherwise,
# which no assertion here expects).
def time_value(value)
  case value
  when Time then value
  else Time.at(0, 7).utc
  end
end

test "execute_models answers a DATETIME before 1970 as a Time too" do
  conn = connect
  row = conn.execute_models("SELECT CAST('1965-03-02 00:00:00.250000' AS DATETIME(6)) AS a, " \
                            "CAST('1969-12-31 23:59:59.999999' AS DATETIME(6)) AS b, " \
                            "CAST('0001-01-01 00:00:00' AS DATETIME(6)) AS c, " \
                            "CAST('1970-01-01 00:00:00' AS DATETIME(6)) AS d")[0]
  a = time_value(row["a"])
  assert_equal [-152_582_400, 250_000], [a.to_i, a.usec]
  b = time_value(row["b"])
  assert_equal [-1, 999_999], [b.to_i, b.usec]
  assert_equal "1969-12-31 23:59:59", b.strftime("%Y-%m-%d %H:%M:%S")
  c = time_value(row["c"])
  assert_equal [-62_135_596_800, 0], [c.to_i, c.usec]
  d = time_value(row["d"])
  assert_equal [0, 0], [d.to_i, d.usec]
  conn.close
end

# The review asked whether a cached statement can be left answering 1615
# (ER_NEED_REPREPARE) after DDL from another session: MySQL 8.0 re-prepares
# it on the next execute, each time, and the new columns come back.
test "a cached SELECT * re-prepares on the server after another session's ALTER" do
  conn = connect
  other = connect
  conn.exec_script("DROP TABLE IF EXISTS ct_df_reprep; CREATE TABLE ct_df_reprep (id INT PRIMARY KEY, v INT); " \
                   "INSERT INTO ct_df_reprep VALUES (1, 2)")
  assert_equal [{ "id" => 1, "v" => 2 }], conn.execute("SELECT * FROM ct_df_reprep")
  i = 1
  while i <= 5
    other.exec_script("ALTER TABLE ct_df_reprep ADD COLUMN c#{i} INT DEFAULT #{i}")
    assert_equal [{ "id" => 1, "v" => 2, "c#{i}" => i }], conn.execute("SELECT * FROM ct_df_reprep")
    other.exec_script("ALTER TABLE ct_df_reprep DROP COLUMN c#{i}")
    assert_equal [{ "id" => 1, "v" => 2 }], conn.execute("SELECT * FROM ct_df_reprep")
    i += 1
  end
  conn.exec_script("DROP TABLE ct_df_reprep")
  other.close
  conn.close
end

Cybertrain::Test.run!
