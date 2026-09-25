# SPIKE (throwaway): extended SQLite3 FFI bindings for Spinel, built
# from examples/ffi/sqlite/sqlite3_lib.rb. Adds open_v2, prepared
# statement binds (int64/double/text/null), column type detection,
# reset, and the pragma/introspection surface the adapter needs.
#
# bind_text's destructor arg: pass the literal -1 directly (int -> :ptr
# coercion, see spinel/test/ffi_ptr_int_literal.rb) to get
# SQLITE_TRANSIENT — no C shim needed, `ffi_func` accepts an Integer
# where :ptr is declared and emits ((void *)-1LL).
module SQL
  ffi_lib "sqlite3"

  ffi_const :OK,   0
  ffi_const :ROW,  100
  ffi_const :DONE, 101

  ffi_const :OPEN_READWRITE, 0x00000002
  ffi_const :OPEN_CREATE,    0x00000004

  # sqlite3_column_type return values.
  ffi_const :INTEGER,  1
  ffi_const :FLOAT,    2
  ffi_const :TEXT,     3
  ffi_const :BLOB,     4
  ffi_const :NULL_TYPE, 5

  # --- Core open/close/exec ---
  ffi_func :sqlite3_open,              [:str, :ptr],                   :int
  ffi_func :sqlite3_open_v2,           [:str, :ptr, :int, :ptr],       :int
  ffi_func :sqlite3_close,             [:ptr],                         :int
  ffi_func :sqlite3_exec,              [:ptr, :str, :ptr, :ptr, :ptr], :int
  ffi_func :sqlite3_errmsg,            [:ptr],                         :str

  # --- Prepared statements ---
  ffi_func :sqlite3_prepare_v2,        [:ptr, :str, :int, :ptr, :ptr], :int
  ffi_func :sqlite3_bind_int64,        [:ptr, :int, :long],            :int
  ffi_func :sqlite3_bind_double,       [:ptr, :int, :double],          :int
  ffi_func :sqlite3_bind_text,         [:ptr, :int, :str, :int, :ptr], :int
  ffi_func :sqlite3_bind_null,         [:ptr, :int],                   :int
  ffi_func :sqlite3_step,              [:ptr],                         :int
  ffi_func :sqlite3_reset,             [:ptr],                         :int
  ffi_func :sqlite3_finalize,          [:ptr],                         :int

  # --- Column accessors ---
  ffi_func :sqlite3_column_count,      [:ptr],                         :int
  ffi_func :sqlite3_column_name,       [:ptr, :int],                   :str
  ffi_func :sqlite3_column_type,       [:ptr, :int],                   :int
  ffi_func :sqlite3_column_int64,      [:ptr, :int],                   :long
  ffi_func :sqlite3_column_double,     [:ptr, :int],                   :double
  ffi_func :sqlite3_column_text,       [:ptr, :int],                   :str

  # --- Misc ---
  ffi_func :sqlite3_last_insert_rowid, [:ptr],                         :long
  ffi_func :sqlite3_changes,           [:ptr],                         :int

  # Out-params — sqlite3_open(_v2) writes the db handle here,
  # prepare_v2 writes the stmt handle.
  #
  # CONFIRMED HAZARD (spikes/06_sqlite_pool/race_stress*.rb): an
  # ffi_buffer is a SINGLE static buffer shared by the whole process
  # (docs/FFI.md: "Lifetime: static. The buffer lives for the whole
  # program."). Two threads calling sqlite3_prepare_v2 (or open_v2)
  # concurrently — even against entirely separate sqlite3 connections
  # — race on writing/reading this same buffer and reliably SIGSEGV
  # under load. db_out/stmt_out below must NOT be used from more than
  # one thread without external synchronization.
  #
  # Fix used by Connection/Adapter in this spike: malloc a fresh
  # 8-byte scratch pointer per call instead, so each thread's
  # open/prepare gets its own out-param slot with zero shared state.
  ffi_buffer :db_out,   8
  ffi_buffer :stmt_out, 8
  ffi_read_ptr :read_ptr, 0

  # Per-call scratch out-param, safe for concurrent use: malloc a
  # fresh 8-byte slot, pass it as the out-param, read it back, free
  # it. No sharing across threads because nothing is static.
  ffi_func :malloc, [:size_t], :ptr
  ffi_func :free,   [:ptr],    :void
end

# Tiny helper module. Quote-escapes single quotes for inline SQL —
# good enough for the demo's well-known input strings.
module Sql
  def self.q(s)
    s.gsub("'", "''")
  end
end
