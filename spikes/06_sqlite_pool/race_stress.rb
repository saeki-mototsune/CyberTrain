# SPIKE (throwaway): the ffi_buffer out-params (db_out/stmt_out) are
# STATIC and shared by the whole module (docs/FFI.md: "Lifetime:
# static. The buffer lives for the whole program."). sqlite3_prepare_v2
# writes the new stmt ptr into SQL.stmt_out, then we immediately
# read_ptr it back — if two threads interleave prepare_v2/read_ptr on
# the SAME buffer, a thread can read the OTHER thread's stmt pointer.
# This tries hard to trigger that: many threads hammering prepare_v2
# on one shared db handle, with NO app-level lock around the
# buffer, checking each row for the value it itself bound.
#
# Also uses one shared sqlite3 handle across threads without
# SQLITE_OPEN_FULLMUTEX, which is its own hazard (sqlite3 says a
# single connection is only safe for concurrent use in "serialized"
# mode); ATTENTION: a failure here could come from either hazard, so
# this is read as "is naive concurrent FFI dangerous", not as an
# isolated stmt_out-only test.
require_relative "sqlite3_lib"

rc = SQL.sqlite3_open_v2(":memory:", SQL.db_out,
                          SQL::OPEN_READWRITE | SQL::OPEN_CREATE, nil)
raise "open failed" if rc != SQL::OK
db = SQL.read_ptr(SQL.db_out)

N_THREADS = 16
N_ITERS = 3000
bad = Mutex.new
bad_count = 0
crash_count = 0

threads = []
N_THREADS.times { |tid|
  threads << Thread.new {
    i = 0
    while i < N_ITERS
      rc2 = SQL.sqlite3_prepare_v2(db, "SELECT ? AS x", -1, SQL.stmt_out, nil)
      if rc2 != SQL::OK
        bad.synchronize { crash_count += 1 }
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
  }
}
threads.each { |t| t.join }
puts "race_stress (NO app-level lock around stmt_out/prepare): mismatches=" + bad_count.to_s + " prepare_errs=" + crash_count.to_s + " / " + (N_THREADS * N_ITERS).to_s
puts "race_stress ok"
