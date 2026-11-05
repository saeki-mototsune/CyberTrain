# A transaction opened with SQL (`exec_script("BEGIN")`, not begin! or
# DB.transaction) that SQLite rolled back on its own must not let later
# statements run in autocommit either (the gap left by
# saeki-mototsune/CyberTrain#158). The connection notices the rollback when
# a statement that started inside a transaction fails with SQLite back in
# autocommit, and refuses statements until the application ends the
# transaction with COMMIT, END or ROLLBACK.
#
# The rollback is forced with a full database (PRAGMA max_page_count), as in
# test/db_rolled_back_transaction.rb.
require "cybertrain/db"
require "cybertrain/test"

# This program links SQLite through FFI, so it cannot run under CRuby: its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB

RAW_PATH = "tmp/db_raw_transaction_rollback_test.sqlite3"

def small_database
  Dir.mkdir("tmp") unless Dir.exist?("tmp")
  [RAW_PATH, RAW_PATH + "-wal", RAW_PATH + "-shm"].each do |f|
    File.delete(f) if File.exist?(f)
  end
  conn = DB::Connection.new(RAW_PATH)
  conn.exec_script("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL);")
  pages = conn.execute("PRAGMA page_count")[0]["page_count"].to_s.to_i
  conn.execute("PRAGMA max_page_count = #{pages + 2}")
  conn
end

# Inserts large rows until SQLite refuses one; returns its message.
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

def try_script(c, sql)
  c.exec_script(sql)
  ""
rescue DB::Error => e
  e.message
end

def try_null_insert(c)
  c.execute("INSERT INTO t (v) VALUES (NULL)")
  ""
rescue DB::Error => e
  e.message
end

def rows(c)
  c.execute("SELECT v FROM t ORDER BY id").map { |r| r["v"].to_s }
end

GONE = "the enclosing transaction is no longer open"

test "after SQLite rolled back a SQL BEGIN, statements are refused until COMMIT" do
  c = small_database
  c.exec_script("BEGIN")
  assert_includes fill_until_full(c), "database or disk is full"

  assert_includes try_insert(c, "after the rollback"), GONE
  assert_includes try_script(c, "INSERT INTO t (v) VALUES ('script after the rollback');"), GONE
  # COMMIT is let through and fails as SQLite reports it: nothing was committed.
  assert_includes try_script(c, "COMMIT"), "no transaction is active"
  # The transaction is over: the connection works again.
  assert_equal "", try_insert(c, "next")
  assert_equal ["next"], rows(c)
  c.close
end

test "a ROLLBACK after SQLite already rolled back is accepted, not an error" do
  c = small_database
  c.exec_script("BEGIN")
  fill_until_full(c)
  assert_includes try_insert(c, "after the rollback"), GONE
  # The usual cleanup in a rescue: the transaction is already rolled back,
  # so this succeeds instead of masking the original error.
  assert_equal "", try_script(c, "ROLLBACK")
  assert_equal "", try_insert(c, "next")
  assert_equal ["next"], rows(c)

  # The same through execute.
  c.exec_script("BEGIN")
  fill_until_full(c)
  assert_includes try_insert(c, "after the second rollback"), GONE
  assert_equal [], c.execute("ROLLBACK")
  assert_equal "", try_insert(c, "after")
  assert_equal ["next", "after"], rows(c)
  c.close
end

test "ROLLBACK TO a savepoint does not end a lost transaction" do
  c = small_database
  c.exec_script("BEGIN")
  fill_until_full(c)
  assert_includes try_insert(c, "after the rollback"), GONE
  # ROLLBACK TO undoes part of a transaction and does not end it, so the
  # connection stays refused.
  assert_includes try_script(c, "ROLLBACK TO s"), GONE
  assert_includes try_insert(c, "still after the rollback"), GONE
  assert_equal "", try_script(c, "ROLLBACK")
  assert_equal [], rows(c)
  c.close
end

test "a script that starts with ROLLBACK is run, not skipped" do
  c = small_database
  c.exec_script("BEGIN")
  fill_until_full(c)
  assert_includes try_insert(c, "after the rollback"), GONE
  # Only a ROLLBACK on its own is skipped. Here the BEGIN after it must not
  # vanish silently: the script runs, and SQLite stops at its ROLLBACK.
  assert_includes try_script(c, "ROLLBACK; BEGIN"), "no transaction is active"
  # The ROLLBACK ended the lost transaction all the same.
  assert_equal "", try_insert(c, "next")
  assert_equal ["next"], rows(c)
  c.close
end

test "ROLLBACK TO is told from ROLLBACK through comments and line breaks" do
  c = small_database
  c.exec_script("BEGIN")
  fill_until_full(c)
  assert_includes try_insert(c, "after the rollback"), GONE
  # A ";" inside a comment does not end the statement, and a line break
  # separates keywords as a space does.
  assert_includes try_script(c, "ROLLBACK /* ; */ TO s"), GONE
  assert_includes try_script(c, "ROLLBACK\nTO s"), GONE
  assert_includes try_insert(c, "still after the rollback"), GONE
  # A comment after the ROLLBACK is not a second statement: still skipped.
  assert_equal "", try_script(c, "ROLLBACK; -- cleanup")
  assert_equal "", try_insert(c, "next")
  assert_equal ["next"], rows(c)
  c.close
end

