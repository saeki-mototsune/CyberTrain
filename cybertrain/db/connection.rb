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
        #
        # The open above succeeded, so a PRAGMA that raises (SQLITE_BUSY or
        # IOERR on the WAL switch, a file that is not a database) must close
        # the handle before the error leaves: the caller never receives the
        # object, so nobody else can. A Pool slot in quarantine reopens on
        # every checkout (Pool#reopen), and a handle leaked per request is a
        # file descriptor and a WAL/shm lock per request until EMFILE. A
        # rescue, not an ensure, as everywhere in this file (NOTES rules 33,
        # 50); `close` is the same path a user close takes.
        begin
          exec_script("PRAGMA busy_timeout=5000")
          exec_script("PRAGMA journal_mode=WAL") unless path == ":memory:"
          exec_script("PRAGMA foreign_keys=ON")
        rescue JSON::ParserError, StandardError => e
          close
          raise e
        end
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
      # the outer transaction. Do not break or return out of a transaction
      # block. Under CRuby that leaves BEGIN open with the depth at 1; the
      # autocommit probe below cannot see it (autocommit is 0, as in a live
      # transaction), so a later `transaction` on the same checkout would
      # nest into it and never COMMIT. Nothing in this method can observe
      # that: an `ensure` is the only construct that could, and an ensure in
      # this re-entrant yielding method miscompiles under Spinel (NOTES rule
      # 50; rule 45 for the earlier ensure-based body). The Pool rolls the
      # open transaction back on check-in (abandon_transaction!, with a warn
      # line), so the hole is bounded to the rest of that one checkout under
      # CRuby, and it does not exist under Spinel: a `break` there is
      # refused at compile time and a `return` just ends the block (rule 44).
      # A BEGIN run by hand is caught by the Pool the same way.
      # Returns nil: the blocks callers pass return unrelated types, and one
      # generic return value would not type-check under Spinel.
      def transaction
        raise Error, "connection closed (transaction)" if @closed

        # A depth above 0 while SQLite is in autocommit means the enclosing
        # transaction is gone: SQLite rolled it back on its own after
        # SQLITE_FULL / IOERR / BUSY and the app's block rescued that and went
        # on. Nesting into it would run this block without a transaction
        # and never COMMIT; starting a fresh one here would commit this part
        # while the outer COMMIT then fails as if everything rolled back.
        # Raising is the only honest answer; Pool#check_in resets the depth
        # when the connection comes back.
        if @transaction_depth > 0 && SQLite3.sqlite3_get_autocommit(@db) != 0
          raise Error, "transaction: the enclosing transaction is no longer open (SQLite rolled it back " \
                       "after an error); nothing nested in it can be committed"
        end
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
          abandon_transaction!
          raise e
        end
        @transaction_depth = 0
        begin
          exec_script("COMMIT")
        rescue Error => e
          abandon_transaction!
          raise e
        end
        nil
      end

      # Rolls back whatever was left open and resets the depth; never raises,
      # so the rescue paths of `transaction` can call it without masking the
      # exception they propagate. Pool#with runs it when a connection comes
      # back: a `transaction` block that got
      # out past the rescue (a `break`, under CRuby) leaves BEGIN open with
      # the depth at 1, so every later transaction on this pooled connection
      # would count as nested and nothing would ever be committed; a BEGIN
      # run by hand leaves autocommit off. Returns what happened, so the
      # caller's log line is never a false alarm:
      #   :clean       -- nothing was open (a depth left above 0 with
      #                   autocommit already back on -- SQLite rolled back on
      #                   its own after SQLITE_FULL / IOERR / BUSY, or a
      #                   ROLLBACK run by hand -- only resets the depth);
      #   :rolled_back -- a ROLLBACK was issued and autocommit is back on;
      #   :failed      -- the ROLLBACK did not bring autocommit back (BUSY,
      #                   IOERR): the connection is still inside the
      #                   transaction, and the Pool closes and replaces it
      #                   rather than hand it out again.
      def abandon_transaction!
        # The depth goes first: a connection closed inside its own
        # transaction block must not keep a stale depth for whoever still
        # holds it.
        @transaction_depth = 0
        return :clean if @closed
        return :clean if SQLite3.sqlite3_get_autocommit(@db) != 0

        SQLite3.sqlite3_exec(@db, "ROLLBACK", nil, nil, nil)
        SQLite3.sqlite3_get_autocommit(@db) != 0 ? :rolled_back : :failed
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
