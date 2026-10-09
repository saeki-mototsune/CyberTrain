# Cybertrain::DB::SQLite3 -- the raw SQLite C API, bound through Spinel FFI.
#
# Only Cybertrain::DB::Connection talks to this module. Two FFI rules from
# spike 6 (spikes/NOTES.md) apply to every caller:
#
# * Out-parameters (the db handle from open_v2, the statement from
#   prepare_v2) go through a fresh `malloc(8)` scratch slot per call, read
#   back with `read_ptr` and then `free`d. A static `ffi_buffer` is shared by
#   the whole process and crashes as soon as two threads prepare at once.
# * `sqlite3_bind_text` takes the integer literal -1 as its destructor
#   argument: that is SQLITE_TRANSIENT, so SQLite copies the string.
#
# `blocking: true` marks the calls that can wait on disk or on another
# connection's lock (busy_timeout). Spinel 2026.09.12 accepts and ignores the
# option, so today such a call still holds its OS worker while it waits.
module Cybertrain
  module DB
    module SQLite3
      ffi_lib "sqlite3"

      # A busy handler that retries every 100 microseconds, for about five
      # seconds (the busy_timeout it replaces). SQLite's own busy_timeout
      # sleeps 1, 2, 5, 10 ... 100 ms between tries; with SPINEL_WORKERS > 1
      # two inserts meet on the write lock often, and the loser slept a whole
      # millisecond or more (holding its OS worker, see above) for a lock
      # held for microseconds.
      ffi_source <<~C
        #include <time.h>
        extern int sqlite3_busy_handler(void *db, int (*cb)(void *, int), void *arg);
        static int cybertrain_sqlite_busy(void *arg, int count) {
          (void)arg;
          if (count >= 50000) return 0;
          struct timespec ts = { 0, 100000 };
          nanosleep(&ts, NULL);
          return 1;
        }
        int cybertrain_sqlite_set_busy_handler(void *db) {
          return sqlite3_busy_handler(db, cybertrain_sqlite_busy, NULL);
        }
      C
      ffi_func :cybertrain_sqlite_set_busy_handler, [:ptr], :int

      # A DATETIME column read straight into UTC epoch seconds, with no Ruby
      # String in between: the text SQLite already holds is parsed in place.
      # -1 means "not this shape" ("YYYY-MM-DD[T ]HH:MM:SS" and anything after
      # it, a year from 1970 on, valid month, day, hour, minute and second,
      # the same shape and ranges as Cast.parse_time), and the caller reads
      # the column as text, as it always did. Called only after
      # sqlite3_column_type said TEXT.
      ffi_source <<~C
        extern int sqlite3_column_bytes(void *, int);
        static int cybertrain_digits(const unsigned char *s, int from, int n) {
          int v = 0;
          for (int i = 0; i < n; i++) {
            unsigned d = (unsigned)(s[from + i] - '0');
            if (d > 9) return -1;
            v = v * 10 + (int)d;
          }
          return v;
        }
        long cybertrain_sqlite_column_epoch(void *stmt, int col) {
          const unsigned char *s = (const unsigned char *)sqlite3_column_text(stmt, col);
          if (!s || sqlite3_column_bytes(stmt, col) < 19) return -1;
          if (s[4] != '-' || s[7] != '-' || s[13] != ':' || s[16] != ':') return -1;
          if (s[10] != 'T' && s[10] != ' ') return -1;
          int y = cybertrain_digits(s, 0, 4), mo = cybertrain_digits(s, 5, 2), d = cybertrain_digits(s, 8, 2);
          int h = cybertrain_digits(s, 11, 2), mi = cybertrain_digits(s, 14, 2), se = cybertrain_digits(s, 17, 2);
          if (y < 1970 || mo < 1 || mo > 12 || d < 1 || h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 59) return -1;
          static const int dim[] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
          int leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
          if (d > dim[mo - 1] + (mo == 2 && leap)) return -1;
          long long yy = y - (mo <= 2);
          long long era = yy / 400, yoe = yy - era * 400;
          long long doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
          long long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
          return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se;
        }
      C
      ffi_func :cybertrain_sqlite_column_epoch, [:ptr, :int], :long

      ffi_const :OK, 0
      ffi_const :ROW, 100
      ffi_const :DONE, 101

      ffi_const :OPEN_READWRITE, 0x00000002
      ffi_const :OPEN_CREATE, 0x00000004
      ffi_const :OPEN_URI, 0x00000040

      # sqlite3_column_type results.
      ffi_const :INTEGER, 1
      ffi_const :FLOAT, 2
      ffi_const :TEXT, 3
      ffi_const :BLOB, 4
      ffi_const :NULL_TYPE, 5

      ffi_func :sqlite3_open_v2, [:str, :ptr, :int, :ptr], :int
      ffi_func :sqlite3_close, [:ptr], :int
      ffi_func :sqlite3_exec, [:ptr, :str, :ptr, :ptr, :ptr], :int, blocking: true
      ffi_func :sqlite3_errmsg, [:ptr], :str
      ffi_func :sqlite3_get_autocommit, [:ptr], :int

      ffi_func :sqlite3_prepare_v2, [:ptr, :str, :int, :ptr, :ptr], :int, blocking: true
      ffi_func :sqlite3_bind_int64, [:ptr, :int, :long], :int
      ffi_func :sqlite3_bind_double, [:ptr, :int, :double], :int
      ffi_func :sqlite3_bind_text, [:ptr, :int, :str, :int, :ptr], :int
      ffi_func :sqlite3_bind_null, [:ptr, :int], :int
      ffi_func :sqlite3_step, [:ptr], :int, blocking: true
      ffi_func :sqlite3_finalize, [:ptr], :int
      ffi_func :sqlite3_reset, [:ptr], :int
      ffi_func :sqlite3_clear_bindings, [:ptr], :int

      ffi_func :sqlite3_column_count, [:ptr], :int
      ffi_func :sqlite3_column_name, [:ptr, :int], :str
      ffi_func :sqlite3_column_type, [:ptr, :int], :int
      ffi_func :sqlite3_column_int64, [:ptr, :int], :long
      ffi_func :sqlite3_column_double, [:ptr, :int], :double
      ffi_func :sqlite3_column_text, [:ptr, :int], :str
      ffi_func :sqlite3_column_decltype, [:ptr, :int], :str

      ffi_func :sqlite3_changes, [:ptr], :int
      ffi_func :sqlite3_last_insert_rowid, [:ptr], :long

      ffi_func :malloc, [:size_t], :ptr
      ffi_func :free, [:ptr], :void
      ffi_read_ptr :read_ptr, 0
    end
  end
end
