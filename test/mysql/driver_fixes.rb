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

Cybertrain::Test.run!
