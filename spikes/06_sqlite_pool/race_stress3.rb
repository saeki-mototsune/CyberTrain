# SPIKE (throwaway): same stress as race_stress2.rb, but using a
# malloc'd per-call scratch pointer instead of the shared static
# db_out/stmt_out ffi_buffer, to verify the fix.
require_relative "sqlite3_lib"

N_THREADS = 16
N_ITERS = 3000
bad = Mutex.new
bad_count = 0
err_count = 0

threads = []
N_THREADS.times { |tid|
  threads << Thread.new {
    scratch = SQL.malloc(8)
    rc = SQL.sqlite3_open_v2(":memory:", scratch,
                              SQL::OPEN_READWRITE | SQL::OPEN_CREATE, nil)
    raise "open failed" if rc != SQL::OK
    db = SQL.read_ptr(scratch)
    SQL.sqlite3_exec(db, "CREATE TABLE t (x INTEGER)", nil, nil, nil)
    i = 0
    while i < N_ITERS
      rc2 = SQL.sqlite3_prepare_v2(db, "SELECT ? AS x", -1, scratch, nil)
      if rc2 != SQL::OK
        bad.synchronize { err_count += 1 }
        i += 1
        next
      end
      stmt = SQL.read_ptr(scratch)
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
    SQL.free(scratch)
  }
}
threads.each { |t| t.join }
puts "race_stress3 (per-thread malloc'd scratch, no shared out-param): mismatches=" + bad_count.to_s + " prepare_errs=" + err_count.to_s + " / " + (N_THREADS * N_ITERS).to_s
puts "race_stress3 ok"
