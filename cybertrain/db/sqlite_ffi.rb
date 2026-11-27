# Cybertrain::DB::SQLite3 -- the raw SQLite C API, bound through Spinel FFI.
#
# Only Cybertrain::DB::Connection talks to this module. Two FFI rules from
# spike 6 (spikes/NOTES.md) apply to every caller:
#
# * Out-parameters (the db handle from open_v2, the statement from
#   prepare_v2) go through a fresh `malloc(8)` scratch slot per call, read
#   back with `read_ptr` and then `free`d. A static `ffi_buffer` is shared by
#   the whole process and crashes as soon as two threads prepare at once.
# * `sqlite3_bind_text` and `sqlite3_bind_blob` take the integer literal -1
#   as their destructor argument: that is SQLITE_TRANSIENT, so SQLite copies
#   the bytes.
#
# `offload: true` marks the calls that can wait for another connection's
# lock (and so for the busy handler below): preparing, sqlite3_exec and
# the first step of a statement. Spinel runs such a call on a pool thread
# of its own while the calling green thread waits as for I/O, so the
# worker runs its other green threads meanwhile, the lock holder among
# them (docs/FFI.md, "`offload: true` (Spinel's own)"; spikes/NOTES.md
# rule 80, docs/spinel-feedback.md AB). `blocking: true` alone does not
# do that: the worker's other green threads wait for as long as the call
# runs, which stalled a one-worker server for 5 s
# (saeki-mototsune/CyberTrain#134). What offload asks, and why it holds
# here:
#
# * the C function may run on a different OS thread at each call. The
#   SQLite this links is built multi-thread (`sqlite3_threadsafe()` = 2 on
#   macOS 3.54.0; distribution builds are 1, serialized): a connection
#   and its statements may move between threads as long as two never use
#   them at once, and Pool hands each Connection to one thread at a time.
#   sqlite3_errmsg is the connection's, not the thread's.
# * no `ffi_callback` anywhere in the program (offload refuses one): the
#   busy handler is C, and sqlite3_exec gets no callback.
# * out-parameters are malloc'd per call (above), never a shared buffer.
#
# Each offloaded call costs a hand-off to the pool and back (about 7 us),
# so a statement's later steps, which only read rows (a statement takes
# its locks in its first step), go through the plain `sqlite3_step`.
module Cybertrain
  module DB
    module SQLite3
      ffi_lib "sqlite3"

      # The busy handler: retry every 100 microseconds, inside the call,
      # until limit_ms have passed since SQLite first asked for this lock;
      # then SQLite returns SQLITE_BUSY ("database is locked"). The call is
      # offloaded, so the sleep holds a pool thread, not the worker. The
      # per-connection slot (malloc(16), owned by the Connection) holds the
      # limit and when the current wait started, in nanoseconds on the
      # monotonic clock (milliseconds rounded a 5 s wait down to 4.999 s
      # as Ruby's clock saw it). SQLite's
      # own busy_timeout slept 1, 2, 5 ... 100 ms between tries; with
      # SPINEL_WORKERS > 1 the loser of two inserts slept a millisecond or
      # more for a lock held for microseconds. SQLite calls the handler
      # only when waiting can help: a stale WAL snapshot still fails at
      # once.
      ffi_source <<~C
        #include <time.h>
        extern int sqlite3_busy_handler(void *db, int (*cb)(void *, int), void *arg);
        static long long cybertrain_now_ns(void) {
          struct timespec ts;
          clock_gettime(CLOCK_MONOTONIC, &ts);
          return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
        }
        static int cybertrain_sqlite_busy(void *arg, int count) {
          long long *slot = (long long *)arg;
          long long now = cybertrain_now_ns();
          if (count == 0) slot[1] = now;
          if (now - slot[1] >= slot[0]) return 0;
          struct timespec ts = { 0, 100000 };
          nanosleep(&ts, NULL);
          return 1;
        }
        int cybertrain_sqlite_set_busy_handler(void *db, void *slot, long limit_ms) {
          ((long long *)slot)[0] = (long long)limit_ms * 1000000LL;
          ((long long *)slot)[1] = 0;
          return sqlite3_busy_handler(db, cybertrain_sqlite_busy, slot);
        }
      C
      ffi_func :cybertrain_sqlite_set_busy_handler, [:ptr, :ptr, :long], :int

      # The first sqlite3_step of a statement, offloaded: the step that
      # takes the statement's locks and may wait in the busy handler. Later
      # steps use the plain binding of sqlite3_step below.
      ffi_source <<~C
        extern int sqlite3_step(void *);
        int cybertrain_sqlite_step_first(void *stmt) {
          return sqlite3_step(stmt);
        }
      C
      ffi_func :cybertrain_sqlite_step_first, [:ptr], :int, offload: true

      # The next statement of a script, prepared from byte offset `offset` of
      # sql: Connection#exec_script runs a script one statement at a time
      # (saeki-mototsune/CyberTrain#164), where sqlite3_exec would run it
      # whole and show SQLite's state only before and after. Empty
      # statements (whitespace, comments, a lone ";") are skipped here.
      # Returns the offset just past the statement, with the statement in
      # *stmt_out; NO_STATEMENT when none is left; or -rc when preparing
      # failed (sqlite3_errmsg has the message). A trigger body's ";" stays
      # inside its CREATE TRIGGER: SQLite's own parser splits the text.
      ffi_source <<~C
        extern int sqlite3_prepare_v2(void *, const char *, int, void **, const char **);
        extern int sqlite3_finalize(void *);
        long cybertrain_sqlite_prepare_at(void *db, const char *sql, long offset, void **stmt_out) {
          const char *at = sql + offset;
          *stmt_out = 0;
          while (*at) {
            const char *tail = at;
            int rc = sqlite3_prepare_v2(db, at, -1, stmt_out, &tail);
            if (rc != 0) return -(long)rc;
            if (*stmt_out) return (long)(tail - sql);
            if (tail == at) break;
            at = tail;
          }
          return -1000000;
        }
      C
      ffi_func :cybertrain_sqlite_prepare_at, [:ptr, :str, :long, :ptr], :long, offload: true
      ffi_const :NO_STATEMENT, -1000000

      # A DATETIME column read straight into UTC epoch microseconds, with no
      # Ruby String in between: the text SQLite already holds is parsed in
      # place. The shapes are Cast.parse_time's ISO 8601 ones:
      # "YYYY-MM-DD[T ]HH:MM:SS", then an optional "." and 1 to 9 fraction
      # digits (the first six kept), then an optional "Z", "+HH:MM",
      # "-HH:MM", "+HHMM" or "-HHMM" (applied, so the answer is the UTC
      # instant), and nothing after it; a year from 1970 on, valid month,
      # day, hour, minute and second. The answer is seconds * 1000000 +
      # microseconds. -1 means "not this shape" (or before the epoch once
      # the offset is applied), and the caller reads the column as text, as
      # it always did. Called only after sqlite3_column_type said TEXT.
      # sqlite3_column_text is declared here too: Spinel after 2026.09.12
      # declares ffi_func functions under names of its own, and without this
      # the call compiled as an implicit `int` function and cut the pointer
      # in half (a SIGSEGV). The declaration is the one 2026.09.12 emits
      # (NOTES rule 59), so it builds on both.
      ffi_source <<~C
        extern int sqlite3_column_bytes(void *, int);
        extern const char *sqlite3_column_text(void *, int);
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
          int n = sqlite3_column_bytes(stmt, col);
          if (!s || n < 19) return -1;
          if (s[4] != '-' || s[7] != '-' || s[13] != ':' || s[16] != ':') return -1;
          if (s[10] != 'T' && s[10] != ' ') return -1;
          int y = cybertrain_digits(s, 0, 4), mo = cybertrain_digits(s, 5, 2), d = cybertrain_digits(s, 8, 2);
          int h = cybertrain_digits(s, 11, 2), mi = cybertrain_digits(s, 14, 2), se = cybertrain_digits(s, 17, 2);
          if (y < 1970 || mo < 1 || mo > 12 || d < 1 || h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 59) return -1;
          static const int dim[] = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
          int leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
          if (d > dim[mo - 1] + (mo == 2 && leap)) return -1;
          int i = 19;
          long long usec = 0;
          if (i < n && s[i] == '.') {
            int digits = 0;
            i++;
            while (i < n && s[i] >= '0' && s[i] <= '9') {
              if (digits < 6) usec = usec * 10 + (s[i] - '0');
              digits++;
              i++;
            }
            if (digits == 0 || digits > 9) return -1;
            for (; digits < 6; digits++) usec *= 10;
          }
          long long offset = 0;
          if (i < n) {
            int rest = n - i, oh, om;
            if (s[i] == 'Z') {
              if (rest != 1) return -1;
            } else if (s[i] == '+' || s[i] == '-') {
              if (rest != 5 && rest != 6) return -1;
              oh = cybertrain_digits(s, i + 1, 2);
              if (rest == 6 && s[i + 3] == ':') om = cybertrain_digits(s, i + 4, 2);
              else if (rest == 5) om = cybertrain_digits(s, i + 3, 2);
              else return -1;
              if (oh < 0 || oh > 23 || om < 0 || om > 59) return -1;
              offset = (long long)(oh * 3600 + om * 60);
              if (s[i] == '-') offset = -offset;
            } else {
              return -1;
            }
          }
          long long yy = y - (mo <= 2);
          long long era = yy / 400, yoe = yy - era * 400;
          long long doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
          long long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
          long long secs = (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se - offset;
          if (secs < 0) return -1;
          return (long)(secs * 1000000 + usec);
        }
      C
      ffi_func :cybertrain_sqlite_column_epoch, [:ptr, :int], :long

      # A BLOB cell's bytes, NULs included: the :binstr bridge of
      # GzipFFI.cybertrain_bytes_at. It publishes the byte count in
      # sp_ffi_bin_len (the TLS int the codegen declares for a module with a
      # :binstr function) and returns SQLite's pointer, so Spinel copies
      # exactly that many bytes into a new String before the next step can
      # reuse the buffer. sqlite3_column_blob comes first, then
      # sqlite3_column_bytes, the order SQLite documents. A zero-length blob
      # has a NULL pointer: "" is returned for it, so the String is empty,
      # never nil. Called only after sqlite3_column_type said BLOB.
      ffi_source <<~C
        extern const void *sqlite3_column_blob(void *, int);
        const char *cybertrain_sqlite_column_blob(void *stmt, int col) {
          const void *p = sqlite3_column_blob(stmt, col);
          int n = sqlite3_column_bytes(stmt, col);
          if (!p) n = 0;
          sp_ffi_bin_len = n;
          return p ? (const char *)p : "";
        }
      C
      ffi_func :cybertrain_sqlite_column_blob, [:ptr, :int], :binstr

      ffi_const :OK, 0
      ffi_const :BUSY, 5
      ffi_const :ROW, 100
      ffi_const :DONE, 101

      ffi_const :OPEN_READWRITE, 0x00000002
      ffi_const :OPEN_CREATE, 0x00000004
      ffi_const :OPEN_URI, 0x00000040

      # sqlite3_column_type results.
      ffi_const :INTEGER, 1
      ffi_const :FLOAT, 2
      ffi_const :BLOB, 4
      ffi_const :NULL_TYPE, 5

      # sqlite3_limit categories.
      ffi_const :LIMIT_VARIABLE_NUMBER, 9

      ffi_func :sqlite3_open_v2, [:str, :ptr, :int, :ptr], :int
      ffi_func :sqlite3_close, [:ptr], :int
      ffi_func :sqlite3_exec, [:ptr, :str, :ptr, :ptr, :ptr], :int, offload: true
      ffi_func :sqlite3_errmsg, [:ptr], :str
      ffi_func :sqlite3_get_autocommit, [:ptr], :int
      # sqlite3_limit(db, id, -1) reads a limit without changing it
      # (Connection#variable_limit asks SQLITE_LIMIT_VARIABLE_NUMBER, 9).
      ffi_func :sqlite3_limit, [:ptr, :int, :int], :int

      ffi_func :sqlite3_prepare_v2, [:ptr, :str, :int, :ptr, :ptr], :int, offload: true
      ffi_func :sqlite3_bind_int64, [:ptr, :int, :long], :int
      ffi_func :sqlite3_bind_double, [:ptr, :int, :double], :int
      ffi_func :sqlite3_bind_text, [:ptr, :int, :str, :int, :ptr], :int
      # The bytes go through :str with their explicit length, as
      # GzipFFI.cybertrain_gunzip_bounded receives a body: SQLite reads that
      # many bytes from the pointer, so a NUL inside does not end them.
      ffi_func :sqlite3_bind_blob, [:ptr, :int, :str, :int, :ptr], :int
      ffi_func :sqlite3_bind_null, [:ptr, :int], :int
      # Row steps after the first (cybertrain_sqlite_step_first): they read
      # pages, and wait for no lock. `blocking: true` lets a collection run
      # meanwhile.
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
