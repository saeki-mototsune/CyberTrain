require "cybertrain/cast"
require "cybertrain/db/error"
require "cybertrain/db/sqlite_ddl"

module Cybertrain
  module DB
    # Cybertrain::DB::Adapter (SQLite) -- which adapter the program was built
    # with, and what DB.connect is given. The adapter is chosen by the entry
    # a program requires (cybertrain/db/sqlite here, cybertrain/db/mysql
    # there); nothing branches on it at run time.
    module Adapter
      # "sqlite"; MySQL: "mysql". Not `name`: a singleton `name` beside
      # Module#name breaks `x.class.name` on boxed receivers in a
      # whole-framework program (spikes/NOTES.md rule 66, second paragraph).
      # @return [String]
      def self.adapter_name
        "sqlite"
      end

      # What DB.connect opens for `config`: the database file.
      # MySQL: config.database_url.
      # @param config [Cybertrain::Config]
      # @return [String]
      def self.connect_target(config)
        config.database_path
      end
    end

    # Cybertrain::DB::Dialect (SQLite) -- the SQL that differs between
    # adapters, so that the framework's files send none of their own. Every
    # method answers one type, the same on every adapter. The methods named
    # `<service>_<operation>` hold one service's statement that the general
    # operations cannot express (docs/superpowers/plans/2026-11-27-mysql-
    # adapter.md, Task 2, lists them). Each method's MySQL form is written
    # beside it, for the MySQL Dialect to implement.
    #
    # A `conn` is a Cybertrain::DB::Connection, typed (Connection.new's) or
    # the boxed one a DB.with block receives: only its plain methods are
    # called (spikes/NOTES.md rule 67).
    module Dialect
      # "posts" -> "`posts`" (an embedded backtick is doubled). SQLite
      # accepts MySQL's quote, so the form is the same on both.
      # @param name [String]
      # @return [String]
      def self.quote_ident(name)
        return "`#{name}`" unless name.include?("`")

        "`" + name.gsub("`", "``") + "`"
      end

      # The tail of an INSERT that updates `update_cols` from the inserted
      # row when it collides on `conflict_cols` (each name as SQL text,
      # already quoted where it needs to be); DO NOTHING when `update_cols`
      # is empty.
      # MySQL: " ON DUPLICATE KEY UPDATE c = VALUES(c), ..." (no conflict
      # target; with no column, " ON DUPLICATE KEY UPDATE <first conflict
      # col> = <first conflict col>").
      # @param conflict_cols [Array<String>]
      # @param update_cols [Array<String>]
      # @return [String]
      def self.upsert_tail(conflict_cols, update_cols)
        sets = Array.new(0) { "" }
        update_cols.each { |col| sets << "#{col} = excluded.#{col}" }
        Dialect.bulk_writes_upsert_tail(conflict_cols, sets)
      end

      # Whether an INSERT can end in RETURNING (Model.insert_all's
      # `returning:`). MySQL: false.
      # @return [Boolean]
      def self.returning?
        true
      end

      # The tables of the connected database, by name: the application's and
      # the framework's, not SQLite's own (sqlite_sequence, sqlite_stat1, ...).
      # MySQL: SELECT table_name AS name FROM information_schema.tables
      # WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' ORDER BY
      # table_name.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Array<String>]
      def self.table_names(conn)
        rows = conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        names = Array.new(0) { "" }
        rows.each do |r|
          name = r["name"].to_s
          names << name unless name.start_with?("sqlite_")
        end
        names
      end

      # Whether the table exists (read without creating anything).
      # MySQL: SELECT 1 FROM information_schema.tables WHERE table_schema =
      # DATABASE() AND table_name = ?.
      # @param conn [Cybertrain::DB::Connection]
      # @param name [String]
      # @return [Boolean]
      def self.table_exists?(conn, name)
        rows = conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", [name])
        !rows.empty?
      end

      # The table's column names in declaration order ([] for no table).
      # MySQL: SELECT column_name AS name FROM information_schema.columns
      # WHERE table_schema = DATABASE() AND table_name = ? ORDER BY
      # ordinal_position.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<String>]
      def self.column_names(conn, table)
        quoted = "'" + table.gsub("'", "''") + "'"
        rows = conn.execute("PRAGMA table_info(#{quoted})")
        names = Array.new(0) { "" }
        rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
        names
      end

      # A cheap SELECT that answers one row only while the database is
      # there: it reads the schema page (page 1), where a bare `SELECT 1`
      # never touches the file and would answer for a database that is
      # gone. sqlite_master rather than its newer alias sqlite_schema
      # (SQLite 3.33+). MySQL: "SELECT 1 AS n".
      # @return [String]
      def self.health_query
        "SELECT count(*) AS n FROM sqlite_master"
      end

      # Foreign key enforcement off for this connection. A no-op inside a
      # transaction on SQLite, so it is issued before BEGIN.
      # MySQL: SET FOREIGN_KEY_CHECKS = 0.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.foreign_keys_off(conn)
        conn.execute("PRAGMA foreign_keys = OFF")
        nil
      end

      # Foreign key enforcement on again. MySQL: SET FOREIGN_KEY_CHECKS = 1.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.foreign_keys_on(conn)
        conn.execute("PRAGMA foreign_keys = ON")
        nil
      end

      # Ids start again at 1 in `tables` (rows already deleted): SQLite
      # empties sqlite_sequence, which holds every AUTOINCREMENT table's
      # counter, when the database has one.
      # MySQL: ALTER TABLE `t` AUTO_INCREMENT = 1 for each of `tables`.
      # @param conn [Cybertrain::DB::Connection]
      # @param tables [Array<String>]
      # @return [nil]
      def self.reset_sequences(conn, tables)
        return nil unless Dialect.table_exists?(conn, "sqlite_sequence")

        conn.execute("DELETE FROM \"main\".sqlite_sequence")
        nil
      end

      # "" when no row names a missing parent, else the first such row as
      # "<table> row with id <id> has <column> <value>, which names no row
      # of <parent>" (always ending in the parent table's name).
      # MySQL: no foreign_key_check; for each foreign key in
      # information_schema.key_column_usage (referenced_table_name IS NOT
      # NULL), SELECT c.id, c.<col> FROM <table> c LEFT JOIN <parent> p ON
      # p.<ref> = c.<col> WHERE c.<col> IS NOT NULL AND p.<ref> IS NULL LIMIT 1.
      # @param conn [Cybertrain::DB::Connection]
      # @return [String]
      def self.foreign_key_violation(conn)
        rows = conn.execute("PRAGMA foreign_key_check")
        return "" if rows.empty?

        r = rows[0]
        table = r["table"].to_s
        parent = r["parent"].to_s
        rowid = Cybertrain::Cast.int(r["rowid"])
        fkid = Cybertrain::Cast.int(r["fkid"])
        column = ""
        conn.execute("PRAGMA foreign_key_list(\"#{table}\")").each { |f| column = f["from"].to_s if Cybertrain::Cast.int(f["id"]) == fkid }
        value = ""
        unless column.empty?
          found = conn.execute("SELECT \"#{column}\" AS v FROM \"#{table}\" WHERE rowid = ?", [rowid])
          value = Cybertrain::Cast.int(found[0]["v"]).to_s unless found.empty?
        end
        "#{table} row with id #{rowid} has #{column} #{value}, which names no row of #{parent}"
      end

      # Whether DDL rolls back with its transaction. MySQL: false (each DDL
      # statement commits).
      # @return [Boolean]
      def self.transactional_ddl?
        true
      end

      # The statements a migration operation that does not rebuild its
      # table runs (SqliteDDL.statements).
      # MySQL: Cybertrain::DB::MySQL::DDL.statements(op).
      # @param op [Cybertrain::Migration::Operation]
      # @return [Array<String>]
      def self.ddl_statements(op)
        Cybertrain::DB::SqliteDDL.statements(op)
      end

      # The CREATE TABLE of the Migrator's schema_migrations, when there
      # is none. MySQL: a VARCHAR(255) key and the table options.
      # @return [String]
      def self.migrator_schema_migrations_sql
        "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)"
      end

      # The current time as Integer epoch microseconds (UTC), in SQL.
      # MySQL: CAST(UNIX_TIMESTAMP(NOW(6)) * 1000000 AS SIGNED).
      # @return [String]
      def self.now_epoch_usec_sql
        "CAST((julianday('now') - 2440587.5) * 86400000000.0 AS INTEGER)"
      end

      # --- Relation ---------------------------------------------------------

      # The Float sum of `arg` (`expr` or `DISTINCT expr`), 0.0 over no rows
      # or only NULLs: SQLite's TOTAL. MySQL: "COALESCE(SUM(arg), 0e0)".
      # @param arg [String]
      # @return [String]
      def self.relation_float_total(arg)
        "TOTAL(#{arg})"
      end

      # The alias a derived table (`FROM (SELECT ...)`) takes after its
      # parenthesis: none on SQLite. MySQL: " AS cybertrain_sub" (it
      # requires one).
      # @return [String]
      def self.relation_subquery_alias
        ""
      end

      # The ESCAPE clause of where_like's LIKE, the escape character a
      # backslash. MySQL: " ESCAPE '\\\\'" (a backslash is doubled in its
      # string literals).
      # @return [String]
      def self.relation_like_escape
        " ESCAPE '\\'"
      end

      # The LIMIT that means none, for an OFFSET (which SQLite accepts only
      # after a LIMIT). MySQL: "18446744073709551615".
      # @return [String]
      def self.relation_no_limit
        "-1"
      end

      # What `id IN (...)` holds to name the ids of the windowed SELECT
      # `window` (update_all / delete_all with a limit or offset): the
      # SELECT itself. MySQL: "SELECT <id> FROM (<window>) AS
      # cybertrain_sub" (it refuses a LIMIT in an IN subquery, and a
      # subquery on the table the statement changes, unless derived).
      # @param id [String]
      # @param window [String]
      # @return [String]
      def self.relation_window_ids(id, window)
        window
      end

      # --- Model bulk writes --------------------------------------------------

      # The tail of Model.upsert / upsert_all: on a collision on
      # `conflict_cols`, `assignments` ("`c` = <expr>" each), DO NOTHING
      # when there is none.
      # MySQL: " ON DUPLICATE KEY UPDATE <assignments>" (excluded.c reads
      # VALUES(c)); with none, " ON DUPLICATE KEY UPDATE <first conflict col>
      # = <first conflict col>".
      # @param conflict_cols [Array<String>]
      # @param assignments [Array<String>]
      # @return [String]
      def self.bulk_writes_upsert_tail(conflict_cols, assignments)
        target_list = conflict_cols.join(", ")
        sql = +" ON CONFLICT (" << target_list << ")"
        if assignments.empty?
          sql << " DO NOTHING"
        else
          set_list = assignments.join(", ")
          sql << " DO UPDATE SET " << set_list
        end
        sql
      end

      # The tail of Model.insert_all: a row that collides on any unique key
      # is skipped. MySQL: INSERT IGNORE has no tail; " ON DUPLICATE KEY
      # UPDATE `id` = `id`".
      # @return [String]
      def self.bulk_writes_ignore_tail
        " ON CONFLICT DO NOTHING"
      end

      # The RETURNING clause of insert_all's `returning:` (each column
      # quoted). MySQL has none (returning? is false): "".
      # @param columns [Array<String>]
      # @return [String]
      def self.bulk_writes_returning_tail(columns)
        list = columns.join(", ")
        " RETURNING " + list
      end

      # Before a bulk INSERT whose rows are read back by their ids (only
      # where returning? is false): nothing on SQLite, whose RETURNING
      # answers the rows. MySQL: SELECT LAST_INSERT_ID(0), so that
      # bulk_writes_first_insert_id answers 0 when the INSERT made no id.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.bulk_writes_mark_insert_id(conn)
        nil
      end

      # The id of the first row the last INSERT made, 0 when it made none
      # (only where returning? is false). SQLite: the last rowid less the
      # rows changed, plus one. MySQL: SELECT LAST_INSERT_ID().
      # @param conn [Cybertrain::DB::Connection]
      # @return [Integer]
      def self.bulk_writes_first_insert_id(conn)
        changed = conn.changes
        return 0 if changed <= 0

        conn.last_insert_id - changed + 1
      end

      # --- Cache --------------------------------------------------------------

      # An expires_at of 0 is stored as NULL (never expires).
      CACHE_WRITE_SQL = "INSERT INTO cybertrain_cache (key, value, expires_at, updated_at) " \
                        "VALUES (?, ?, NULLIF(?, 0), ?) " \
                        "ON CONFLICT(key) DO UPDATE SET value = excluded.value, " \
                        "expires_at = excluded.expires_at, updated_at = excluded.updated_at"

      # write(unless_exist: true): an existing row is replaced only once it
      # has expired (the DO UPDATE's WHERE is false for a live row, so no row
      # changes).
      CACHE_ADD_SQL = "#{CACHE_WRITE_SQL} WHERE cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ?"

      # ?1 key, ?2 by, ?3 expires_at (0: none given), ?4 now. A missing row
      # starts at `by`, an expired one too (and loses its old expiry); a live
      # one adds `by` to its value read as an Integer (text that is not a
      # number counts as 0). A given expiry replaces the row's.
      CACHE_INCREMENT_SQL = "INSERT INTO cybertrain_cache (key, value, expires_at, updated_at) " \
                            "VALUES (?1, ?2, NULLIF(?3, 0), ?4) " \
                            "ON CONFLICT(key) DO UPDATE SET " \
                            "value = CASE WHEN cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ?4 " \
                            "THEN ?2 ELSE CAST(cybertrain_cache.value AS INTEGER) + ?2 END, " \
                            "expires_at = CASE WHEN cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ?4 " \
                            "THEN NULLIF(?3, 0) " \
                            "WHEN cybertrain_cache.expires_at IS NULL AND ?3 > 0 THEN ?3 " \
                            "ELSE cybertrain_cache.expires_at END, " \
                            "updated_at = ?4 " \
                            "RETURNING CAST(value AS INTEGER) AS n"

      # Cache.write: the row for `key` (expires_at 0: none), or with
      # `unless_exist` only when there is none or it has expired. Whether a
      # row was written.
      # MySQL: INSERT ... ON DUPLICATE KEY UPDATE value = VALUES(value), ...
      # (unless_exist: each column IF(expires_at IS NOT NULL AND expires_at <
      # ?, VALUES(c), c), expires_at last); written when the affected-row
      # count is 1 or 2 (CLIENT_FOUND_ROWS off, so 0 for a live row).
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.cache_write(conn, key, value, expires_at, now, unless_exist)
        sql = unless_exist ? CACHE_ADD_SQL : CACHE_WRITE_SQL
        binds = Cybertrain::Cast.binds(key, value, expires_at, now)
        binds << now if unless_exist
        conn.execute(sql, binds)
        conn.changes > 0
      end

      # Cache.increment: the counter for `key` after adding `by` (a missing or
      # expired row starts at `by`; expires_at 0: keep the row's expiry, or
      # none). 0 when no row came back.
      # MySQL: INSERT ... ON DUPLICATE KEY UPDATE with the same CASEs on
      # VALUES(), then SELECT CAST(value AS SIGNED) AS n FROM cybertrain_cache
      # WHERE `key` = ? in the same transaction.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Integer]
      def self.cache_increment(conn, key, by, expires_at, now)
        rows = conn.execute(CACHE_INCREMENT_SQL, Cybertrain::Cast.binds(key, by, expires_at, now))
        return 0 if rows.empty?

        Cybertrain::Cast.int(rows[0]["n"])
      end

      # Cache.prune: deletes at most `limit` rows expired before `now`, and
      # answers how many.
      # MySQL: DELETE FROM cybertrain_cache WHERE expires_at IS NOT NULL AND
      # expires_at < ? LIMIT <limit>.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Integer]
      def self.cache_prune(conn, now, limit)
        sql = "DELETE FROM cybertrain_cache WHERE rowid IN (SELECT rowid FROM cybertrain_cache " \
              "WHERE expires_at IS NOT NULL AND expires_at < ? LIMIT #{limit})"
        conn.execute(sql, [now])
        conn.changes
      end

      # --- Lease --------------------------------------------------------------

      # One statement takes a free lease, renews our own, and takes over an
      # expired one; a lease another holder still has is left alone (the DO
      # UPDATE's WHERE is false, so no row changes).
      LEASE_ACQUIRE_SQL = "INSERT INTO cybertrain_leases (name, holder, expires_at) VALUES (?, ?, ?) " \
                          "ON CONFLICT(name) DO UPDATE SET holder = excluded.holder, expires_at = excluded.expires_at " \
                          "WHERE cybertrain_leases.holder = excluded.holder OR cybertrain_leases.expires_at < ?"

      # Lease.acquire: whether `holder` now has the lease `name` until
      # `expires_at`.
      # MySQL: INSERT ... ON DUPLICATE KEY UPDATE expires_at = IF(holder =
      # VALUES(holder) OR expires_at < ?, VALUES(expires_at), expires_at),
      # holder = IF(<same test on the old expires_at>, ...), then SELECT holder
      # FROM cybertrain_leases WHERE name = ? (a renewal of an unchanged row
      # affects 0 rows).
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.lease_acquire(conn, name, holder, expires_at, now)
        conn.execute(LEASE_ACQUIRE_SQL, Cybertrain::Cast.binds(name, holder, expires_at, now))
        conn.changes == 1
      end

      # --- Scheduler::Timetable -------------------------------------------------

      # Timetable.write's statement: binds name, last_run_at (0: stored as
      # NULL), next_run_at, now. A row is never moved backwards: an update
      # needs a later last run, or the same one and a next run no earlier.
      # MySQL: INSERT ... ON DUPLICATE KEY UPDATE with each column
      # IF(<the same test on VALUES()>, VALUES(c), c), updated_at last.
      # @return [String]
      def self.timetable_write_sql
        "INSERT INTO cybertrain_schedules (name, last_run_at, next_run_at, updated_at) " \
          "VALUES (?, NULLIF(?, 0), ?, ?) " \
          "ON CONFLICT(name) DO UPDATE SET last_run_at = excluded.last_run_at, " \
          "next_run_at = excluded.next_run_at, updated_at = excluded.updated_at " \
          "WHERE COALESCE(excluded.last_run_at, 0) > COALESCE(cybertrain_schedules.last_run_at, 0) " \
          "OR (COALESCE(excluded.last_run_at, 0) = COALESCE(cybertrain_schedules.last_run_at, 0) " \
          "AND excluded.next_run_at >= cybertrain_schedules.next_run_at)"
      end

      # Timetable.write_missing's statement (binds name, next_run_at, now):
      # a new task's row, left alone when one exists.
      # MySQL: INSERT IGNORE INTO cybertrain_schedules ... VALUES (?, NULL, ?, ?).
      # @return [String]
      def self.timetable_insert_missing_sql
        "INSERT INTO cybertrain_schedules (name, last_run_at, next_run_at, updated_at) " \
          "VALUES (?, NULL, ?, ?) ON CONFLICT(name) DO NOTHING"
      end

      # --- WebSocket::FeedTable -------------------------------------------------

      # FeedTable.upsert_feed's statement (binds name, process, connected,
      # started_at, last_activity_at (0: NULL), restarts, now).
      # MySQL: the same INSERT with " ON DUPLICATE KEY UPDATE process =
      # VALUES(process), ..." (upsert_tail).
      # @return [String]
      def self.feed_table_write_sql
        "INSERT INTO cybertrain_feeds " \
          "(name, process, connected, started_at, last_activity_at, restarts, updated_at) " \
          "VALUES (?, ?, ?, ?, NULLIF(?, 0), ?, ?) " \
          "ON CONFLICT(name) DO UPDATE SET process = excluded.process, " \
          "connected = excluded.connected, started_at = excluded.started_at, " \
          "last_activity_at = excluded.last_activity_at, restarts = excluded.restarts, " \
          "updated_at = excluded.updated_at"
      end

      # --- Test::Database --------------------------------------------------------

      # Deletes every row of `table` (the "main" database's, so a TEMP table
      # of the same name never takes it). MySQL: DELETE FROM `table`.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.test_database_clear_table(conn, table)
        conn.execute("DELETE FROM \"main\".\"#{table}\"")
        nil
      end

      # Marks the database as one `cybertrain test` created (`marker` into
      # the file header's application_id) and checkpoints, so the mark is in
      # the file itself and not only in its write-ahead log.
      # MySQL: nothing (the database name is the proof; nil).
      # @param conn [Cybertrain::DB::Connection]
      # @param marker [Integer]
      # @return [nil]
      def self.test_database_mark(conn, marker)
        conn.execute("PRAGMA application_id = #{marker}")
        conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        nil
      end

      # --- Schema reading (SchemaDumper, Migrator) --------------------------------

      # The table's columns, one row each in declaration order, with the
      # keys "name", "type" (as declared), "notnull" (0/1), "dflt_value"
      # (the default's SQL text or nil) and "pk" (0, or the column's place in
      # the primary key). MySQL: information_schema.columns, with the type
      # and the default as SQLite's would read (MySQL::SchemaReader).
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<Hash{String => Object}>]
      def self.schema_columns(conn, table)
        conn.execute("PRAGMA table_info(#{table})")
      end

      # The table's indexes, one row each with "name" and "unique" (0/1),
      # SQLite's own automatic ones (sqlite_autoindex_*) included.
      # MySQL: SELECT DISTINCT index_name AS name, NOT non_unique AS `unique`
      # FROM information_schema.statistics WHERE ... AND index_name <> 'PRIMARY'.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<Hash{String => Object}>]
      def self.schema_index_rows(conn, table)
        conn.execute("PRAGMA index_list(#{table})")
      end

      # The CREATE INDEX text of `table`'s index `index`, "" when there is
      # none (an automatic index). SQLite's index names are unique in the
      # schema, so `table` is not read. MySQL (names unique per table only):
      # one written from information_schema.statistics for an index with an
      # expression, else "".
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @param index [String]
      # @return [String]
      def self.schema_index_sql(conn, table, index)
        rows = conn.execute("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [index])
        return "" if rows.empty?

        Cybertrain::Cast.str_or_nil(rows[0]["sql"]).to_s
      end

      # The column names of `table`'s index `index`, in key order (`table`
      # not read on SQLite, whose index names are unique in the schema).
      # MySQL: SELECT column_name FROM information_schema.statistics WHERE
      # table_schema = DATABASE() AND table_name = ? AND index_name = ?
      # ORDER BY seq_in_index.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @param index [String]
      # @return [Array<String>]
      def self.schema_index_columns(conn, table, index)
        rows = conn.execute("PRAGMA index_info(#{index})")
        ordered = rows.sort_by { |r| Cybertrain::Cast.int(r["seqno"]) }
        ordered.map { |r| r["name"].to_s }
      end

      # The table's foreign keys, one row each with "table" (the parent),
      # "from" (the column) and "on_delete" ("CASCADE", "SET NULL",
      # "RESTRICT", "NO ACTION", ...).
      # MySQL: information_schema.key_column_usage joined with
      # referential_constraints as referenced_table_name AS `table`,
      # column_name AS `from`, delete_rule AS on_delete.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<Hash{String => Object}>]
      def self.schema_foreign_key_rows(conn, table)
        conn.execute("PRAGMA foreign_key_list(#{table})")
      end

      # --- Migrator ----------------------------------------------------------------

      # Whether foreign keys are enforced on this connection now.
      # MySQL: SELECT @@foreign_key_checks AS n.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.migrator_foreign_keys_enforced?(conn)
        rows = conn.execute("PRAGMA foreign_keys")
        !rows.empty? && Cybertrain::Cast.int(rows[0]["foreign_keys"]) != 0
      end

      # Every row that names a missing parent, as "<table> row <rowid> ->
      # <parent>" joined with ", "; "" when there is none. What the migrator
      # checks before committing a version that rebuilt a table.
      # MySQL: the foreign_key_violation query for every foreign key, each
      # hit as "<table> row <id> -> <parent>".
      # @param conn [Cybertrain::DB::Connection]
      # @return [String]
      def self.migrator_foreign_key_check(conn)
        rows = conn.execute("PRAGMA foreign_key_check")
        return "" if rows.empty?

        found = Array.new(0) { "" }
        rows.each { |r| found << "#{r["table"]} row #{r["rowid"]} -> #{r["parent"]}" }
        found.join(", ")
      end

      # Runs one operation that rebuilds its table (op.rebuilds?) by
      # SQLite's procedure: `definition` is the live schema dumped just now
      # (after the version's earlier operations); the operation is applied
      # to it in memory and the table rebuilt from the result, with its
      # triggers and its sqlite_sequence value as they were. A
      # change_column_null to NOT NULL with a default first backfills the
      # NULL cells. Foreign key enforcement is already off (the migrator's
      # apply_version).
      # MySQL: the operation's one ALTER TABLE (MySQL::DDL.rebuild_sql),
      # no rebuild; the Migrator runs the backfill before it.
      # @param conn [Cybertrain::DB::Connection]
      # @param op [Cybertrain::Migration::Operation]
      # @param definition [Cybertrain::Schema::Definition]
      # @return [nil]
      def self.migrator_rebuild(conn, op, definition)
        table_name = op.table_text
        table = definition.table(table_name)
        if table.nil?
          message = "cannot #{op.kind} on #{table_name}: no such table"
          raise Cybertrain::DB::Error, message
        end
        refused = Cybertrain::DB::SqliteDDL.rebuild_refusal(Dialect.rebuild_table_sql(conn, table_name))
        if refused != ""
          message = "rebuilding #{table_name} would drop #{refused}: rewrite the migration with execute"
          raise Cybertrain::DB::Error, message
        end
        definition.replace_table(Cybertrain::DB::SqliteDDL.table_after(table, op))
        triggers = Dialect.rebuild_table_triggers(conn, table_name)
        sequence = Dialect.rebuild_table_sequence(conn, table_name)
        conn.execute(op.exec_sql, op.exec_binds) if op.kind == :change_column_null && !op.null && op.exec_sql != ""
        rename = Cybertrain::DB::SqliteDDL.rename_new_sql(table_name)
        Cybertrain::DB::SqliteDDL.rebuild_table(definition, table_name, triggers, sequence).each do |sql|
          if sql == rename
            Dialect.rebuild_legacy_rename(conn, sql)
          else
            conn.exec_script(sql)
          end
        end
        nil
      end

      # SQLite only, for migrator_rebuild (no MySQL form): the rebuild's
      # RENAME with legacy_alter_table on, so the views and
      # the other tables' triggers that name the table are not checked
      # while it does not exist (they would refuse the RENAME). The pragma
      # is not transactional, so it is turned off again whatever happens.
      # Never used for a plain rename_table, which needs it off for the
      # references to follow the new name.
      def self.rebuild_legacy_rename(conn, sql)
        conn.exec_script("PRAGMA legacy_alter_table = ON")
        begin
          conn.exec_script(sql)
        ensure
          conn.exec_script("PRAGMA legacy_alter_table = OFF")
        end
        nil
      end

      # SQLite only, for migrator_rebuild: the table's CREATE TABLE text.
      def self.rebuild_table_sql(conn, table_name)
        rows = conn.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table_name])
        return "" if rows.empty?

        Cybertrain::Cast.str_or_nil(rows[0]["sql"]).to_s
      end

      # SQLite only, for migrator_rebuild: the table's CREATE TRIGGER texts.
      def self.rebuild_table_triggers(conn, table_name)
        rows = conn.execute("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name", [table_name])
        result = Array.new(0) { "" }
        rows.each do |r|
          sql = Cybertrain::Cast.str_or_nil(r["sql"])
          result << sql.to_s unless sql.nil?
        end
        result
      end

      # SQLite only, for migrator_rebuild: the table's sqlite_sequence
      # value, -1 when it has none (or the
      # database has no AUTOINCREMENT table at all).
      def self.rebuild_table_sequence(conn, table_name)
        exists = conn.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'")
        return -1 if exists.empty?

        rows = conn.execute("SELECT seq FROM sqlite_sequence WHERE name = ?", [table_name])
        return -1 if rows.empty?

        Cybertrain::Cast.int(rows[0]["seq"])
      end
    end
  end
end
