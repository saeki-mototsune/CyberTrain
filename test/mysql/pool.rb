# Cybertrain::DB's pool on MySQL, against a real server (the URL is
# CYBERTRAIN_TEST_MYSQL_URL, as in test/mysql/connection.rb): what the pool
# does when the server ends a session it holds (KILL from a second
# connection, wait_timeout), and the boot path's DATABASE_URL.
#
# A connection that was idle in the pool and is found dead by the first
# statement of its checkout reopens its session and runs that statement
# once more, only when the request cannot have run (the stream ended or the
# server's unprompted ERR came before any answer) and no transaction is
# open. Inside a transaction the loss is DB::ConnectionLost: the server
# rolled the transaction back, and nothing is run again.
ENV["SPINEL_WORKERS"] = "1"

require "cybertrain/config"
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

# The URL with its parameters replaced by `params`.
def url_with(params)
  url = Cybertrain::DB::MySQL::Url.parse(URL)
  "mysql://#{url.url_user}:#{url.url_password}@#{url.url_host}:#{url.port}/#{url.database}?#{params}"
end

# The session id of the connection the pool hands out next, as text.
def pooled_session_id
  DB.with { |c| c.execute("SELECT CONNECTION_ID() AS id") }[0]["id"].to_s
end

def kill_session(id)
  killer = connect
  killer.exec_script("KILL CONNECTION #{id}")
  killer.close
  nil
end

def count_rows(table)
  conn = connect
  n = conn.execute("SELECT COUNT(*) AS n FROM #{table}")[0]["n"]
  conn.close
  n
end

def reset_table(table)
  conn = connect
  conn.exec_script("DROP TABLE IF EXISTS #{table}; CREATE TABLE #{table} (id INT PRIMARY KEY) ENGINE=InnoDB")
  conn.close
  nil
end

test "pool_reconnects_after_kill" do
  reset_table("ct_pool_rows")
  DB.connect(URL, size: 1)
  first = pooled_session_id
  kill_session(first)

  # The first statement of the next checkout finds the session gone,
  # reopens it (session settings included) and runs once on the new one.
  rows = DB.with { |c| c.execute("SELECT CONNECTION_ID() AS id, @@session.time_zone AS tz") }
  second = rows[0]["id"].to_s
  assert_equal false, second == first
  assert_equal "+00:00", rows[0]["tz"]
  assert_equal false, DB.pool.connection_at(0).closed?

  # A write is retried the same way: it never reached the server.
  kill_session(second)
  DB.with { |c| c.execute("INSERT INTO ct_pool_rows VALUES (?)", [1]) }
  assert_equal 1, count_rows("ct_pool_rows")

  # Only the checkout's first statement: once the session answered, a loss
  # is ConnectionLost and the connection is closed, not handed out again.
  third = pooled_session_id
  message = assert_raises("Cybertrain::DB::ConnectionLost") do
    DB.with do |c|
      c.execute("SELECT 1 AS one")
      kill_session(third)
      c.execute("INSERT INTO ct_pool_rows VALUES (?)", [2])
    end
  end
  assert_equal true, message.end_with?("(sql: INSERT INTO ct_pool_rows VALUES (?))")
  assert_equal 1, count_rows("ct_pool_rows")
  assert_equal true, DB.pool.connection_at(0).closed?
  # The next checkout replaces it.
  assert_equal false, pooled_session_id == third
  assert_equal false, DB.pool.connection_at(0).closed?
  DB.disconnect
end

test "an idle session the server timed out is reopened" do
  DB.connect(URL, size: 1)
  first = pooled_session_id
  DB.with { |c| c.exec_script("SET SESSION wait_timeout = 1") }
  sleep 2.5
  # The server's unprompted 4031 ERR is read where the answer should be.
  second = pooled_session_id
  assert_equal false, second == first
  DB.disconnect
end

test "a timeout is not retried" do
  # The server may be running the statement: read_timeout's loss is
  # ConnectionLost after one wait, and the statement is not sent again.
  DB.connect(url_with("ssl_mode=disabled&read_timeout=1"), size: 1)
  started = monotonic
  message = assert_raises("Cybertrain::DB::ConnectionLost") { DB.with { |c| c.execute("SELECT SLEEP(2) AS s") } }
  elapsed = monotonic - started
  assert_equal true, message.end_with?("reading timed out after 1s (sql: SELECT SLEEP(2) AS s)")
  assert elapsed < 1.8, "the timed-out statement took #{elapsed.round(2)} s: it was run again"
  DB.disconnect
end

test "transaction_lost_on_kill" do
  reset_table("ct_pool_rows")
  DB.connect(URL, size: 1)
  killed = ""
  message = assert_raises("Cybertrain::DB::ConnectionLost") do
    DB.transaction do |c|
      c.execute("INSERT INTO ct_pool_rows VALUES (?)", [1])
      killed = c.execute("SELECT CONNECTION_ID() AS id")[0]["id"].to_s
      kill_session(killed)
      c.execute("INSERT INTO ct_pool_rows VALUES (?)", [2])
    end
  end
  assert_equal true, message.end_with?("(sql: INSERT INTO ct_pool_rows VALUES (?))")
  # Nothing was run again: the server rolled the transaction back with
  # the session, and the row the block inserted is gone.
  assert_equal 0, count_rows("ct_pool_rows")
  # The lost connection is closed, not reopened inside the transaction;
  # the next checkout replaces it.
  assert_equal true, DB.pool.connection_at(0).closed?
  assert_equal false, pooled_session_id == killed
  assert_equal [{ "n" => 0 }], DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM ct_pool_rows") }
  DB.disconnect
end

test "missing_database_url" do
  ENV["DATABASE_URL"] = ""
  config = Cybertrain::Config.new
  assert_equal "", config.database_url
  message = assert_raises("Cybertrain::DB::Error") { DB::Adapter.connect_target(config) }
  assert_equal "DATABASE_URL is not set (mysql://user:password@host:3306/name)", message

  ENV["DATABASE_URL"] = URL
  assert_equal URL, Cybertrain::Config.new.database_url
  assert_equal URL, DB::Adapter.connect_target(Cybertrain::Config.new)
  assert_equal "mysql", DB::Adapter.adapter_name
  ENV["DATABASE_URL"] = ""
end

Cybertrain::Test.run!
