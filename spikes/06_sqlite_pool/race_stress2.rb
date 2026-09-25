# SPIKE (throwaway): isolate the stmt_out race from any sqlite3
# connection-sharing question. Each thread gets its OWN sqlite3
# connection (its own :memory: db) so nothing about the sqlite3
# handle is shared — the ONLY shared state across threads is
# SQL.stmt_out, the static ffi_buffer out-param. If this crashes or
# corrupts, the static ffi_buffer is the confirmed culprit, exactly
# as used by pool_test.rb's Adapter#execute across pooled Connections.
require_relative "sqlite3_lib"

N_THREADS = 16
N_ITERS = 3000
bad = Mutex.new
bad_count = 0
err_count = 0

threads = []
N_THREADS.times { |tid|
  threads << Thread.new {
    rc = SQL.sqlite3_open_v2(":memory:", SQL.db_out,
                              SQL::OPEN_READWRITE | SQL::OPEN_CREATE, nil)
    raise "open failed" if rc != SQL::OK
    # NOTE: SQL.db_out is ALSO the shared static buffer — reading it
    # right after our own open call is itself part of what we're
    # testing (this mirrors Connection#initialize in adapter.rb).
    db = SQL.read_ptr(SQL.db_out)
    SQL.sqlite3_exec(db, "CREATE TABLE t (x INTEGER)", nil, nil, nil)
    i = 0
    while i < N_ITERS
      rc2 = SQL.sqlite3_prepare_v2(db, "SELECT ? AS x", -1, SQL.stmt_out, nil)
      if rc2 != SQL::OK
        bad.synchronize { err_count += 1 }
        i += 1
        next
      end
      stmt = SQL.read_ptr(SQL.stmt_out)
      SQL.sqlite3_bind_int64(stmt, 1, tid * 1_000_000 + i)
      rc3 = SQL.sqlite3_step(stmt)
      if rc3 != SQL::ROW
        bad.synchronize { bad_count += 1 }
      else
        got = SQL.sqlite3_column_int64(stmt, 0)
        if got != tid * 1_000_000 + i
          bad.synchronize { bad_count += 1 }
        end
      end
      SQL.sqlite3_finalize(stmt)
      i += 1
    end
    SQL.sqlite3_close(db)
  }
}
threads.each { |t| t.join }
puts "race_stress2 (separate connections per thread, shared static stmt_out/db_out): mismatches=" + bad_count.to_s + " prepare_errs=" + err_count.to_s + " / " + (N_THREADS * N_ITERS).to_s
puts "race_stress2 ok"
