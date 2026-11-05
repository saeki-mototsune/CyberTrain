# A statement inside a transaction that SQLite already rolled back on its
# own must not run (saeki-mototsune/CyberTrain#158). SQLite rolls an
# explicit transaction back after SQLITE_FULL, IOERR, BUSY or NOMEM; if the
# application rescues that error inside the block and carries on, every
# later statement used to run in autocommit and commit by itself, while the
# block's COMMIT then failed, so the transaction was neither all nor
# nothing.
#
# The rollback is forced with a full database: PRAGMA max_page_count just
# above the current size, then rows until an INSERT fails with
# "database or disk is full".
require "cybertrain/db"
require "cybertrain/test"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB

FULL_PATH = "tmp/db_rolled_back_transaction_test.sqlite3"

def reset_full_file
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  [FULL_PATH, FULL_PATH + "-wal", FULL_PATH + "-shm"].each do |f|
    File.delete(f) if File.exist?(f)
  end
end

def connect_small_database
  reset_full_file
  DB.connect(FULL_PATH, size: 1)
  DB.with do |c|
    c.exec_script("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")
    pages = c.execute("PRAGMA page_count")[0]["page_count"].to_s.to_i
    c.execute("PRAGMA max_page_count = #{pages + 2}")
  end
  nil
end

# Inserts large rows until SQLite refuses one; returns its message. A plain
# method, so its rescue is not inside the yielding block (NOTES rules 32, 45).
def fill_until_full(c)
  big = "x" * 2000
  i = 0
  while i < 1000
    c.execute("INSERT INTO t (v) VALUES (?)", [big])
    i += 1
  end
  ""
rescue DB::Error => e
  e.message
end

# Runs one statement; returns the error message, or "" when it ran.
def try_insert(c, value)
  c.execute("INSERT INTO t (v) VALUES (?)", [value])
  ""
rescue DB::Error => e
  e.message
end

# Runs one script through exec_script; returns the error message, or ""
# when it ran.
def try_script(c)
  c.exec_script("INSERT INTO t (v) VALUES ('after the rollback, as a script');")
  ""
rescue DB::Error => e
  e.message
end

def row_count
  DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM t")[0]["n"].to_s.to_i }
end

# Runs the whole transaction; returns its error message, or "" when it
# committed.
def run_rescuing_transaction(log)
  DB.transaction do |c|
    log << fill_until_full(c)
    log << try_insert(c, "after the rollback")
    log << try_script(c)
  end
  ""
rescue DB::Error => e
  e.message
end

test "a statement after SQLite rolled the transaction back is refused" do
  connect_small_database
  log = []
  outcome = run_rescuing_transaction(log)

  assert_includes log[0], "database or disk is full"
  # The statement after the rollback did not run...
  assert_includes log[1], "the enclosing transaction is no longer open"
  # exec_script is refused the same way.
  assert_includes log[2], "the enclosing transaction is no longer open"
  # ...so nothing of the transaction is left: the rows before the failure
  # went with SQLite's rollback, and the ones after never ran.
  assert_equal 0, row_count
  # The block's own end still reports the transaction as failed.
  refute outcome.empty?, "the transaction reported success"
  DB.disconnect
end

test "the connection works again once the failed transaction has ended" do
  connect_small_database
  run_rescuing_transaction([])
  DB.with { |c| c.execute("INSERT INTO t (v) VALUES (?)", ["next request"]) }
  assert_equal 1, row_count
  DB.transaction { |c| c.execute("INSERT INTO t (v) VALUES (?)", ["next transaction"]) }
  assert_equal 2, row_count
  DB.disconnect
end

Cybertrain::Test.run!
