require "json"
require "cybertrain/db/error"
require "cybertrain/db/sqlite_ffi"

module Cybertrain
  module DB
    # One SQLite database handle. Not thread-safe on its own: threads share
    # connections through Cybertrain::DB::Pool, which hands each one to a
    # single thread at a time.
    class Connection
      # Prepared statements a connection keeps (see #execute).
      MAX_CACHED_STATEMENTS = 64

      attr_reader :path

      # True for a path whose database lives only in its connection, so no
      # other connection can see it: ":memory:", "" (a private temporary
      # database) and, since Connection opens with OPEN_URI, a `file:` URI
      # naming ":memory:" or "mode=memory" -- unless it says "cache=shared".
      # A shared-cache in-memory database (`file:memdb?mode=memory&cache=
      # shared`) is one database that every connection to that name sees, kept
      # alive while any of them is open, so it is NOT private: a Pool may hold
      # its full size on it (a nested checkout then gets a second connection
      # instead of waiting on the first forever) and may reopen a slot, since
      # the other connections keep the database alive. String checks only: no
      # Regexp. The single predicate: Connection#initialize (no WAL for it)
      # and Pool (one never-reopened connection) both ask it, so a new
      # spelling is a change here only.
      def self.private_database?(path)
        return true if path == "" || path == ":memory:"
        return false unless path.start_with?("file:")
        return false if path.include?("cache=shared")
        path.include?(":memory:") || path.include?("mode=memory")
      end

      # path is a file name, ":memory:" or a "file:" URI (OPEN_URI makes
      # SQLite read the URI form whether or not the library was compiled
      # with SQLITE_USE_URI). With create: false a missing file is refused
      # by SQLite itself (SQLITE_CANTOPEN -> DB::Error) instead of created.
      def initialize(path, create: true)
        @path = path
        @closed = false
        @transaction_depth = 0
        # SQL text => its prepared statement, kept for the life of the
        # connection: an app runs the same few queries on every request, and
        # preparing one (parsing the SQL against the schema) cost more than
        # running it. A schema change re-prepares a cached statement inside
        # sqlite3_step (prepare_v2 semantics), so migrations need nothing.
        @statements = {}
        # Column names per SQL text, next to the prepared statement: a
        # typed Array found through a String => index Hash (a Hash of
        # objects would box its values, and Array#clear would box the
        # Array: see spikes/NOTES.md rule 56).
        @name_lists = Connection.no_name_lists
        @name_index = { "" => 0 }
        @name_index.delete("")
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

        # The busy handler first: switching to WAL takes a lock that another
        # connection opening the same file may hold, and without one that
        # PRAGMA fails immediately with SQLITE_BUSY.
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
          # Short retries instead of PRAGMA busy_timeout (see SQLite3).
          rc = SQLite3.cybertrain_sqlite_set_busy_handler(@db)
          raise Error, error_message("sqlite3_busy_handler") if rc != SQLite3::OK
          # WAL is meaningless for a database that lives only in this
          # connection; every spelling of that is private_database?, not just
          # ":memory:" (`file:x?mode=memory` and "" count too).
          # A shared-cache in-memory database is not private and still gets
          # the PRAGMA: SQLite answers "memory" for it and keeps that mode.
          exec_script("PRAGMA journal_mode=WAL") unless Connection.private_database?(path)
          exec_script("PRAGMA foreign_keys=ON")
        rescue JSON::ParserError, StandardError => e
          close
          raise e
        end
      end

      # Runs one statement with positional `?` binds and returns its rows as
      # Hashes keyed by column name (an empty Array for DDL/DML).
      def execute(sql, binds = [])
        run_statement(sql, binds, false)
      end

      # execute for the ORM: a DATETIME column comes back as UTC epoch seconds
      # (an Integer, which Cast.time_or_nil turns into a Time) instead of its
      # text, parsed in C without a Ruby String; a value that is not a
      # timestamp stays text. Relation reads its rows through this; execute
      # keeps returning the text SQLite stores.
      def execute_models(sql, binds = [])
        run_statement(sql, binds, true)
      end

      def run_statement(sql, binds, epoch)
        raise Error, "connection closed (sql: #{sql})" if @closed
        stmt = @statements[sql]
        cached = !stmt.nil?
        unless cached
          scratch = SQLite3.malloc(8)
          rc = SQLite3.sqlite3_prepare_v2(@db, sql, -1, scratch, nil)
          stmt = SQLite3.read_ptr(scratch)
          SQLite3.free(scratch)
          raise Error, error_message(sql) if rc != SQLite3::OK

          # Bounded: SQL built from request data (an IN list of varying
          # length) would otherwise grow the table without end; past the
          # bound a statement is used once and finalized, as before.
          if @statements.size < MAX_CACHED_STATEMENTS
            @statements[sql] = stmt
            cached = true
          end
        end

        rows = []
        begin
          index = 1
          while index <= binds.size
            rc = bind(stmt, index, binds[index - 1])
            raise Error, error_message(sql) if rc != SQLite3::OK
            index += 1
          end

          # Step first: a cached statement is re-prepared inside the step
          # after a schema change, and only then do its column count and
          # names (and any later row) describe the new table.
          rc = SQLite3.sqlite3_step(stmt)
          columns = SQLite3.sqlite3_column_count(stmt)
          # The names once per SQL text (and the count must still match),
          # not once per row and column.
          info = columns == 0 ? NO_COLUMNS : cached_columns(sql)
          if info.names.size != columns
            built = Array.new(0) { "" }
            datetimes = Array.new(0) { 0 }
            column = 0
            while column < columns
              built << SQLite3.sqlite3_column_name(stmt, column)
              datetimes << (Connection.datetime_decl?(SQLite3.sqlite3_column_decltype(stmt, column)) ? 1 : 0)
              column += 1
            end
            info = remember_columns(sql, built, datetimes)
          end
          names = info.names
          flags = info.datetimes
          while rc == SQLite3::ROW
            rows << read_row(stmt, names, flags, epoch)
            rc = SQLite3.sqlite3_step(stmt)
          end
          raise Error, error_message(sql) if rc != SQLite3::DONE
        ensure
          if cached
            # Back to the start, holding nothing: reset ends the statement
            # (releasing its read lock) and clear_bindings drops the bound
            # copies.
            SQLite3.sqlite3_reset(stmt)
            SQLite3.sqlite3_clear_bindings(stmt)
          else
            SQLite3.sqlite3_finalize(stmt)
          end
        end
        rows
      end

      # Runs a semicolon-separated script (schema DDL, PRAGMAs); no binds, no rows.
      def exec_script(sql)
        raise Error, "connection closed (sql: #{sql})" if @closed
        forget_names
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
      # 50; rule 45 for nested calls). The Pool rolls the
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
          # The outer branch's shape, not an ensure: this is a re-entrant
          # yielding method (NOTES rule 50). A raise from the nested block
          # restores the depth here and propagates; the outer `transaction`
          # then rolls everything back.
          @transaction_depth += 1
          begin
            yield
          rescue JSON::ParserError, StandardError => e
            @transaction_depth -= 1
            raise e
          end
          @transaction_depth -= 1
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
        # sqlite3_close refuses (SQLITE_BUSY) while a statement is unfinalized.
        @statements.each_value { |stmt| SQLite3.sqlite3_finalize(stmt) }
        @statements.clear
        forget_names
        SQLite3.sqlite3_close(@db)
        @closed = true
        nil
      end

      def closed?
        @closed
      end

      # Remembered column names for one SQL text, and which of the columns
      # are declared DATETIME (1) or not (0).
      class ColumnNames
        attr_reader :names, :datetimes

        def initialize(names, datetimes)
          @names = names
          @datetimes = datetimes
        end
      end

      # No columns, shared and never written to.
      NO_COLUMNS = ColumnNames.new(Array.new(0) { "" }, Array.new(0) { 0 })

      # An empty Array<ColumnNames>, typed by the block (never called).
      def self.no_name_lists
        Array.new(0) { ColumnNames.new(Array.new(0) { "" }, Array.new(0) { 0 }) }
      end

      # sqlite3_column_decltype is nil for an expression; a table column
      # answers the type its CREATE TABLE gave (DATETIME for t.datetime).
      def self.datetime_decl?(decl)
        return false if decl.nil?

        decl.upcase == "DATETIME"
      end

      private

      def cached_columns(sql)
        i = @name_index[sql]
        return NO_COLUMNS if i.nil?

        found = @name_lists[i]
        case found
        when ColumnNames then return found
        end
        NO_COLUMNS
      end

      # The ColumnNames is bound to a local before it is stored: an unnamed
      # temporary can be collected while the push that receives it still
      # grows the Array (the cause of a crash seen under load, see the
      # warning in FormBuilder.humanize).
      def remember_columns(sql, names, datetimes)
        entry = ColumnNames.new(names, datetimes)
        i = @name_index[sql]
        if i.nil?
          @name_index[sql] = @name_lists.size
          @name_lists << entry
        else
          @name_lists[i] = entry
        end
        entry
      end

      # A script (DDL) can rename columns under a cached statement. Added or
      # dropped columns change the count, which execute checks; a rename that
      # keeps the count, made through another connection, is the one change
      # this cannot see (the generated models name their columns anyway, so
      # such a server needs a restart regardless).
      def forget_names
        @name_lists = Connection.no_name_lists
        @name_index.clear
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

      # A :str FFI return is already a copy (Spinel builds it with
      # sp_str_dup_external), so neither the names nor the text values are
      # copied again: SQLite reusing its buffer on the next step cannot
      # reach them.
      def read_row(stmt, names, datetimes, epoch)
        row = {}
        columns = names.size
        column = 0
        while column < columns
          name = names[column]
          case SQLite3.sqlite3_column_type(stmt, column)
          when SQLite3::NULL_TYPE then row[name] = nil
          when SQLite3::INTEGER then row[name] = SQLite3.sqlite3_column_int64(stmt, column)
          when SQLite3::FLOAT then row[name] = SQLite3.sqlite3_column_double(stmt, column)
          else
            seconds = epoch && datetimes[column] == 1 ? SQLite3.cybertrain_sqlite_column_epoch(stmt, column) : -1
            if seconds >= 0
              row[name] = seconds
            else
              text = SQLite3.sqlite3_column_text(stmt, column)
              row[name] = text.nil? ? "" : text
            end
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
