# The MySQL adapter's Cybertrain::DB::Adapter (which adapter the program
# was built with, and what DB.connect is given) and Cybertrain::DB::Dialect
# (the SQL that differs from SQLite's; cybertrain/db/sqlite/dialect.rb is
# the SQLite one, method for method, with the same signatures and return
# types).
require "cybertrain/cast"
require "cybertrain/db/error"

module Cybertrain
  module DB
    # Cybertrain::DB::Adapter (MySQL). Chosen by the entry a program
    # requires (cybertrain/db/mysql); nothing branches on it at run time.
    module Adapter
      # What an application on MySQL is told when DATABASE_URL is empty:
      # the boot stops (Application#acquire_boot_resources, through
      # connect_target) before anything connects.
      MISSING_URL = "DATABASE_URL is not set (mysql://user:password@host:3306/name)"

      # "mysql" (SQLite: "sqlite"). Not `name` (spikes/NOTES.md rule 66).
      # @return [String]
      def self.adapter_name
        "mysql"
      end

      # What DB.connect opens for `config`: the server's URL,
      # config.database_url (from DATABASE_URL). An empty one stops the
      # boot with MISSING_URL; the URL itself is never in a message (its
      # faults are named by Url, without the password).
      # @param config [Cybertrain::Config]
      # @return [String]
      # @raise [Cybertrain::DB::Error] when config.database_url is empty
      def self.connect_target(config)
        url = config.database_url
        raise Error, MISSING_URL if url.empty?

        url
      end
    end

    # Cybertrain::DB::Dialect (MySQL 8.0.19 or later: the upserts use the
    # row alias of INSERT ... AS excluded ON DUPLICATE KEY UPDATE). Each
    # method is the SQLite Dialect's, with its signature and return type;
    # what the SQLite one does in SQLite's SQL this one does in MySQL's.
    #
    # The row alias is named `excluded`, so that the `excluded.c`
    # expressions Model.upsert's `update:` documents (SQLite's name for the
    # row the INSERT tried to write) read the same row here. MySQL's VALUES(c)
    # is deprecated since 8.0.20 and never used.
    #
    # The session counts found rows (CLIENT_FOUND_ROWS, Connection#changes):
    # an ON DUPLICATE KEY UPDATE that matches a row and changes nothing
    # affects 1 row, as an insert does, so no method here reads "was a row
    # written" from the affected-row count of an upsert alone.
    #
    # A `conn` is a Cybertrain::DB::Connection (the MySQL one), typed or
    # the boxed one a DB.with block receives: only its plain methods are
    # called (spikes/NOTES.md rule 67).
    module Dialect
      # The row alias of every upsert (see the module comment).
      ROW_ALIAS = "excluded"

      # "posts" -> "`posts`" (an embedded backtick is doubled).
      # @param name [String]
      # @return [String]
      def self.quote_ident(name)
        return "`#{name}`" unless name.include?("`")

        "`" + name.gsub("`", "``") + "`"
      end

      # The tail of an INSERT that updates `update_cols` from the inserted
      # row when it collides on a unique key: " AS excluded ON DUPLICATE KEY
      # UPDATE c = excluded.c, ..."; with no column, the colliding row is
      # left as it is (bulk_writes_upsert_tail). MySQL has no conflict
      # target: a collision on any unique key of the table takes the update.
      # @param conflict_cols [Array<String>]
      # @param update_cols [Array<String>]
      # @return [String]
      def self.upsert_tail(conflict_cols, update_cols)
        sets = Array.new(0) { "" }
        update_cols.each { |col| sets << "#{col} = #{ROW_ALIAS}.#{col}" }
        Dialect.bulk_writes_upsert_tail(conflict_cols, sets)
      end

      # Whether an INSERT can end in RETURNING: not on MySQL. insert_all's
      # `returning:` reads the rows back in the same transaction
      # (Model.bulk_select_returned).
      # @return [Boolean]
      def self.returning?
        false
      end

      # The tables of the connected database, by name (the application's
      # and the framework's; MySQL keeps its own in other schemas).
      # @param conn [Cybertrain::DB::Connection]
      # @return [Array<String>]
      def self.table_names(conn)
        rows = conn.execute("SELECT table_name AS name FROM information_schema.tables " \
                            "WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' ORDER BY table_name")
        names = Array.new(0) { "" }
        rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
        names
      end

      # Whether the table exists (read without creating anything).
      # @param conn [Cybertrain::DB::Connection]
      # @param name [String]
      # @return [Boolean]
      def self.table_exists?(conn, name)
        rows = conn.execute("SELECT 1 AS n FROM information_schema.tables " \
                            "WHERE table_schema = DATABASE() AND table_name = ?", [name])
        !rows.empty?
      end

      # The table's column names in declaration order ([] for no table).
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<String>]
      def self.column_names(conn, table)
        rows = conn.execute("SELECT column_name AS name FROM information_schema.columns " \
                            "WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position", [table])
        names = Array.new(0) { "" }
        rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
        names
      end

      # A cheap SELECT that answers one row while the server is there.
      # @return [String]
      def self.health_query
        "SELECT 1 AS n"
      end

      # Foreign key checks off for this session.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.foreign_keys_off(conn)
        conn.execute("SET FOREIGN_KEY_CHECKS = 0")
        nil
      end

      # Foreign key checks on again.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.foreign_keys_on(conn)
        conn.execute("SET FOREIGN_KEY_CHECKS = 1")
        nil
      end

      # Ids start again at 1 in `tables` (rows already deleted): an ALTER
      # TABLE per table, which MySQL takes as the lowest value above the
      # table's largest id. DDL: it commits an open transaction.
      # @param conn [Cybertrain::DB::Connection]
      # @param tables [Array<String>]
      # @return [nil]
      def self.reset_sequences(conn, tables)
        tables.each do |table|
          quoted = Dialect.quote_ident(table)
          conn.exec_script("ALTER TABLE #{quoted} AUTO_INCREMENT = 1")
        end
        nil
      end

      # The foreign keys of the database (or of one table, when `table` is
      # not ""), one row each with "table", "column", "parent" and "ref",
      # in table and constraint order.
      def self.foreign_key_columns(conn, table)
        sql = +"SELECT table_name AS t, column_name AS c, referenced_table_name AS p, " \
               "referenced_column_name AS r FROM information_schema.key_column_usage " \
               "WHERE table_schema = DATABASE() AND referenced_table_name IS NOT NULL"
        binds = Cybertrain::Cast.empty_binds
        unless table.empty?
          sql << " AND table_name = ?"
          binds << table
        end
        sql << " ORDER BY table_name, constraint_name, ordinal_position"
        conn.execute(sql, binds)
      end

      # The first row of `table` whose `column` names no row of `parent`
      # (by `ref`): [id, value], or [] when every row has its parent.
      def self.orphan_rows(conn, table, column, parent, ref, limit)
        t = Dialect.quote_ident(table)
        c = Dialect.quote_ident(column)
        p = Dialect.quote_ident(parent)
        r = Dialect.quote_ident(ref)
        conn.execute("SELECT ch.`id` AS id, ch.#{c} AS v FROM #{t} ch LEFT JOIN #{p} pa ON pa.#{r} = ch.#{c} " \
                     "WHERE ch.#{c} IS NOT NULL AND pa.#{r} IS NULL ORDER BY ch.`id` LIMIT #{limit}")
      end

      # "" when no row names a missing parent, else the first such row as
      # "<table> row with id <id> has <column> <value>, which names no row
      # of <parent>" (the SQLite Dialect's text). MySQL has no
      # foreign_key_check: each foreign key is joined to its parent.
      # @param conn [Cybertrain::DB::Connection]
      # @return [String]
      def self.foreign_key_violation(conn)
        Dialect.foreign_key_columns(conn, "").each do |fk|
          table = Cybertrain::Cast.str(fk["t"])
          column = Cybertrain::Cast.str(fk["c"])
          parent = Cybertrain::Cast.str(fk["p"])
          found = Dialect.orphan_rows(conn, table, column, parent, Cybertrain::Cast.str(fk["r"]), 1)
          next if found.empty?

          id = Cybertrain::Cast.int(found[0]["id"])
          value = Cybertrain::Cast.str(found[0]["v"])
          return "#{table} row with id #{id} has #{column} #{value}, which names no row of #{parent}"
        end
        ""
      end

      # Whether DDL rolls back with its transaction: no, each DDL statement
      # commits the open transaction.
      # @return [Boolean]
      def self.transactional_ddl?
        false
      end

      # The statements a migration operation that does not read the live
      # schema runs (MySQL::DDL.statements): every kind but the rebuild
      # ones (migrator_rebuild). A partial index raises DB::Error
      # "partial indexes (where:) are not supported on MySQL".
      # @param op [Cybertrain::Migration::Operation]
      # @return [Array<String>]
      def self.ddl_statements(op)
        Cybertrain::DB::MySQL::DDL.statements(op)
      end

      # The CREATE TABLE of the Migrator's schema_migrations, when there
      # is none (a VARCHAR key: MySQL keys no TEXT without a prefix length).
      # @return [String]
      def self.migrator_schema_migrations_sql
        "CREATE TABLE IF NOT EXISTS schema_migrations (version VARCHAR(255) NOT NULL PRIMARY KEY)" +
          Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS
      end

      # The current time as Integer epoch microseconds (UTC), in SQL: the
      # session's time zone is +00:00, so UNIX_TIMESTAMP reads NOW(6) as UTC.
      # @return [String]
      def self.now_epoch_usec_sql
        "CAST(UNIX_TIMESTAMP(NOW(6)) * 1000000 AS SIGNED)"
      end

      # --- Relation ---------------------------------------------------------

      # The Float sum of `arg` (`expr` or `DISTINCT expr`), 0.0 over no rows
      # or only NULLs (SQLite's TOTAL): the DOUBLE 0e0 makes the COALESCE a
      # DOUBLE, never a DECIMAL.
      # @param arg [String]
      # @return [String]
      def self.relation_float_total(arg)
        "COALESCE(SUM(#{arg}), 0e0)"
      end

      # The alias a derived table (`FROM (SELECT ...)`) takes: MySQL
      # requires one (error 1248). SQLite: "".
      # @return [String]
      def self.relation_subquery_alias
        " AS cybertrain_sub"
      end

      # The ESCAPE clause of where_like's LIKE: the escape character is a
      # backslash, which a MySQL string literal writes doubled. SQLite:
      # " ESCAPE '\'".
      # @return [String]
      def self.relation_like_escape
        " ESCAPE '\\\\'"
      end

      # The LIMIT that means none, for an OFFSET (MySQL takes OFFSET only
      # after a LIMIT): the largest it accepts. SQLite: "-1".
      # @return [String]
      def self.relation_no_limit
        "18446744073709551615"
      end

      # What `id IN (...)` holds to name the ids of the windowed SELECT
      # `window` (update_all / delete_all with a limit or offset): the
      # window as a derived table, since MySQL refuses a LIMIT in an IN
      # subquery (error 1235) and a subquery on the table being changed
      # (error 1093), but not a derived table of it. SQLite: `window`.
      # @param id [String]
      # @param window [String]
      # @return [String]
      def self.relation_window_ids(id, window)
        "SELECT #{id} FROM (#{window}) AS cybertrain_sub"
      end

      # --- Model bulk writes --------------------------------------------------

      # The tail of Model.upsert / upsert_all: " AS excluded ON DUPLICATE KEY
      # UPDATE <assignments>" (each "`c` = <expr>", where excluded.c is the
      # value the INSERT tried to write). With no assignment the colliding
      # row is left as it is: " ON DUPLICATE KEY UPDATE <first conflict col>
      # = <first conflict col>" (a column set to itself; MySQL has no DO
      # NOTHING), without the alias, beside which the bare column would be
      # ambiguous (error 1052). For the same reason an assignment's
      # expression names the table's own column qualified by the table
      # (`calls = stats.calls + excluded.calls`).
      # @param conflict_cols [Array<String>]
      # @param assignments [Array<String>]
      # @return [String]
      def self.bulk_writes_upsert_tail(conflict_cols, assignments)
        if assignments.empty?
          first = conflict_cols.empty? ? "`id`" : conflict_cols[0]
          return " ON DUPLICATE KEY UPDATE #{first} = #{first}"
        end

        set_list = assignments.join(", ")
        " AS #{ROW_ALIAS} ON DUPLICATE KEY UPDATE #{set_list}"
      end

      # The tail of Model.insert_all: a row that collides on any unique key
      # is left as it is (not INSERT IGNORE, which would also turn a NOT
      # NULL or a range error into a warning).
      # @return [String]
      def self.bulk_writes_ignore_tail
        " ON DUPLICATE KEY UPDATE `id` = `id`"
      end

      # MySQL has no RETURNING (returning? is false): "".
      # @param columns [Array<String>]
      # @return [String]
      def self.bulk_writes_returning_tail(columns)
        ""
      end

      # Before a bulk INSERT whose rows are read back by their ids: the
      # session's LAST_INSERT_ID() set to 0, so bulk_writes_first_insert_id
      # tells "this INSERT made no id" from an earlier statement's id.
      # SQLite: nothing (its RETURNING answers the rows).
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.bulk_writes_mark_insert_id(conn)
        conn.execute("SELECT LAST_INSERT_ID(0) AS n")
        nil
      end

      # The AUTO_INCREMENT id of the first row the last INSERT made, 0 when
      # it made none since bulk_writes_mark_insert_id. The ids one INSERT
      # makes are consecutive, in the order of its rows (InnoDB allocates a
      # multi-row INSERT's ids at once, innodb_autoinc_lock_mode=2
      # included).
      # @param conn [Cybertrain::DB::Connection]
      # @return [Integer]
      def self.bulk_writes_first_insert_id(conn)
        rows = conn.execute("SELECT LAST_INSERT_ID() AS n")
        return 0 if rows.empty?

        Cybertrain::Cast.int(rows[0]["n"])
      end

      # --- Cache --------------------------------------------------------------

      # An expires_at of 0 is stored as NULL (never expires). `key` is a
      # reserved word in MySQL, so it is quoted everywhere.
      CACHE_WRITE_SQL = "INSERT INTO cybertrain_cache (`key`, value, expires_at, updated_at) " \
                        "VALUES (?, ?, NULLIF(?, 0), ?) AS excluded " \
                        "ON DUPLICATE KEY UPDATE value = excluded.value, " \
                        "expires_at = excluded.expires_at, updated_at = excluded.updated_at"

      # write(unless_exist: true), first statement: the row for the key is
      # deleted when it has expired (binds key, now).
      CACHE_DELETE_EXPIRED_SQL = "DELETE FROM cybertrain_cache WHERE `key` = ? " \
                                 "AND expires_at IS NOT NULL AND expires_at < ?"

      # write(unless_exist: true), second statement: the row inserted only
      # when the key has none (binds key, value, expires_at, now, key). One
      # row affected when it was written, none when a live row was there.
      CACHE_ADD_SQL = "INSERT INTO cybertrain_cache (`key`, value, expires_at, updated_at) " \
                      "SELECT ?, ?, NULLIF(?, 0), ? FROM DUAL WHERE NOT EXISTS " \
                      "(SELECT 1 FROM cybertrain_cache WHERE `key` = ?)"

      # A value read as an Integer as SQLite's CAST(value AS INTEGER) reads
      # it: its leading digits (after spaces, with a sign), 0 when it has
      # none. A plain CAST would refuse text that is not a number under the
      # strict sql_mode.
      CACHE_INT_VALUE = "COALESCE(CAST(REGEXP_SUBSTR(cybertrain_cache.value, '^ *[-+]?[0-9]+') AS SIGNED), 0)"

      # Binds key, by, expires_at (0: none given), now; then now, now, expires_at
      # for the CASEs (positional binds: each use is its own `?`). A missing
      # row starts at `by`, an expired one too (and loses its old expiry);
      # a live one adds `by`. A given expiry replaces the row's. expires_at
      # is assigned last, so the value's CASE reads the old expiry.
      CACHE_INCREMENT_SQL = "INSERT INTO cybertrain_cache (`key`, value, expires_at, updated_at) " \
                            "VALUES (?, ?, NULLIF(?, 0), ?) AS excluded " \
                            "ON DUPLICATE KEY UPDATE " \
                            "value = CASE WHEN cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ? " \
                            "THEN excluded.value ELSE #{CACHE_INT_VALUE} + excluded.value END, " \
                            "updated_at = excluded.updated_at, " \
                            "expires_at = CASE WHEN cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ? " \
                            "THEN excluded.expires_at " \
                            "WHEN cybertrain_cache.expires_at IS NULL AND ? > 0 THEN excluded.expires_at " \
                            "ELSE cybertrain_cache.expires_at END"

      # Cache.write: the row for `key` (expires_at 0: none), or with
      # `unless_exist` only when there is none or it has expired. Whether a
      # row was written.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.cache_write(conn, key, value, expires_at, now, unless_exist)
        unless unless_exist
          conn.execute(CACHE_WRITE_SQL, Cybertrain::Cast.binds(key, value, expires_at, now))
          return true
        end

        conn.execute(CACHE_DELETE_EXPIRED_SQL, Cybertrain::Cast.binds(key, now))
        conn.execute(CACHE_ADD_SQL, Cybertrain::Cast.binds(key, value, expires_at, now, key))
        conn.changes > 0
      end

      # Cache.increment: the counter for `key` after adding `by`, read back
      # by a SELECT in the same transaction as the upsert (one is opened
      # when none is). 0 when no row came back.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Integer]
      def self.cache_increment(conn, key, by, expires_at, now)
        binds = Cybertrain::Cast.binds(key, by, expires_at, now, now, now, expires_at)
        conn.begin!
        begin
          conn.execute(CACHE_INCREMENT_SQL, binds)
          found = conn.execute("SELECT #{CACHE_INT_VALUE} AS n FROM cybertrain_cache WHERE `key` = ?", [key])
        rescue StandardError => e
          conn.rollback!
          raise e
        end
        conn.commit!
        return 0 if found.empty?

        Cybertrain::Cast.int(found[0]["n"])
      end

      # Cache.prune: deletes at most `limit` rows expired before `now`, and
      # answers how many.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Integer]
      def self.cache_prune(conn, now, limit)
        sql = "DELETE FROM cybertrain_cache WHERE expires_at IS NOT NULL AND expires_at < ? LIMIT #{limit}"
        conn.execute(sql, [now])
        conn.changes
      end

      # --- Lease --------------------------------------------------------------

      # Binds name, holder, expires_at, now. holder is assigned first, from
      # the old row: it becomes ours when it was ours or has expired; then
      # expires_at follows when holder (now) is ours. A lease another holder
      # still has is left alone.
      LEASE_ACQUIRE_SQL = "INSERT INTO cybertrain_leases (name, holder, expires_at) VALUES (?, ?, ?) AS excluded " \
                          "ON DUPLICATE KEY UPDATE " \
                          "holder = IF(cybertrain_leases.holder = excluded.holder OR cybertrain_leases.expires_at < ?, " \
                          "excluded.holder, cybertrain_leases.holder), " \
                          "expires_at = IF(cybertrain_leases.holder = excluded.holder, excluded.expires_at, " \
                          "cybertrain_leases.expires_at)"

      # Lease.acquire: whether `holder` now has the lease `name` until
      # `expires_at` (the row's holder read back; a renewal that changes
      # nothing is still a renewal).
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.lease_acquire(conn, name, holder, expires_at, now)
        conn.execute(LEASE_ACQUIRE_SQL, Cybertrain::Cast.binds(name, holder, expires_at, now))
        rows = conn.execute("SELECT holder FROM cybertrain_leases WHERE name = ?", [name])
        return false if rows.empty?

        Cybertrain::Cast.str(rows[0]["holder"]) == holder.to_s
      end

      # --- Scheduler::Timetable -------------------------------------------------

      # The test that lets Timetable.write move a row: a later last run, or
      # the same one and a next run no earlier.
      TIMETABLE_FORWARD = "(COALESCE(excluded.last_run_at, 0) > COALESCE(cybertrain_schedules.last_run_at, 0) " \
                          "OR (COALESCE(excluded.last_run_at, 0) = COALESCE(cybertrain_schedules.last_run_at, 0) " \
                          "AND excluded.next_run_at >= cybertrain_schedules.next_run_at))"

      # Timetable.write's statement: binds name, last_run_at (0: stored as
      # NULL), next_run_at, now. A row is never moved backwards. Each column
      # takes IF(<test>, new, old); MySQL assigns left to right, so the
      # columns go updated_at, next_run_at, last_run_at: the test reads
      # next_run_at after it may have moved, and answers the same then
      # (moved, it equals excluded.next_run_at and the test was true).
      # @return [String]
      def self.timetable_write_sql
        "INSERT INTO cybertrain_schedules (name, last_run_at, next_run_at, updated_at) " \
          "VALUES (?, NULLIF(?, 0), ?, ?) AS excluded " \
          "ON DUPLICATE KEY UPDATE " \
          "updated_at = IF(#{TIMETABLE_FORWARD}, excluded.updated_at, cybertrain_schedules.updated_at), " \
          "next_run_at = IF(#{TIMETABLE_FORWARD}, excluded.next_run_at, cybertrain_schedules.next_run_at), " \
          "last_run_at = IF(#{TIMETABLE_FORWARD}, excluded.last_run_at, cybertrain_schedules.last_run_at)"
      end

      # Timetable.write_missing's statement (binds name, next_run_at, now):
      # a new task's row, left alone when one exists.
      # @return [String]
      def self.timetable_insert_missing_sql
        "INSERT INTO cybertrain_schedules (name, last_run_at, next_run_at, updated_at) " \
          "VALUES (?, NULL, ?, ?) ON DUPLICATE KEY UPDATE name = name"
      end

      # --- WebSocket::FeedTable -------------------------------------------------

      # FeedTable.upsert_feed's statement (binds name, process, connected,
      # started_at, last_activity_at (0: NULL), restarts, now).
      # @return [String]
      def self.feed_table_write_sql
        "INSERT INTO cybertrain_feeds " \
          "(name, process, connected, started_at, last_activity_at, restarts, updated_at) " \
          "VALUES (?, ?, ?, ?, NULLIF(?, 0), ?, ?) AS excluded " \
          "ON DUPLICATE KEY UPDATE process = excluded.process, " \
          "connected = excluded.connected, started_at = excluded.started_at, " \
          "last_activity_at = excluded.last_activity_at, restarts = excluded.restarts, " \
          "updated_at = excluded.updated_at"
      end

      # --- Test::Database --------------------------------------------------------

      # Deletes every row of `table`.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.test_database_clear_table(conn, table)
        quoted = Dialect.quote_ident(table)
        conn.execute("DELETE FROM #{quoted}")
        nil
      end

      # Nothing: on MySQL the database's name is the proof that `cybertrain
      # test` may empty it.
      # @param conn [Cybertrain::DB::Connection]
      # @param marker [Integer]
      # @return [nil]
      def self.test_database_mark(conn, marker)
        nil
      end

      # --- Schema reading (SchemaDumper, Migrator) --------------------------------

      # The table's columns, one row each in declaration order, with the
      # keys "name", "type" (as SqliteDDL would declare it: "VARCHAR",
      # "INTEGER", "BOOLEAN", ...; MySQL::SchemaReader), "notnull" (0/1),
      # "dflt_value" (the default's SQL text, as SQLite reports it, or nil)
      # and "pk" (0, or the column's place in the primary key).
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<Hash{String => Object}>]
      def self.schema_columns(conn, table)
        Cybertrain::DB::MySQL::SchemaReader.column_rows(conn, table)
      end

      # The table's indexes but the primary key, one row each with "name"
      # and "unique" (0/1).
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<Hash{String => Object}>]
      def self.schema_index_rows(conn, table)
        conn.execute("SELECT index_name AS name, IF(MIN(non_unique) = 0, 1, 0) AS `unique` " \
                     "FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? " \
                     "AND index_name <> 'PRIMARY' GROUP BY index_name ORDER BY index_name", [table])
      end

      # The CREATE INDEX text of `table`'s index `index` when it has an
      # expression among its key parts, "" for an index of columns only
      # (MySQL keeps no CREATE INDEX text:
      # MySQL::SchemaReader.expression_index_sql writes one from
      # information_schema.statistics).
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @param index [String]
      # @return [String]
      def self.schema_index_sql(conn, table, index)
        Cybertrain::DB::MySQL::SchemaReader.expression_index_sql(conn, table, index)
      end

      # The column names of `table`'s index `index`, in key order.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @param index [String]
      # @return [Array<String>]
      def self.schema_index_columns(conn, table, index)
        rows = conn.execute("SELECT column_name AS name FROM information_schema.statistics " \
                            "WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? " \
                            "ORDER BY seq_in_index", [table, index])
        names = Array.new(0) { "" }
        rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
        names
      end

      # The table's foreign keys, one row each with "table" (the parent),
      # "from" (the column) and "on_delete" ("CASCADE", "SET NULL",
      # "RESTRICT", "NO ACTION", ...).
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @return [Array<Hash{String => Object}>]
      def self.schema_foreign_key_rows(conn, table)
        conn.execute("SELECT k.referenced_table_name AS `table`, k.column_name AS `from`, r.delete_rule AS on_delete " \
                     "FROM information_schema.key_column_usage k JOIN information_schema.referential_constraints r " \
                     "ON r.constraint_schema = k.constraint_schema AND r.constraint_name = k.constraint_name " \
                     "AND r.table_name = k.table_name " \
                     "WHERE k.table_schema = DATABASE() AND k.table_name = ? AND k.referenced_table_name IS NOT NULL " \
                     "ORDER BY k.constraint_name, k.ordinal_position", [table])
      end

      # --- Migrator ----------------------------------------------------------------

      # Whether foreign keys are checked on this session now.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.migrator_foreign_keys_enforced?(conn)
        rows = conn.execute("SELECT @@foreign_key_checks AS n")
        !rows.empty? && Cybertrain::Cast.int(rows[0]["n"]) != 0
      end

      # Every row that names a missing parent, as "<table> row <id> ->
      # <parent>" joined with ", "; "" when there is none.
      # @param conn [Cybertrain::DB::Connection]
      # @return [String]
      def self.migrator_foreign_key_check(conn)
        found = Array.new(0) { "" }
        Dialect.foreign_key_columns(conn, "").each do |fk|
          table = Cybertrain::Cast.str(fk["t"])
          parent = Cybertrain::Cast.str(fk["p"])
          rows = Dialect.orphan_rows(conn, table, Cybertrain::Cast.str(fk["c"]), parent,
                                     Cybertrain::Cast.str(fk["r"]), 1_000_000)
          rows.each { |r| found << "#{table} row #{Cybertrain::Cast.int(r["id"])} -> #{parent}" }
        end
        found.join(", ")
      end

      # Runs one operation SQLite rebuilds its table for (op.rebuilds?):
      # MySQL changes the table in place, with the one ALTER TABLE
      # MySQL::DDL.rebuild_sql writes from `definition` (the live schema
      # dumped just now). A change_column_null's backfill is not run here:
      # the Migrator runs it first, as a statement of its own (SQLite's
      # rebuild runs it).
      # @param conn [Cybertrain::DB::Connection]
      # @param op [Cybertrain::Migration::Operation]
      # @param definition [Cybertrain::Schema::Definition]
      # @return [nil]
      def self.migrator_rebuild(conn, op, definition)
        conn.exec_script(Cybertrain::DB::MySQL::DDL.rebuild_sql(conn, op, definition))
        nil
      end
    end
  end
end
