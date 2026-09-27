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

      ffi_func :sqlite3_column_count, [:ptr], :int
      ffi_func :sqlite3_column_name, [:ptr, :int], :str
      ffi_func :sqlite3_column_type, [:ptr, :int], :int
      ffi_func :sqlite3_column_int64, [:ptr, :int], :long
      ffi_func :sqlite3_column_double, [:ptr, :int], :double
      ffi_func :sqlite3_column_text, [:ptr, :int], :str

      ffi_func :sqlite3_changes, [:ptr], :int
      ffi_func :sqlite3_last_insert_rowid, [:ptr], :long

      ffi_func :malloc, [:size_t], :ptr
      ffi_func :free, [:ptr], :void
      ffi_read_ptr :read_ptr, 0
    end
  end
end