test "the statement classifiers read SQL the way SQLite tokenizes it" do
  conn = DB::Connection
  # Ends a transaction (first statement only).
  assert conn.ends_transaction?("COMMIT")
  assert conn.ends_transaction?("  end transaction;")
  assert conn.ends_transaction?("/* why */ ROLLBACK")
  assert conn.ends_transaction?("-- note\nrollback transaction")
  assert conn.ends_transaction?("ROLLBACK; BEGIN")
  refute conn.ends_transaction?("ROLLBACK TO s")
  refute conn.ends_transaction?("ROLLBACK TRANSACTION TO SAVEPOINT s")
  refute conn.ends_transaction?("ROLLBACK /* ; */ TO s")
  refute conn.ends_transaction?("ROLLBACK\n\tTO s")
  refute conn.ends_transaction?("INSERT INTO t (v) VALUES ('ROLLBACK')")
  refute conn.ends_transaction?("BEGIN; ROLLBACK")
  # Only the exact statements: anything more in the first statement is not
  # an end SQLite would accept.
  assert conn.ends_transaction?("COMMIT TRANSACTION")
  refute conn.ends_transaction?("COMMIT 'bogus'")
  refute conn.ends_transaction?("ROLLBACK BOGUS")
  refute conn.ends_transaction?("END TRANSACTION now")
  # A standalone ROLLBACK: the one statement skipped after SQLite's rollback.
  assert conn.rollback_statement?("ROLLBACK")
  assert conn.rollback_statement?("rollback;")
  assert conn.rollback_statement?("ROLLBACK; -- cleanup")
  assert conn.rollback_statement?("ROLLBACK /* x; y */ ;  ;")
  refute conn.rollback_statement?("ROLLBACK; BEGIN")
  refute conn.rollback_statement?("ROLLBACK; /* c */ INSERT INTO t (v) VALUES ('a')")
  refute conn.rollback_statement?("ROLLBACK TO s")
  refute conn.rollback_statement?("ROLLBACK BOGUS")
  refute conn.rollback_statement?("ROLLBACK 'x'")
end

# A script whose own BEGIN opened the transaction SQLite then rolled back.
def full_script
  big = "x" * 2000
  script = +"BEGIN;"
  i = 0
  while i < 50
    script << " INSERT INTO t (v) VALUES ('#{big}');"
    i += 1
  end
  script
end

test "a script that opened the transaction itself is covered too" do
  c = small_database
  assert_includes try_script(c, full_script), "database or disk is full"
  assert_includes try_insert(c, "after the script"), GONE
  assert_equal "", try_script(c, "ROLLBACK")
  assert_equal "", try_insert(c, "next")
  assert_equal ["next"], rows(c)
  c.close
end

test "a BEGIN that fails on its own opened nothing and marks nothing" do
  c = small_database
  # A bare BEGIN that fails (here a syntax error; SQLITE_BUSY on BEGIN
  # IMMEDIATE is the same) never opened a transaction.
  assert_includes try_script(c, "BEGIN BOGUS"), "syntax error"
  assert_equal "", try_insert(c, "after the failed begin")
  assert_equal ["after the failed begin"], rows(c)
  c.close
end

# A script that opens its transaction after other statements
# (saeki-mototsune/CyberTrain#164): exec_script runs a script one statement
# at a time, so it sees the transaction open whatever came before the BEGIN.
def late_begin_script
  big = "x" * 2000
  script = +"CREATE TABLE IF NOT EXISTS u (v TEXT); BEGIN;"
  i = 0
  while i < 50
    script << " INSERT INTO t (v) VALUES ('#{big}');"
    i += 1
  end
  script
end

test "a script that opens its transaction after other statements is covered" do
  c = small_database
  assert_includes try_script(c, late_begin_script), "database or disk is full"
  assert_includes try_insert(c, "after the script"), GONE
  assert_equal "", try_script(c, "ROLLBACK")
  assert_equal "", try_insert(c, "next")
  assert_equal ["next"], rows(c)
  c.close
end

test "a script whose own BEGIN fails opened nothing and marks nothing" do
  c = small_database
  assert_includes try_script(c, "BEGIN BOGUS; INSERT INTO t (v) VALUES ('never');"), "syntax error"
  assert_equal "", try_insert(c, "after the failed script")
  assert_equal ["after the failed script"], rows(c)
  c.close
end

test "a script runs each statement once, trigger bodies as part of theirs" do
  c = small_database
  c.exec_script(
    "CREATE TABLE log (v TEXT); " \
    "CREATE TRIGGER g AFTER INSERT ON t BEGIN INSERT INTO log (v) VALUES (new.v); END; " \
    "INSERT INTO t (v) VALUES ('a'); -- a comment; not a statement\n" \
    "INSERT INTO t (v) VALUES ('b; with a semicolon');"
  )
  assert_equal ["a", "b; with a semicolon"], rows(c)
  logged = c.execute("SELECT v FROM log ORDER BY rowid").map { |r| r["v"].to_s }
  assert_equal ["a", "b; with a semicolon"], logged
  c.close
end

test "a failed statement that leaves the transaction open is not a rollback" do
  c = small_database
  c.exec_script("BEGIN")
  assert_equal "", try_insert(c, "a")
  # A constraint error undoes only its own statement.
  assert_includes try_null_insert(c), "NOT NULL constraint failed"
  assert_equal "", try_insert(c, "b")
  assert_equal "", try_script(c, "COMMIT")
  assert_equal ["a", "b"], rows(c)

  # Outside any transaction, a failed statement does not block the next one.
  assert_includes try_null_insert(c), "NOT NULL constraint failed"
  assert_equal "", try_insert(c, "c")
  assert_equal ["a", "b", "c"], rows(c)
  c.close
end

Cybertrain::Test.run!
