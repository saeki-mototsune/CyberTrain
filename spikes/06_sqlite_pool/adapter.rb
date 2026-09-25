# SPIKE (throwaway): Connection wraps a :ptr as a plain ivar (per
# docs/FFI.md "wrap them in a class with a ptr-typed ivar" escape
# hatch for "pointers can't enter polymorphic values"). Adapter#execute
# returns Array<Hash<String, value>> rows; report what Spinel infers
# for the hash value type.
#
# IMPORTANT: open/prepare use a malloc'd-per-call scratch pointer for
# the out-param, NOT SQL.db_out/SQL.stmt_out. Those are static
# ffi_buffers shared by the whole process; race_stress2.rb reliably
# SIGSEGVs within a few thousand concurrent prepare_v2 calls when
# multiple threads share them, even across independent connections.
# See sqlite3_lib.rb's comment on SQL.malloc/SQL.free.
require_relative "sqlite3_lib"

class Connection
  def initialize(path)
    scratch = SQL.malloc(8)
    rc = SQL.sqlite3_open_v2(path, scratch,
                              SQL::OPEN_READWRITE | SQL::OPEN_CREATE, nil)
    raise "open failed rc=#{rc}" if rc != SQL::OK
    @ptr = SQL.read_ptr(scratch)
    SQL.free(scratch)
    exec("PRAGMA journal_mode=WAL")
    exec("PRAGMA busy_timeout=5000")
    exec("PRAGMA foreign_keys=ON")
  end

  def ptr
    @ptr
  end

  def exec(sql)
    rc = SQL.sqlite3_exec(@ptr, sql, nil, nil, nil)
    raise "exec failed: #{SQL.sqlite3_errmsg(@ptr)} sql=#{sql}" if rc != SQL::OK
  end

  def close
    SQL.sqlite3_close(@ptr)
    @ptr = nil
  end
end

class Adapter
  def initialize(conn)
    @conn = conn
  end

  # binds: Array of Integer/Float/String/nil, positional (1-based in sqlite).
  # Returns Array<Hash<String, value>> for SELECT, or [] for DDL/DML
  # (caller can use last_insert_rowid/changes for those).
  def execute(sql, binds)
    db = @conn.ptr
    scratch = SQL.malloc(8)
    rc = SQL.sqlite3_prepare_v2(db, sql, -1, scratch, nil)
    raise "prepare failed: #{SQL.sqlite3_errmsg(db)} sql=#{sql}" if rc != SQL::OK
    stmt = SQL.read_ptr(scratch)
    SQL.free(scratch)

    i = 1
    binds.each { |b|
      if b == nil
        SQL.sqlite3_bind_null(stmt, i)
      elsif b.is_a?(Integer)
        SQL.sqlite3_bind_int64(stmt, i, b)
      elsif b.is_a?(Float)
        SQL.sqlite3_bind_double(stmt, i, b)
      else
        SQL.sqlite3_bind_text(stmt, i, b.to_s, -1, -1)
      end
      i += 1
    }

    ncols = SQL.sqlite3_column_count(stmt)
    rows = []
    while SQL.sqlite3_step(stmt) == SQL::ROW
      row = {}
      c = 0
      while c < ncols
        cname = SQL.sqlite3_column_name(stmt, c)
        ctype = SQL.sqlite3_column_type(stmt, c)
        if ctype == SQL::NULL_TYPE
          row[cname] = nil
        elsif ctype == SQL::INTEGER
          row[cname] = SQL.sqlite3_column_int64(stmt, c)
        elsif ctype == SQL::FLOAT
          row[cname] = SQL.sqlite3_column_double(stmt, c)
        else
          txt = SQL.sqlite3_column_text(stmt, c)
          row[cname] = (txt == nil) ? "" : (txt + "")  # copy out of the stmt buffer
        end
        c += 1
      end
      rows << row
    end
    SQL.sqlite3_finalize(stmt)
    rows
  end

  def last_insert_rowid
    SQL.sqlite3_last_insert_rowid(@conn.ptr)
  end

  def changes
    SQL.sqlite3_changes(@conn.ptr)
  end
end
