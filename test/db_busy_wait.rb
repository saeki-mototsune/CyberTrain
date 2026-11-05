# A writer waiting for SQLite's write lock must not hold the OS worker that
# the lock holder needs to finish (saeki-mototsune/CyberTrain#134). With one
# worker, every green thread runs on the same OS thread: a busy wait inside
# the SQLite call (the old busy handler slept there for up to about 5 s)
# keeps the holder from ever reaching its COMMIT, so the waiter gave up with
# "database is locked" and every other request stalled meanwhile.
#
# SPINEL_WORKERS is read when the first Thread.new starts the scheduler, so
# it is set before anything else (spikes/NOTES.md rule 22).
ENV["SPINEL_WORKERS"] = "1"

require "cybertrain/db"
require "cybertrain/test"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB

BUSY_PATH = "tmp/db_busy_wait_test.sqlite3"

def reset_busy_file
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  [BUSY_PATH, BUSY_PATH + "-wal", BUSY_PATH + "-shm"].each do |f|
    File.delete(f) if File.exist?(f)
  end
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# The holder takes the write lock, then parks its green thread (as a request
# does on I/O inside a transaction) for HOLD seconds before it commits.
HOLD = 0.3

def start_holder(log, hold = HOLD)
  Thread.new do
    DB.transaction(immediate: true) do |c|
      c.execute("INSERT INTO events (who) VALUES (?)", ["holder"])
      log << "locked"
      sleep hold
    end
    log << "committed"
  end
end

def wait_for_lock(log)
  tries = 0
  while log.empty? && tries < 1000
    sleep 0.001
    tries += 1
  end
  nil
end

test "a write waiting for the lock lets the holder commit (one worker)" do
  reset_busy_file
  DB.connect(BUSY_PATH, size: 4)
  DB.with { |c| c.exec_script("CREATE TABLE events (id INTEGER PRIMARY KEY, who TEXT);") }
  log = []
  holder = start_holder(log)
  wait_for_lock(log)
  assert_equal ["locked"], log

  started = monotonic
  DB.with { |c| c.execute("INSERT INTO events (who) VALUES (?)", ["waiter"]) }
  waited = monotonic - started
  holder.join

  # The waiter got the lock once the holder committed: about HOLD seconds,
  # never the busy handler's 5 s give-up.
  assert waited < 2.0, "the waiter took #{waited.round(2)} s"
  assert_equal ["locked", "committed"], log
  rows = DB.with { |c| c.execute("SELECT who FROM events ORDER BY id") }
  assert_equal ["holder", "waiter"], rows.map { |r| r["who"].to_s }
  DB.disconnect
end

test "BEGIN IMMEDIATE waiting for the lock lets the holder commit (one worker)" do
  reset_busy_file
  DB.connect(BUSY_PATH, size: 4)
  DB.with { |c| c.exec_script("CREATE TABLE events (id INTEGER PRIMARY KEY, who TEXT);") }
  log = []
  holder = start_holder(log)
  wait_for_lock(log)

  started = monotonic
  DB.transaction(immediate: true) do |c|
    c.execute("INSERT INTO events (who) VALUES (?)", ["second"])
  end
  waited = monotonic - started
  holder.join

  assert waited < 2.0, "the second transaction took #{waited.round(2)} s"
  rows = DB.with { |c| c.execute("SELECT who FROM events ORDER BY id") }
  assert_equal ["holder", "second"], rows.map { |r| r["who"].to_s }
  DB.disconnect
end

# Waiting still ends: a lock held past Connection::BUSY_WAIT_LIMIT (5 s)
# fails the waiter with SQLite's own message, as the busy handler did, and
# the holder, which ran meanwhile, commits.
test "a write gives up with database is locked after the wait limit" do
  reset_busy_file
  DB.connect(BUSY_PATH, size: 4)
  DB.with { |c| c.exec_script("CREATE TABLE events (id INTEGER PRIMARY KEY, who TEXT);") }
  log = []
  holder = start_holder(log, DB::Connection::BUSY_WAIT_LIMIT + 1.0)
  wait_for_lock(log)

  started = monotonic
  message = ""
  begin
    DB.with { |c| c.execute("INSERT INTO events (who) VALUES (?)", ["waiter"]) }
  rescue DB::Error => e
    message = e.message
  end
  waited = monotonic - started
  holder.join

  assert_includes message, "database is locked"
  assert waited >= DB::Connection::BUSY_WAIT_LIMIT, "gave up after #{waited.round(2)} s"
  assert_equal ["locked", "committed"], log
  rows = DB.with { |c| c.execute("SELECT who FROM events ORDER BY id") }
  assert_equal ["holder"], rows.map { |r| r["who"].to_s }
  DB.disconnect
end

Cybertrain::Test.run!
