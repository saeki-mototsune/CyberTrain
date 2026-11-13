require "json"
require "cybertrain/cast"
require "cybertrain/db/blob"
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

      # Waiting for another connection's lock in Ruby (#step_waiting,
      # #exec_waiting): the first pause, the longest one, and when to give
      # up (seconds). The pause starts at the 100 us the busy handler used,
      # so a lock held for microseconds still costs microseconds, and
      # doubles to 1 ms; the limit is the busy handler's five seconds.
      BUSY_FIRST_PAUSE = 0.0001
      BUSY_MAX_PAUSE = 0.001
      BUSY_WAIT_LIMIT = 5.0

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
        # SQLITE_LIMIT_VARIABLE_NUMBER, read on the first #variable_limit.
        @variable_limit = -1
        # Statements run so far (#statements_run).
        @statements_run = 0
        # True once SQLite rolled back a transaction on its own while a
        # statement failed, until the application ends it with COMMIT, END
        # or ROLLBACK (#note_lost_transaction, #refuse_if_transaction_gone).
        # Covers transactions opened with SQL too, which @transaction_depth
        # does not see.
        @transaction_lost = false
        # The busy handler's slot (SQLite3.cybertrain_sqlite_set_busy_handler):
        # its mode and whether SQLite asked to wait. Freed by #close, after
        # sqlite3_close, the last call that could reach the handler.
        @busy = SQLite3.malloc(8)
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
          SQLite3.free(@busy)
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
          # Lock waits through the busy handler's slot instead of PRAGMA
          # busy_timeout (see SQLite3): in Ruby for a statement, in C for a
          # script.
          rc = SQLite3.cybertrain_sqlite_set_busy_handler(@db, @busy)
          raise Error, error_message("sqlite3_busy_handler") if rc != SQLite3::OK
          # WAL is meaningless for a database that lives only in this
          # connection; every spelling of that is private_database?, not just
          # ":memory:" (`file:x?mode=memory` and "" count too).
          # A shared-cache in-memory database is not private and still gets
          # the PRAGMA: SQLite answers "memory" for it and keeps that mode.
          exec_script("PRAGMA journal_mode=WAL") unless Connection.private_database?(path)
          exec_script("PRAGMA foreign_keys=ON")
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          close
          raise e
        end
      end

      # Runs one statement with positional `?` binds and returns its rows as
      # Hashes keyed by column name (an empty Array for DDL/DML).
      def execute(sql, binds = [])
        run_statement(sql, binds, false)
      end

      # execute for the ORM: a DATETIME column comes back as a UTC Time (with
      # microseconds; Cast.time_or_nil takes it as is) instead of its text,
      # parsed in C without a Ruby String; a value that is not a
      # timestamp stays text. Relation reads its rows through this; execute
      # keeps returning the text SQLite stores.
      def execute_models(sql, binds = [])
        run_statement(sql, binds, true)
      end

      def run_statement(sql, binds, epoch)
        raise Error, "connection closed (sql: #{sql})" if @closed
        rows = []
        # A ROLLBACK of a transaction SQLite already rolled back: nothing
        # left to do (see #exec_script).
        return rows if refuse_if_transaction_gone(sql)

        @statements_run += 1
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

        begin
          index = 1
          while index <= binds.size
            rc = bind(stmt, index, binds[index - 1])
            raise Error, error_message(sql) if rc != SQLite3::OK
            index += 1
          end

          # Step first: a cached statement is re-prepared inside the step
          # after a schema change, and only then do its column count and
          # names (and any later row) describe the new table. Only this first
          # step waits for a lock: a statement takes its locks before it
          # changes or returns anything.
          in_transaction = SQLite3.sqlite3_get_autocommit(@db) == 0
          rc = step_waiting(stmt, in_transaction)
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
          if rc != SQLite3::DONE
            note_lost_transaction(in_transaction, sql)
            raise Error, error_message(sql)
          end
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
      # A lock is waited for inside the call, holding the OS worker: a script
      # that stopped at a lock half way could not be re-run from the top
      # (its first statements already ran). Scripts run at boot and in
      # migrations, not per request.
      def exec_script(sql)
        raise Error, "connection closed (sql: #{sql})" if @closed
        # A ROLLBACK of a transaction SQLite already rolled back has nothing
        # left to do: running it would raise "no transaction is active" and
        # mask the error the application is cleaning up after.
        return nil if refuse_if_transaction_gone(sql)

        forget_names
        SQLite3.cybertrain_sqlite_busy_report(@busy, 0)
        message = run_script(sql)
        SQLite3.cybertrain_sqlite_busy_report(@busy, 1)
        raise Error, message unless message.empty?

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

      # The most `?` binds one statement may carry
      # (SQLITE_LIMIT_VARIABLE_NUMBER: 32766 by default since SQLite 3.32,
      # 999 before, 250000 in the bundled build), asked of the library once
      # and then cached. Model.insert_all_into sizes its chunks by it.
      # @return [Integer]
      # @raise [Cybertrain::DB::Error] when the connection is closed
      # @api public
      def variable_limit
        raise Error, "connection closed (variable_limit)" if @closed
        @variable_limit = SQLite3.sqlite3_limit(@db, SQLite3::LIMIT_VARIABLE_NUMBER, -1) if @variable_limit < 0
        @variable_limit
      end

      # How many statements #execute and #execute_models have run on this
      # connection (exec_script's are not counted), for a test that asserts
      # how many queries something costs:
      #
      #     before = Cybertrain::DB.with { |c| c.statements_run }
      #     Article.includes(:comments).to_a.each { |a| a.comments.size }
      #     Cybertrain::DB.with { |c| c.statements_run } - before  # => 2
      # @return [Integer]
      # @api public
      def statements_run
        @statements_run
      end

      # Whether a transaction is open on this connection, however it was
      # opened ({#begin!}, a `transaction` block or a BEGIN run as SQL):
      # SQLite is out of autocommit mode.
      # @return [Boolean]
      # @raise [Cybertrain::DB::Error] when the connection is closed
      # @api public
      def in_transaction?
        raise Error, "connection closed (in_transaction?)" if @closed
        SQLite3.sqlite3_get_autocommit(@db) == 0
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
      #
      # The block-free begin!/commit!/rollback! below do the bookkeeping, so
      # this method, Cybertrain::DB.transaction and code that calls them by
      # hand share one depth count and one "SQLite rolled it back on its own"
      # check.
      def transaction
        begin!
        begin
          yield
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          rollback!
          raise e
        end
        commit!
        nil
      end

      # Opens a transaction, or one more nesting level of the open one, for
      # code that keeps its rescue in a plain method (Spinel cannot compile a
      # yielding method with a rescue everywhere: NOTES rules 32/45).
      # `immediate: true` issues BEGIN IMMEDIATE, which takes SQLite's write
      # lock now instead of at the first write: a read-then-write transaction
      # then waits for other writers at its start, where a deferred one would
      # fail with SQLITE_BUSY at its first write once another connection has
      # written in between. Only the outermost level opens anything, so
      # `immediate:` on a nested call changes nothing (SQLite cannot upgrade an
      # open transaction). Pair every begin! with exactly one commit! or
      # rollback!:
      #
      #   c.begin!(immediate: true)
      #   begin
      #     c.execute("UPDATE accounts SET balance = balance - ? WHERE id = ?", [n, from])
      #     c.execute("UPDATE accounts SET balance = balance + ? WHERE id = ?", [n, to])
      #   rescue JSON::NestingError, JSON::ParserError, StandardError => e
      #     c.rollback!
      #     raise e
      #   end
      #   c.commit!
      #
      # @param immediate [Boolean] BEGIN IMMEDIATE instead of BEGIN (outermost level only)
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the connection is closed, when the
      #   enclosing transaction is gone (SQLite rolled it back on its own after
      #   an error the application rescued), or when SQLite refuses the BEGIN
      #   (SQLITE_BUSY once the busy handler gives up, for BEGIN IMMEDIATE)
      # @api public
      def begin!(immediate: false)
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
          return nil
        end
        refuse_if_transaction_gone(immediate ? "BEGIN IMMEDIATE" : "BEGIN")

        exec_waiting(immediate ? "BEGIN IMMEDIATE" : "BEGIN")
        @transaction_depth = 1
        nil
      end

      # Ends one level opened by {#begin!}. A nested level only counts down;
      # the outermost one COMMITs. A failed COMMIT (deferred foreign key,
      # SQLITE_BUSY) leaves SQLite inside the transaction, so it is rolled
      # back before the COMMIT error is re-raised.
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the connection is closed, when no
      #   transaction is open, or when the COMMIT fails (everything is rolled
      #   back then)
      # @api public
      def commit!
        raise Error, "connection closed (commit!)" if @closed
        raise Error, "commit!: no transaction is open on this connection" if @transaction_depth == 0
        if @transaction_depth > 1
          @transaction_depth -= 1
          return nil
        end

        @transaction_depth = 0
        begin
          exec_waiting("COMMIT")
        rescue Error => e
          abandon_transaction!
          raise e
        end
        nil
      end

      # Ends one level opened by {#begin!} after an error. The outermost level
      # ROLLBACKs; a nested level only counts down and leaves the decision to
      # the outermost one, exactly as a raise out of a nested `transaction`
      # block does: re-raise after it, so the outer level rolls back too
      # (a nested rollback! followed by a normal end commits the nested
      # writes along with the outer ones: there are no savepoints). Never
      # raises, so a rescue clause can call it without masking the exception
      # it is about to re-raise; on a connection with nothing open it does
      # nothing.
      # @return [nil]
      # @api public
      def rollback!
        if @transaction_depth > 1
          @transaction_depth -= 1
          return nil
        end
        abandon_transaction!
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
        @transaction_lost = false
        return :clean if @closed
        return :clean if SQLite3.sqlite3_get_autocommit(@db) != 0

        SQLite3.cybertrain_sqlite_busy_report(@busy, 0)
        SQLite3.sqlite3_exec(@db, "ROLLBACK", nil, nil, nil)
        SQLite3.cybertrain_sqlite_busy_report(@busy, 1)
        SQLite3.sqlite3_get_autocommit(@db) != 0 ? :rolled_back : :failed
      end

      def close
        return nil if @closed
        # sqlite3_close refuses (SQLITE_BUSY) while a statement is unfinalized.
        @statements.each_value { |stmt| SQLite3.sqlite3_finalize(stmt) }
        @statements.clear
        forget_names
        SQLite3.sqlite3_close(@db)
        SQLite3.free(@busy)
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
      # answers the type its CREATE TABLE gave (DATETIME for t.datetime;
      # Rails writes datetime(6)): any type that starts with DATETIME.
      def self.datetime_decl?(decl)
        return false if decl.nil?

        decl.upcase.start_with?("DATETIME")
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
      # warning in I18n.humanize_attribute).
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
        when Time then SQLite3.sqlite3_bind_text(stmt, index, Cast.sql_datetime(value), -1, -1)
        when Date then SQLite3.sqlite3_bind_text(stmt, index, value.to_s, -1, -1)
        # Its byte length, not -1 (which makes SQLite stop at the first NUL,
        # as it does for bind_text): every byte is stored.
        when Blob
          bytes = value.blob_bytes
          SQLite3.sqlite3_bind_blob(stmt, index, bytes, bytes.bytesize, -1)
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
          # The exact bytes, NULs included (a :binstr copy; the :str text
          # path would stop at the first NUL). A String like a TEXT cell.
          when SQLite3::BLOB then row[name] = SQLite3.cybertrain_sqlite_column_blob(stmt, column)
          else
            # Epoch microseconds (sqlite_ffi.rb), -1 for text that is not a
            # datetime. A Time in the row: Cast.time_or_nil takes it as is.
            us = epoch && datetimes[column] == 1 ? SQLite3.cybertrain_sqlite_column_epoch(stmt, column) : -1
            if us >= 0
              row[name] = Time.at(us / 1_000_000, us % 1_000_000).utc
            else
              text = SQLite3.sqlite3_column_text(stmt, column)
              row[name] = text.nil? ? "" : text
            end
          end
          column += 1
        end
        row
      end

      # sqlite3_step, waiting in Ruby while another connection holds the
      # lock it needs: SQLITE_BUSY with the busy handler asked to wait
      # resets the statement (its binds stay) and steps again after a
      # green-thread `sleep`, which lets the lock holder run on this OS
      # worker (saeki-mototsune/CyberTrain#134). A BUSY the handler was not
      # asked about cannot clear by waiting and is returned at once, as is
      # the last one after BUSY_WAIT_LIMIT.
      #
      # in_transaction: whether SQLite was inside a transaction before this
      # statement, one opened by #begin! or by SQL (`exec_script("BEGIN")`,
      # which leaves @transaction_depth at 0). #run_statement reads it once
      # for this and for #note_lost_transaction.
      def step_waiting(stmt, in_transaction)
        rc = SQLite3.sqlite3_step(stmt)
        return rc if rc != SQLite3::BUSY

        deadline = Connection.monotonic + BUSY_WAIT_LIMIT
        pause = BUSY_FIRST_PAUSE
        while rc == SQLite3::BUSY && SQLite3.cybertrain_sqlite_busy_asked(@busy) == 1
          break if Connection.monotonic >= deadline
          # SQLite may roll an explicit transaction back on its own after
          # SQLITE_BUSY (as #begin! notes); the statement re-run then would
          # commit by itself, outside the transaction the caller opened.
          # Return the BUSY instead, so the transaction fails as a whole.
          break if in_transaction && SQLite3.sqlite3_get_autocommit(@db) != 0

          SQLite3.sqlite3_reset(stmt)
          sleep pause
          pause = pause * 2 < BUSY_MAX_PAUSE ? pause * 2 : BUSY_MAX_PAUSE
          rc = SQLite3.sqlite3_step(stmt)
        end
        rc
      end

      # One statement with no rows (BEGIN, BEGIN IMMEDIATE, COMMIT), waiting
      # for a lock as #step_waiting does. Re-running it after SQLITE_BUSY is
      # safe: a refused BEGIN IMMEDIATE began nothing, and a refused COMMIT
      # leaves the transaction open for the next try (SQLite's docs).
      def exec_waiting(sql)
        raise Error, "connection closed (sql: #{sql})" if @closed
        forget_names
        rc = SQLite3.sqlite3_exec(@db, sql, nil, nil, nil)
        if rc == SQLite3::BUSY
          deadline = Connection.monotonic + BUSY_WAIT_LIMIT
          pause = BUSY_FIRST_PAUSE
          while rc == SQLite3::BUSY && SQLite3.cybertrain_sqlite_busy_asked(@busy) == 1
            break if Connection.monotonic >= deadline

            sleep pause
            pause = pause * 2 < BUSY_MAX_PAUSE ? pause * 2 : BUSY_MAX_PAUSE
            rc = SQLite3.sqlite3_exec(@db, sql, nil, nil, nil)
          end
        end
        raise Error, error_message(sql) if rc != SQLite3::OK
        nil
      end

      def self.monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Raises instead of running sql when the application's transaction is
      # gone: SQLite rolled it back on its own (SQLITE_FULL / IOERR / BUSY /
      # NOMEM) and the application rescued that and went on. Run now, the
      # statement would commit by itself while the transaction's COMMIT then
      # fails, so the transaction would be neither all nor nothing
      # (saeki-mototsune/CyberTrain#158). Two signs, either is enough:
      #
      # * @transaction_lost: a statement that started inside a transaction
      #   failed and left SQLite in autocommit (#note_lost_transaction). This
      #   sees a transaction opened with SQL (`exec_script("BEGIN")`) too.
      #   COMMIT, END and ROLLBACK end the lost transaction and are let
      #   through; true is returned for a ROLLBACK, which has nothing left to
      #   do, so #exec_script skips it.
      # * a depth above 0 while SQLite is in autocommit: the transaction
      #   #begin! opened is gone, however it went.
      #
      # #abandon_transaction! (#commit!, #rollback!, Pool#check_in) clears
      # both, so the connection works again afterwards. Returns false when
      # sql may run.
      def refuse_if_transaction_gone(sql)
        if @transaction_lost
          if Connection.ends_transaction?(sql)
            @transaction_lost = false
            return Connection.rollback_statement?(sql)
          end
          raise Error, Connection.transaction_gone_message(sql)
        end
        return false if @transaction_depth == 0
        return false if SQLite3.sqlite3_get_autocommit(@db) == 0

        raise Error, Connection.transaction_gone_message(sql)
      end

      # After sql failed: a statement that started inside a transaction and
      # left SQLite in autocommit means SQLite rolled the transaction back
      # on its own (a constraint error undoes only its own statement and
      # leaves the transaction open). A failed COMMIT, END or ROLLBACK is
      # the application ending the transaction itself and marks nothing.
      def note_lost_transaction(in_transaction, sql)
        return nil unless in_transaction
        return nil if SQLite3.sqlite3_get_autocommit(@db) == 0
        return nil if Connection.ends_transaction?(sql)

        @transaction_lost = true
        nil
      end

      def self.transaction_gone_message(sql)
        "the enclosing transaction is no longer open (SQLite rolled it back after an error); " \
          "the statement was not run (sql: #{sql})"
      end

      # The statements around a transaction are recognised by a small lexer
      # that reads SQL the way SQLite tokenizes it: whitespace (line breaks
      # included), `-- ...` and `/* ... */` comments separate tokens and are
      # otherwise ignored, a ";" inside a comment or a quoted name does not
      # end a statement, and keywords are case-insensitive. Only the first
      # statement's leading keywords are read; nothing is parsed further.

      # Whether the first statement of sql is COMMIT, END or ROLLBACK, each
      # optionally followed by TRANSACTION and nothing else: the statements
      # that end a transaction. ROLLBACK [TRANSACTION] TO a savepoint undoes
      # part of one and does not, and anything more (`ROLLBACK BOGUS`,
      # `COMMIT 'x'`) is not a statement SQLite would run, so it must not
      # clear the lost-transaction mark either.
      def self.ends_transaction?(sql)
        words = Connection.statement_words(sql)
        Connection.bare_keyword?(words, "COMMIT") || Connection.bare_keyword?(words, "END") ||
          Connection.full_rollback?(words)
      end

      # A ROLLBACK and nothing else (comments, empty statements and a
      # trailing ";" allowed): the one statement #refuse_if_transaction_gone
      # skips after SQLite rolled the transaction back. A script that goes on
      # after its ROLLBACK (`ROLLBACK; BEGIN`) runs, so what follows is never
      # dropped silently.
      def self.rollback_statement?(sql)
        Connection.full_rollback?(Connection.statement_words(sql)) && !Connection.statement_follows?(sql)
      end

      # ROLLBACK or ROLLBACK TRANSACTION, nothing more (so not ROLLBACK TO);
      # words from #statement_words.
      def self.full_rollback?(words)
        Connection.bare_keyword?(words, "ROLLBACK")
      end

      # words is exactly [keyword] or [keyword, "TRANSACTION"].
      def self.bare_keyword?(words, keyword)
        return false if words.empty? || words[0] != keyword
        return true if words.size == 1

        words.size == 2 && words[1] == "TRANSACTION"
      end

      # Every word of the first statement, upcased, up to its ";" or the end
      # of sql. Empty when the statement holds anything but words (a quoted
      # name, a number, a symbol), which none of the statements classified
      # here do.
      def self.statement_words(sql)
        words = Array.new(0) { "" }
        n = sql.bytesize
        i = Connection.skip_blank(sql, 0)
        while i < n && sql.getbyte(i) != 59 # ;
          return Array.new(0) { "" } unless Connection.word_byte?(sql.getbyte(i))

          start = i
          i += 1 while i < n && Connection.word_byte?(sql.getbyte(i))
          words << sql.byteslice(start, i - start).to_s.upcase
          i = Connection.skip_blank(sql, i)
        end
        words
      end

      # Whether a statement follows the first one: anything but whitespace,
      # comments and empty statements after the first ";" that is outside a
      # comment or a quoted string or name.
      def self.statement_follows?(sql)
        n = sql.bytesize
        i = 0
        while i < n
          i = Connection.skip_blank(sql, i)
          break if i >= n

          c = sql.getbyte(i)
          if c == 59 # ;
            i = Connection.skip_blank(sql, i + 1)
            i = Connection.skip_blank(sql, i + 1) while i < n && sql.getbyte(i) == 59
            return i < n
          elsif c == 39 || c == 34 || c == 96 # ' " `
            i = Connection.skip_quoted(sql, i, c)
          elsif c == 91 # [
            i = Connection.skip_quoted(sql, i, 93)
          else
            i += 1
          end
        end
        false
      end

      # The index after whitespace and comments from i (sql.bytesize at the
      # end). An unterminated /* comment runs to the end, as in SQLite.
      def self.skip_blank(sql, i)
        n = sql.bytesize
        while i < n
          c = sql.getbyte(i)
          if c == 32 || (c >= 9 && c <= 13)
            i += 1
          elsif c == 45 && i + 1 < n && sql.getbyte(i + 1) == 45 # --
            i += 2
            i += 1 while i < n && sql.getbyte(i) != 10
          elsif c == 47 && i + 1 < n && sql.getbyte(i + 1) == 42 # /*
            i += 2
            i += 1 while i + 1 < n && !(sql.getbyte(i) == 42 && sql.getbyte(i + 1) == 47)
            i = i + 1 < n ? i + 2 : n
          else
            return i
          end
        end
        n
      end

      # The index after the quoted token that opens at i and closes with
      # close; a doubled close quote is part of the token.
      def self.skip_quoted(sql, i, close)
        n = sql.bytesize
        i += 1
        while i < n
          if sql.getbyte(i) == close
            return i + 1 unless i + 1 < n && sql.getbyte(i + 1) == close

            i += 2
          else
            i += 1
          end
        end
        n
      end

      def self.word_byte?(c)
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95
      end

      # Runs sql one statement at a time, as sqlite3_exec would but seeing
      # SQLite's transaction state before each statement: a statement that
      # started inside a transaction and failed with SQLite back in
      # autocommit marks the transaction lost (#note_lost_transaction),
      # however the script got into it (`CREATE ...; BEGIN; ...`,
      # saeki-mototsune/CyberTrain#164), and a BEGIN that fails opened
      # nothing. Stops at the first failing statement, as sqlite3_exec does,
      # and returns its message ("" when every statement ran), so that
      # #exec_script restores the busy handler's mode before raising.
      def run_script(sql)
        n = sql.bytesize
        offset = 0
        while offset < n
          in_transaction = SQLite3.sqlite3_get_autocommit(@db) == 0
          scratch = SQLite3.malloc(8)
          next_offset = prepare_next(sql, offset, scratch)
          stmt = SQLite3.read_ptr(scratch)
          SQLite3.free(scratch)
          return "" if next_offset == SQLite3::NO_STATEMENT
          if next_offset < 0
            # Preparing can fail with SQLite rolling the transaction back too
            # (IOERR or NOMEM while it reads the schema): the same check as
            # for a failed step, against what is left of the script.
            message = error_message(sql)
            note_lost_transaction(in_transaction, sql.byteslice(offset, n - offset).to_s)
            return message
          end

          statement = sql.byteslice(offset, next_offset - offset).to_s
          offset = next_offset
          rc = SQLite3.sqlite3_step(stmt)
          rc = SQLite3.sqlite3_step(stmt) while rc == SQLite3::ROW
          if rc != SQLite3::DONE
            message = error_message(sql)
            SQLite3.sqlite3_finalize(stmt)
            note_lost_transaction(in_transaction, statement)
            return message
          end
          SQLite3.sqlite3_finalize(stmt)
        end
        ""
      end

      # Prepares the statement of sql that starts at byte offset into
      # stmt_out (malloc(8)): the offset just past it, SQLite3::NO_STATEMENT
      # when only blanks and comments are left, or a negated SQLite error
      # code. A method of its own so that a test can stand in for it: no
      # real SQLite fails a prepare and rolls the transaction back on demand
      # (an IOERR or NOMEM while it reads the schema), and
      # test/db_raw_transaction_rollback.rb needs that to check #run_script's
      # guard on that path (saeki-mototsune/CyberTrain#167).
      def prepare_next(sql, offset, stmt_out)
        SQLite3.cybertrain_sqlite_prepare_at(@db, sql, offset, stmt_out)
      end

      def error_message(sql)
        "#{SQLite3.sqlite3_errmsg(@db)} (sql: #{sql})"
      end
    end
  end
end
