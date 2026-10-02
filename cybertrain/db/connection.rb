require "json"
require "cybertrain/db/error"
require "cybertrain/db/sqlite_ffi"

module Cybertrain
  module DB
    # One SQLite database handle. Not thread-safe on its own: threads share
    # connections through Cybertrain::DB::Pool, which hands each one to a
    # single thread at a time.
    class Connection
      attr_reader :path

      # path is a file name, ":memory:" or a "file:" URI (OPEN_URI makes
      # SQLite read the URI form whether or not the library was compiled
      # with SQLITE_USE_URI). With create: false a missing file is refused
      # by SQLite itself (SQLITE_CANTOPEN -> DB::Error) instead of created.
      def initialize(path, create: true)
        @path = path
        @closed = false
        @transaction_depth = 0
        flags = SQLite3::OPEN_READWRITE | SQLite3::OPEN_URI
        flags |= SQLite3::OPEN_CREATE if create
        scratch = SQLite3.malloc(8)
        rc = SQLite3.sqlite3_open_v2(path, scratch, flags, nil)
        @db = SQLite3.read_ptr(scratch)
        SQLite3.free(scratch)
        if rc != SQLite3::OK
          # SQLite hands back a handle even when the open fails; it must still
          # be closed. Read the message first: close frees it.
          message = "cannot open database #{path}: #{SQLite3.sqlite3_errmsg(@db)} (rc #{rc})"
          SQLite3.sqlite3_close(@db)
          @closed = true
          raise Error, message
        end

        # busy_timeout first: switching to WAL takes a lock that another
        # connection opening the same file may hold, and without a timeout
        # that PRAGMA fails immediately with SQLITE_BUSY.
        exec_script("PRAGMA busy_timeout=5000")
        exec_script("PRAGMA journal_mode=WAL") unless path == ":memory:"
        exec_script("PRAGMA foreign_keys=ON")
      end

      # Runs one statement with positional `?` binds and returns its rows as
      # Hashes keyed by column name (an empty Array for DDL/DML).
      def execute(sql, binds = [])
        raise Error, "connection closed (sql: #{sql})" if @closed
        scratch = SQLite3.malloc(8)
        rc = SQLite3.sqlite3_prepare_v2(@db, sql, -1, scratch, nil)
        stmt = SQLite3.read_ptr(scratch)
        SQLite3.free(scratch)
        raise Error, error_message(sql) if rc != SQLite3::OK

        rows = []
        begin
          index = 1
          binds.each do |value|
            rc = bind(stmt, index, value)
            raise Error, error_message(sql) if rc != SQLite3::OK
            index += 1
          end

          columns = SQLite3.sqlite3_column_count(stmt)
          rc = SQLite3.sqlite3_step(stmt)
          while rc == SQLite3::ROW
            rows << read_row(stmt, columns)
            rc = SQLite3.sqlite3_step(stmt)
          end
          raise Error, error_message(sql) if rc != SQLite3::DONE
        ensure
          SQLite3.sqlite3_finalize(stmt)
        end
        rows
      end

      # Runs a semicolon-separated script (schema DDL, PRAGMAs); no binds, no rows.
      def exec_script(sql)
        raise Error, "connection closed (sql: #{sql})" if @closed
        rc = SQLite3.sqlite3_exec(@db, sql, nil, nil, nil)
        raise Error, error_message(sql) if rc != SQLite3::OK
        nil
      end

      def changes
        raise Error, "connection closed (changes)" if @closed
        SQLite3.sqlite3_changes(@db)
      end

      def last_insert_id
        raise Error, "connection closed (last_insert_id)" if @closed
        SQLite3.sqlite3_last_insert_rowid(@db)
      end

      # BEGIN / COMMIT around the block, ROLLBACK and re-raise when it raises
      # (JSON::ParserError named too: not a StandardError under Spinel, NOTES
      # rule 33). A failed COMMIT (deferred foreign key, SQLITE_BUSY) leaves
      # SQLite inside the transaction, so it is rolled back too before the
      # COMMIT error is re-raised. A nested call just runs its block inside
      # the outer transaction. A block that leaves by `break` is not seen
      # here (no `ensure`: a second ensure in this re-entrant yielding method
      # broke nested transactions under Spinel, CI on PR #10); the Pool
      # calls abandon_transaction! on every check-in, so the open BEGIN and
      # the stale depth never reach the next checkout.
      # Returns nil: the blocks callers pass return unrelated types, and one
      # generic return value would not type-check under Spinel.
      def transaction
        if @transaction_depth > 0
          @transaction_depth += 1
          begin
            yield
          ensure
            @transaction_depth -= 1
          end
          return nil
        end

        exec_script("BEGIN")
        @transaction_depth = 1
        begin
          yield
        rescue JSON::ParserError, StandardError => e
          @transaction_depth = 0
          rollback_quietly
          raise e
        end
        @transaction_depth = 0
        begin
          exec_script("COMMIT")
        rescue Error => e
          rollback_quietly
          raise e
        end
        nil
      end

      # Rolls back whatever a `transaction` block left open and resets the
      # depth. Pool#with runs it when a connection comes back: a block that
      # left `transaction` by `break` (or anything its rescue cannot see)
      # otherwise leaves BEGIN open with the depth at 1, so every later
      # transaction on this pooled connection would count as nested and
      # nothing would ever be committed. A clean connection is untouched.
      def abandon_transaction!
        return nil if @closed
        return nil if @transaction_depth == 0 && SQLite3.sqlite3_get_autocommit(@db) != 0

        @transaction_depth = 0
        rollback_quietly
        nil
      end

      def close
        return nil if @closed
        SQLite3.sqlite3_close(@db)
        @closed = true
        nil
      end

      def closed?
        @closed
      end

      private

      # ROLLBACK that never raises, so it cannot mask the exception being
      # propagated. Skipped when SQLite has already rolled back on its own
      # (SQLITE_FULL, IOERR, NOMEM, some BUSY cases): autocommit is back on.
      def rollback_quietly
        return if @closed
        return if SQLite3.sqlite3_get_autocommit(@db) != 0
        SQLite3.sqlite3_exec(@db, "ROLLBACK", nil, nil, nil)
        nil
      end

      def bind(stmt, index, value)
        case value
        when nil then SQLite3.sqlite3_bind_null(stmt, index)
        when true then SQLite3.sqlite3_bind_int64(stmt, index, 1)
        when false then SQLite3.sqlite3_bind_int64(stmt, index, 0)
        when Integer then SQLite3.sqlite3_bind_int64(stmt, index, value)
        when Float then SQLite3.sqlite3_bind_double(stmt, index, value)
        when Time then SQLite3.sqlite3_bind_text(stmt, index, value.getutc.strftime("%Y-%m-%dT%H:%M:%SZ"), -1, -1)
        else SQLite3.sqlite3_bind_text(stmt, index, value.to_s, -1, -1)
        end
      end

      def read_row(stmt, columns)
        row = {}
        column = 0
        while column < columns
          name = SQLite3.sqlite3_column_name(stmt, column) + ""
          case SQLite3.sqlite3_column_type(stmt, column)
          when SQLite3::NULL_TYPE then row[name] = nil
          when SQLite3::INTEGER then row[name] = SQLite3.sqlite3_column_int64(stmt, column)
          when SQLite3::FLOAT then row[name] = SQLite3.sqlite3_column_double(stmt, column)
          else
            text = SQLite3.sqlite3_column_text(stmt, column)
            # Copy out of SQLite's buffer, which the next step/finalize reuses.
            row[name] = text.nil? ? "" : text + ""
          end
          column += 1
        end
        row
      end

      def error_message(sql)
        "#{SQLite3.sqlite3_errmsg(@db)} (sql: #{sql})"
      end
    end
  end
end
