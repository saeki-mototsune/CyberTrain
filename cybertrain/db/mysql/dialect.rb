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
      # left as it is (bulk_writes_upsert_tail). The text alone, with no
      # conflict target: a collision on any unique key of the table takes
      # the update. Model.upsert and upsert_all write theirs with
      # bulk_writes_upsert_sql, which checks the target and guards the
      # other unique keys.
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

      # The rows of `table` whose `column` names no row of `parent` (by
      # `ref`), at most `limit`: each with "v", the value, and, when
      # `with_id`, "id", in id order. A table without an id column
      # (create_table ..., id: false) is read by the foreign key column
      # alone, in its order.
      def self.orphan_rows(conn, table, column, parent, ref, limit, with_id)
        t = Dialect.quote_ident(table)
        c = Dialect.quote_ident(column)
        p = Dialect.quote_ident(parent)
        r = Dialect.quote_ident(ref)
        id = with_id ? "ch.`id` AS id, " : ""
        order = with_id ? "ch.`id`" : "ch.#{c}"
        conn.execute("SELECT #{id}ch.#{c} AS v FROM #{t} ch LEFT JOIN #{p} pa ON pa.#{r} = ch.#{c} " \
                     "WHERE ch.#{c} IS NOT NULL AND pa.#{r} IS NULL ORDER BY #{order} LIMIT #{limit}")
      end

      # Whether `table` has an id column to name its rows by.
      def self.id_column?(conn, table)
        Dialect.column_names(conn, table).include?("id")
      end

      # "" when no row names a missing parent, else the first such row as
      # "<table> row with id <id> has <column> <value>, which names no row
      # of <parent>" (the SQLite Dialect's text), or, in a table without an
      # id column, "<table> row with <column> <value>, which names no row of
      # <parent>". Either ends in the parent's name, which
      # Test::Database.violation_parent reads. MySQL has no
      # foreign_key_check: each foreign key is joined to its parent.
      # @param conn [Cybertrain::DB::Connection]
      # @return [String]
      def self.foreign_key_violation(conn)
        Dialect.foreign_key_columns(conn, "").each do |fk|
          table = Cybertrain::Cast.str(fk["t"])
          column = Cybertrain::Cast.str(fk["c"])
          parent = Cybertrain::Cast.str(fk["p"])
          with_id = Dialect.id_column?(conn, table)
          found = Dialect.orphan_rows(conn, table, column, parent, Cybertrain::Cast.str(fk["r"]), 1, with_id)
          next if found.empty?

          value = Cybertrain::Cast.str(found[0]["v"])
          return "#{table} row with #{column} #{value}, which names no row of #{parent}" unless with_id

          id = Cybertrain::Cast.int(found[0]["id"])
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

      # The tail of an upsert as text alone: " AS excluded ON DUPLICATE KEY
      # UPDATE <assignments>" (each "`c` = <expr>", where excluded.c is the
      # value the INSERT tried to write). With no assignment the colliding
      # row is left as it is: " ON DUPLICATE KEY UPDATE <first conflict col>
      # = <first conflict col>" (a column set to itself; MySQL has no DO
      # NOTHING), without the alias, beside which the bare column would be
      # ambiguous (error 1052). For the same reason an assignment's
      # expression names the table's own column qualified by the table
      # (`calls = stats.calls + excluded.calls`). It has no conflict target
      # (MySQL has none): Model.upsert and upsert_all write theirs with
      # bulk_writes_upsert_sql, which adds what they need.
      # @param conflict_cols [Array<String>] quoted
      # @param assignments [Array<String>]
      # @return [String]
      # @raise [ArgumentError] with no assignment and no conflict column
      def self.bulk_writes_upsert_tail(conflict_cols, assignments)
        if assignments.empty?
          raise ArgumentError, "an upsert needs a conflict column" if conflict_cols.empty?

          first = conflict_cols[0]
          return " ON DUPLICATE KEY UPDATE #{first} = #{first}"
        end

        set_list = assignments.join(", ")
        " AS #{ROW_ALIAS} ON DUPLICATE KEY UPDATE #{set_list}"
      end

      # --- Upserts: the conflict target MySQL does not have -------------------
      #
      # SQLite's `ON CONFLICT (cols)` names the unique index whose collision
      # takes the update; a collision on any other unique key raises, and a
      # target that is no unique index is refused. MySQL's ON DUPLICATE KEY
      # UPDATE takes a collision on any unique key of the table. So that
      # Model.upsert and upsert_all answer what they answer on SQLite:
      #
      # - the target must be exactly the columns of the primary key or of
      #   one unique index (in any order), else DB::Error before anything
      #   runs (upsert_unique_keys reads the table's unique keys once per
      #   table and connect; upsert_target_key compares);
      # - where the table has another unique key a row could collide on
      #   (any unique index, or the primary key unless it is an
      #   AUTO_INCREMENT id the rows do not supply), every assignment is
      #   guarded by the target: it takes its expression only when the row
      #   found has the inserted row's target values, and the first
      #   assignment, for a row found on another key, evaluates UUID_TO_BIN
      #   of UPSERT_GUARD, whose error 1411 fails the statement (InnoDB
      #   rolls the statement back, so nothing of it is written);
      #   bulk_writes_execute raises it as DB::UniqueViolation, as SQLite
      #   raises its UNIQUE constraint failure. The guard's argument names a
      #   column of the row found (LEFT(col, 0): `col IS NULL` on a NOT
      #   NULL column is folded to a constant, and the server then raised
      #   at PREPARE), so it is evaluated only for that row. When a row
      #   collides on the target and on another key at once, MySQL takes
      #   the key it checks first (the primary key, then the unique
      #   indexes in order): a raise where SQLite may update the
      #   target's row, never a write to a row the target does not name;
      # - Model.upsert answers 1 or 0 (bulk_writes_upsert_count). The
      #   affected-row count cannot: under CLIENT_FOUND_ROWS it is 1 for an
      #   insert, 2 for an updated row and 1 for a row found and left as it
      #   is. An empty `update` (DO NOTHING) marks the row it leaves through
      #   LAST_INSERT_ID(UPSERT_SKIP_MARK), the statement's insert id when
      #   no row was inserted; an inserted row's insert id is its own
      #   AUTO_INCREMENT id (or 0), never the mark unless that id is
      #   2**63 - 1.
      #
      # Assignments to target columns go last, so that every guard before
      # them reads the row found as it was (MySQL assigns left to right).

      # What the guard's UUID_TO_BIN is given: its error 1411 quotes it.
      UPSERT_GUARD = "cybertrain: upsert collided on another unique key"

      # The insert id of a DO NOTHING upsert that left a row (see above).
      UPSERT_SKIP_MARK = 9_223_372_036_854_775_807

      # table => its unique keys (upsert_unique_keys), for the connect
      # @upsert_keys_generation names (DB.generation): module-level ivars
      # (spikes/NOTES.md rule 18), read and written under UPSERT_KEYS_LOCK
      # (rule 57: shared mutable state is synchronized).
      @upsert_keys = { "" => [""] }
      @upsert_keys.delete("")
      @upsert_keys_generation = 0
      UPSERT_KEYS_LOCK = Mutex.new

      # Forgets every table's unique keys: the Migrator calls it after a
      # version, whose DDL may have changed them. Keys read before another
      # process changed the schema are kept until this process connects
      # again or migrates.
      # @return [nil]
      def self.forget_schema_cache
        UPSERT_KEYS_LOCK.synchronize { @upsert_keys.clear }
        nil
      end

      # The unique keys of `table`, each "<kind>:<col>\u001f<col>..." in key
      # order, the primary key first: kind "A" for a one-column
      # AUTO_INCREMENT primary key, "P" for another primary key, "U" for a
      # unique index; a key part that is an expression is "(expression)".
      # Read once per table and connect; `fresh` reads again.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @param fresh [Boolean]
      # @return [Array<String>]
      def self.upsert_unique_keys(conn, table, fresh)
        generation = Cybertrain::DB.generation
        cached = Array.new(0) { "" }
        found = false
        UPSERT_KEYS_LOCK.synchronize do
          if @upsert_keys_generation != generation
            @upsert_keys.clear
            @upsert_keys_generation = generation
          end
          if !fresh && @upsert_keys.key?(table)
            cached = @upsert_keys[table]
            found = true
          end
        end
        return cached if found

        rows = conn.execute("SELECT s.index_name AS name, s.column_name AS col, c.extra AS extra " \
                            "FROM information_schema.statistics s LEFT JOIN information_schema.columns c " \
                            "ON c.table_schema = s.table_schema AND c.table_name = s.table_name " \
                            "AND c.column_name = s.column_name " \
                            "WHERE s.table_schema = DATABASE() AND s.table_name = ? AND s.non_unique = 0 " \
                            "ORDER BY s.index_name <> 'PRIMARY', s.index_name, s.seq_in_index", [table])
        keys = Array.new(0) { "" }
        name = ""
        parts = Array.new(0) { "" }
        auto = false
        rows.each do |r|
          index = Cybertrain::Cast.str(r["name"])
          if !parts.empty? && index != name
            keys << Dialect.upsert_key_text(name, parts, auto)
            parts = Array.new(0) { "" }
            auto = false
          end
          name = index
          col = Cybertrain::Cast.str_or_nil(r["col"])
          parts << (col.nil? ? "(expression)" : col)
          auto = true if Cybertrain::Cast.str(r["extra"]).include?("auto_increment")
        end
        keys << Dialect.upsert_key_text(name, parts, auto) unless parts.empty?
        UPSERT_KEYS_LOCK.synchronize { @upsert_keys[table] = keys } unless keys.empty?
        keys
      end

      # One entry of upsert_unique_keys.
      # @return [String]
      def self.upsert_key_text(index, parts, auto)
        kind = "U"
        kind = parts.size == 1 && auto ? "A" : "P" if index == "PRIMARY"
        joined = parts.join("\u001f")
        "#{kind}:#{joined}"
      end

      # The columns of an upsert_unique_keys entry.
      # @return [Array<String>]
      def self.upsert_key_columns(key)
        key[2, key.size - 2].split("\u001f")
      end

      # The entry of `keys` whose columns are `targets` (in any order), ""
      # for none.
      # @return [String]
      def self.upsert_target_key(keys, targets)
        wanted = targets.sort
        keys.each do |key|
          return key if Dialect.upsert_key_columns(key).sort == wanted
        end
        ""
      end

      # Whether a row of `columns` can collide on a unique key of `keys`
      # other than `target`: any unique index, or a primary key but an
      # AUTO_INCREMENT id the rows do not supply.
      # @return [Boolean]
      def self.upsert_other_key?(keys, target, columns)
        keys.each do |key|
          next if key == target
          next if key.start_with?("A:") && !columns.include?(Dialect.upsert_key_columns(key)[0])

          return true
        end
        false
      end

      # The tail of Model.upsert's statement (`mark` true) or of
      # upsert_all's (`mark` false), after its VALUES: the ON DUPLICATE KEY
      # UPDATE that sets `set_cols` (column names) to `set_exprs` (SQL, at
      # the same positions) on a collision on `targets`, or leaves the row
      # with none, as the section notes above say: the target checked
      # against `table`'s unique keys, the assignments guarded where a row
      # of `columns` (the INSERT's columns) can collide on another key, and,
      # with `mark`, a row an empty update leaves marked. SQLite: ON
      # CONFLICT (targets) DO UPDATE SET ... / DO NOTHING.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @param columns [Array<String>]
      # @param targets [Array<String>]
      # @param set_cols [Array<String>]
      # @param set_exprs [Array<String>]
      # @param mark [Boolean]
      # @return [String]
      # @raise [Cybertrain::DB::Error] when `targets` is not exactly the
      #   primary key or a unique index of `table`
      def self.bulk_writes_upsert_sql(conn, table, columns, targets, set_cols, set_exprs, mark)
        keys = Dialect.upsert_unique_keys(conn, table, false)
        target = Dialect.upsert_target_key(keys, targets)
        if target == ""
          keys = Dialect.upsert_unique_keys(conn, table, true)
          target = Dialect.upsert_target_key(keys, targets)
        end
        # A table that is not there is the INSERT's own error.
        if target == "" && (!keys.empty? || Dialect.table_exists?(conn, table))
          list = targets.join(", ")
          message = "upsert: #{list} is not the primary key or a unique index of #{table} (MySQL has no conflict " \
                    "target: conflict: / unique_by: must name exactly the columns of one)"
          raise Error, message
        end
        guarded = target != "" && Dialect.upsert_other_key?(keys, target, columns)
        Dialect.upsert_tail_sql(table, targets, set_cols, set_exprs, mark, guarded)
      end

      # bulk_writes_upsert_sql's text, once the target is known good.
      # @return [String]
      def self.upsert_tail_sql(table, targets, set_cols, set_exprs, mark, guarded)
        qt = Dialect.quote_ident(table)
        first = Dialect.quote_ident(targets[0])
        terms = Array.new(0) { "" }
        targets.each do |name|
          col = Dialect.quote_ident(name)
          terms << "#{qt}.#{col} <=> #{ROW_ALIAS}.#{col}"
        end
        match = terms.join(" AND ")
        raising = "UUID_TO_BIN(CONCAT('#{UPSERT_GUARD}', COALESCE(LEFT(#{qt}.#{first}, 0), ''))) IS NULL"
        if set_cols.empty?
          kept = guarded ? "#{qt}.#{first}" : first
          kept = "IF(LAST_INSERT_ID(#{UPSERT_SKIP_MARK}) > 0, #{kept}, #{kept})" if mark
          return " ON DUPLICATE KEY UPDATE #{first} = #{kept}" unless guarded

          return " AS #{ROW_ALIAS} ON DUPLICATE KEY UPDATE #{first} = " \
                 "CASE WHEN #{match} THEN #{kept} WHEN #{raising} THEN #{qt}.#{first} ELSE #{qt}.#{first} END"
        end

        sets = Array.new(0) { "" }
        unless guarded
          set_cols.each_with_index { |name, i| sets << "#{Dialect.quote_ident(name)} = #{set_exprs[i]}" }
          return Dialect.bulk_writes_upsert_tail([first], sets)
        end

        order = Array.new(0) { 0 }
        set_cols.each_with_index { |name, i| order << i unless targets.include?(name) }
        set_cols.each_with_index { |name, i| order << i if targets.include?(name) }
        order.each do |i|
          col = Dialect.quote_ident(set_cols[i])
          expr = set_exprs[i]
          set = "#{col} = IF(#{match}, #{expr}, #{qt}.#{col})"
          if sets.empty?
            set = "#{col} = CASE WHEN #{match} THEN #{expr} WHEN #{raising} THEN #{qt}.#{col} ELSE #{qt}.#{col} END"
          end
          sets << set
        end
        Dialect.bulk_writes_upsert_tail([first], sets)
      end

      # Runs one statement of Model.upsert or upsert_all: a collision the
      # guard caught (UPSERT_GUARD's error) raised as DB::UniqueViolation,
      # any other error as it came. SQLite: conn.execute.
      # @param conn [Cybertrain::DB::Connection]
      # @param sql [String]
      # @param binds [Array]
      # @return [Array<Hash{String => Object}>]
      # @raise [Cybertrain::DB::UniqueViolation] on a collision on a unique
      #   key other than the conflict target
      def self.bulk_writes_execute(conn, sql, binds)
        conn.execute(sql, binds)
      rescue Cybertrain::DB::Error => e
        raise e unless e.message.include?(UPSERT_GUARD)

        message = "upsert: a row collides with an existing row on a unique key other than the conflict target, " \
                  "and nothing was written (SQLite: UNIQUE constraint failed): #{e.message}"
        raise UniqueViolation, message
      end

      # Runs Model.upsert's statement and answers the rows it wrote, as
      # SQLite counts them: 1 for a row inserted or updated, 0 for a row an
      # empty update (`skips`) left as it was (see the section notes).
      # @param conn [Cybertrain::DB::Connection]
      # @param sql [String]
      # @param binds [Array]
      # @param skips [Boolean]
      # @return [Integer]
      def self.bulk_writes_upsert_count(conn, sql, binds, skips)
        conn.forget_last_insert_id
        Dialect.bulk_writes_execute(conn, sql, binds)
        return conn.changes > 0 ? 1 : 0 unless skips
        return 1 unless conn.last_insert_id == UPSERT_SKIP_MARK

        conn.forget_last_insert_id
        0
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

      # --- The framework's own tables -------------------------------------------

      # The tables take MySQL::DDL's types for what SQLite's hold (its
      # header has the type table): an id BIGINT AUTO_INCREMENT, epoch
      # seconds BIGINT, flags and counters INT, free text MEDIUMTEXT. A text
      # column that is a key or in an index is a VARCHAR(255) (MySQL keys
      # no TEXT without a prefix length), and the indexes are in the CREATE
      # TABLE (MySQL 8.0 has no CREATE INDEX IF NOT EXISTS). A MEDIUMTEXT
      # default is an expression, `DEFAULT ('')`, the only default MySQL
      # takes on one.

      # Creates a framework table from `script` (its `<service>_table_sql`)
      # when `table` is missing. A CREATE TABLE commits the open transaction
      # in MySQL, even IF NOT EXISTS on a table that is there, so nothing is
      # run for a table that exists, and a missing one is refused inside a
      # transaction rather than committing the caller's work half way.
      # @param conn [Cybertrain::DB::Connection]
      # @param table [String]
      # @param script [String]
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the table is missing and a
      #   transaction is open
      def self.framework_table_install(conn, table, script)
        return nil if Dialect.table_exists?(conn, table)

        if conn.in_transaction?
          raise Error, "#{table} does not exist, and MySQL cannot create it inside a transaction (its DDL would " \
                       "commit the transaction): use the feature once outside a transaction first, or call its install!"
        end
        conn.exec_script(script)
        nil
      end

      # Job::Store's table and both its indexes.
      # @return [String]
      def self.job_table_sql
        "CREATE TABLE IF NOT EXISTS cybertrain_jobs (" \
          "id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, " \
          "kind VARCHAR(255) NOT NULL, " \
          "payload MEDIUMTEXT NOT NULL DEFAULT (''), " \
          "run_at BIGINT NOT NULL, " \
          "attempts INT NOT NULL DEFAULT 0, " \
          "last_error MEDIUMTEXT NOT NULL DEFAULT (''), " \
          "state VARCHAR(255) NOT NULL DEFAULT 'queued', " \
          "created_at BIGINT NOT NULL, " \
          "updated_at BIGINT NOT NULL, " \
          "claimed_by VARCHAR(255), " \
          "heartbeat_at BIGINT, " \
          "concurrency_key VARCHAR(255) NOT NULL DEFAULT '', " \
          "request_id VARCHAR(255) NOT NULL DEFAULT '', " \
          "INDEX index_cybertrain_jobs_on_state_and_run_at (state, run_at), " \
          "INDEX cybertrain_jobs_state_kind_key (state, kind, concurrency_key))" +
          Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS
      end

      # Nothing: job_table_sql's CREATE TABLE has the key index, and no
      # MySQL table predates the column (SQLite's adds it to an older one).
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.job_key_index(conn)
        nil
      end

      # A locking read: the claimed row is read as committed and locked
      # until the claim commits, so a second claimer waits for it and then
      # finds it no longer queued. (SKIP LOCKED is a later stage's.)
      # @return [String]
      def self.job_claim_lock
        " FOR UPDATE"
      end

      # A limited claim counts the running rows as a consistent read, which
      # another claim's uncommitted claim is not in. So every limited claim
      # first locks the oldest due row, the row they all read first: a
      # second claim waits there for the first one's COMMIT, and its count
      # (the transaction's first consistent read, so its snapshot) comes
      # after it. Counting with FOR UPDATE instead would take gap locks on
      # the running rows that the next claim's UPDATE then waits for, a
      # deadlock between two claimers.
      # @param conn [Cybertrain::DB::Connection]
      # @param now [Integer] epoch seconds
      # @return [nil]
      def self.job_claim_serialize(conn, now)
        conn.execute("SELECT id FROM cybertrain_jobs WHERE state = 'queued' AND run_at <= ? " \
                     "ORDER BY run_at, id LIMIT 1 FOR UPDATE", [now])
        nil
      end

      # Cache's table.
      # @return [String]
      def self.cache_table_sql
        "CREATE TABLE IF NOT EXISTS cybertrain_cache (" \
          "`key` VARCHAR(255) NOT NULL PRIMARY KEY, " \
          "value MEDIUMTEXT NOT NULL, " \
          "expires_at BIGINT, " \
          "updated_at BIGINT NOT NULL)" +
          Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS
      end

      # Lease's table.
      # @return [String]
      def self.lease_table_sql
        "CREATE TABLE IF NOT EXISTS cybertrain_leases (" \
          "name VARCHAR(255) NOT NULL PRIMARY KEY, " \
          "holder VARCHAR(255) NOT NULL, " \
          "expires_at BIGINT NOT NULL)" +
          Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS
      end

      # Stream's table and its (stream, id) index; a stream name is at most
      # 200 bytes.
      # @return [String]
      def self.stream_table_sql
        "CREATE TABLE IF NOT EXISTS cybertrain_messages (" \
          "id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY, " \
          "stream VARCHAR(255) NOT NULL, " \
          "payload MEDIUMTEXT NOT NULL, " \
          "created_at BIGINT NOT NULL, " \
          "INDEX index_cybertrain_messages_on_stream_and_id (stream, id))" +
          Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS
      end

      # Scheduler::Timetable's table.
      # @return [String]
      def self.timetable_table_sql
        "CREATE TABLE IF NOT EXISTS cybertrain_schedules (" \
          "name VARCHAR(255) NOT NULL PRIMARY KEY, " \
          "last_run_at BIGINT, " \
          "next_run_at BIGINT NOT NULL, " \
          "updated_at BIGINT NOT NULL)" +
          Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS
      end

      # WebSocket::FeedTable's table.
      # @return [String]
      def self.feed_table_table_sql
        "CREATE TABLE IF NOT EXISTS cybertrain_feeds (" \
          "name VARCHAR(255) NOT NULL PRIMARY KEY, " \
          "process VARCHAR(255), " \
          "connected INT, " \
          "started_at BIGINT NOT NULL, " \
          "last_activity_at BIGINT, " \
          "restarts INT, " \
          "updated_at BIGINT NOT NULL)" +
          Cybertrain::DB::MySQL::DDL::TABLE_OPTIONS
      end

      # --- Cache --------------------------------------------------------------

      # An expires_at of 0 is stored as NULL (never expires). `key` is a
      # reserved word in MySQL, so it is quoted everywhere.
      CACHE_WRITE_SQL = "INSERT INTO cybertrain_cache (`key`, value, expires_at, updated_at) " \
                        "VALUES (?, ?, NULLIF(?, 0), ?) AS excluded " \
                        "ON DUPLICATE KEY UPDATE value = excluded.value, " \
                        "expires_at = excluded.expires_at, updated_at = excluded.updated_at"

      # The test of CACHE_ADD_SQL's assignments: the row found has expired
      # (binds now). Each reads the old expires_at, so expires_at is
      # assigned last.
      CACHE_EXPIRED = "(cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ?)"

      # write(unless_exist: true): one INSERT ... ON DUPLICATE KEY UPDATE
      # whose assignments keep a live row as it is and replace an expired
      # one (binds key, value, expires_at, now; then now for each of the
      # four tests). Its answer is a marker passed through LAST_INSERT_ID,
      # since `changes` (CLIENT_FOUND_ROWS) counts 1 both for a new row and
      # for a live row left alone: the new row's updated_at evaluates
      # LAST_INSERT_ID(1), and an existing row's evaluates LAST_INSERT_ID(1)
      # when it is replaced, LAST_INSERT_ID(2) when it is kept, after the
      # VALUES row's (the statement's insert id is the last one). A
      # duplicate key in an upsert is locked exclusively at once, so two
      # adds of one key, even inside transactions, queue on that lock: the
      # second reads the row as the first committed it. (A plain INSERT
      # whose 1062 was then followed by an UPDATE of the expired row took a
      # shared lock first and upgraded it: two such adds deadlocked.)
      CACHE_ADD_SQL = "INSERT INTO cybertrain_cache (`key`, value, expires_at, updated_at) " \
                      "VALUES (?, ?, NULLIF(?, 0), CAST(? AS SIGNED) + 0 * LAST_INSERT_ID(1)) AS excluded " \
                      "ON DUPLICATE KEY UPDATE " \
                      "value = IF(#{CACHE_EXPIRED}, excluded.value, cybertrain_cache.value), " \
                      "updated_at = IF(#{CACHE_EXPIRED}, excluded.updated_at, cybertrain_cache.updated_at) " \
                      "+ 0 * LAST_INSERT_ID(IF(#{CACHE_EXPIRED}, 1, 2)), " \
                      "expires_at = IF(#{CACHE_EXPIRED}, excluded.expires_at, cybertrain_cache.expires_at)"

      # A value read as an Integer as SQLite's CAST(value AS INTEGER) reads
      # it: its leading digits (after spaces, with a sign), 0 when it has
      # none. A plain CAST would refuse text that is not a number under the
      # strict sql_mode.
      CACHE_INT_VALUE = "COALESCE(CAST(REGEXP_SUBSTR(cybertrain_cache.value, '^ *[-+]?[0-9]+') AS SIGNED), 0)"

      # What Cache.increment adds to the counter before it hands it to
      # LAST_INSERT_ID(expr), and takes off again: LAST_INSERT_ID is
      # BIGINT UNSIGNED, so a negative count would come back as 2**64 - n
      # (and the OK packet's insert id is read only up to 2**63 - 1). With
      # 2**62 added, every counter in -2**62 ... 2**62 - 1 passes as an id
      # in 0 ... 2**63 - 1. The lowest, -2**62, is id 0, which the
      # Connection does not take as an id, so cache_increment has it forget
      # the kept one first. A counter above that range is MySQL's BIGINT
      # out-of-range error; one below it is written, and its id (2**64 - n
      # as UNSIGNED) is past what the client reads, so the call raises
      # ConnectionLost (Cache.increment's doc).
      # (CACHE_INCREMENT_SQL writes it as a literal.)
      CACHE_COUNTER_OFFSET = 4_611_686_018_427_387_904

      # Binds key, by, expires_at (0: none given), now; then now, by, now,
      # now, expires_at for the CASEs and updated_at (positional binds: each
      # use is its own `?`). One statement, atomic under the row lock it
      # takes: a missing row starts at `by`, an expired one too (and loses
      # its old expiry); a live one adds `by`: `value = LAST_INSERT_ID(value
      # + ?)`, with CACHE_COUNTER_OFFSET added inside and taken off outside,
      # and the casts between the value's text and SIGNED. The new row's
      # value passes through LAST_INSERT_ID as well, so the statement's
      # insert id is the counter in both branches (the Connection keeps its
      # previous id when a statement reports 0). A given expiry replaces
      # the row's. expires_at is assigned last, so the value's CASE reads
      # the old expiry.
      CACHE_INCREMENT_SQL = "INSERT INTO cybertrain_cache (`key`, value, expires_at, updated_at) " \
                            "VALUES (?, CAST(CAST(LAST_INSERT_ID(CAST(? AS SIGNED) + 4611686018427387904) AS SIGNED) " \
                            "- 4611686018427387904 AS CHAR), NULLIF(?, 0), ?) AS excluded " \
                            "ON DUPLICATE KEY UPDATE " \
                            "value = CAST(CAST(LAST_INSERT_ID(CASE WHEN cybertrain_cache.expires_at IS NOT NULL " \
                            "AND cybertrain_cache.expires_at < ? THEN 0 ELSE #{CACHE_INT_VALUE} END " \
                            "+ CAST(? AS SIGNED) + 4611686018427387904) AS SIGNED) - 4611686018427387904 AS CHAR), " \
                            "updated_at = ?, " \
                            "expires_at = CASE WHEN cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ? " \
                            "THEN excluded.expires_at " \
                            "WHEN cybertrain_cache.expires_at IS NULL AND ? > 0 THEN excluded.expires_at " \
                            "ELSE cybertrain_cache.expires_at END"

      # Cache.write: the row for `key` (expires_at 0: none), or with
      # `unless_exist` only when there is none or it has expired. Whether a
      # row was written: false only when unless_exist found a live row, or
      # lost the race to another add of the same key.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.cache_write(conn, key, value, expires_at, now, unless_exist)
        unless unless_exist
          conn.execute(CACHE_WRITE_SQL, Cybertrain::Cast.binds(key, value, expires_at, now))
          return true
        end

        conn.execute(CACHE_ADD_SQL, Cybertrain::Cast.binds(key, value, expires_at, now, now, now, now, now))
        conn.last_insert_id == 1
      end

      # Cache.increment: the counter for `key` after adding `by`, as the
      # one statement's insert id (CACHE_INCREMENT_SQL); it opens no
      # transaction of its own, and inside the caller's commits or rolls
      # back with it.
      # @param conn [Cybertrain::DB::Connection]
      # @return [Integer]
      def self.cache_increment(conn, key, by, expires_at, now)
        binds = Cybertrain::Cast.binds(key, by, expires_at, now, now, by, now, now, expires_at)
        conn.forget_last_insert_id
        conn.execute(CACHE_INCREMENT_SQL, binds)
        conn.last_insert_id - CACHE_COUNTER_OFFSET
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
      # `expires_at`: the row's holder, read back after the one upsert.
      # `changes` cannot answer it: under CLIENT_FOUND_ROWS the upsert
      # counts 1 for a new row and 1 for a row another holder keeps (found,
      # set to its own values), and 2 for a renewal or a takeover, but 1
      # again for a renewal that changes nothing (test/mysql/lease.rb
      # shows the five counts). The read is a locking one (FOR SHARE), on
      # the row the upsert has just locked: it reads the row as committed
      # or as this upsert wrote it, never an older snapshot of the caller's
      # transaction (in which another holder's takeover would not show).
      # @param conn [Cybertrain::DB::Connection]
      # @return [Boolean]
      def self.lease_acquire(conn, name, holder, expires_at, now)
        conn.execute(LEASE_ACQUIRE_SQL, Cybertrain::Cast.binds(name, holder, expires_at, now))
        rows = conn.execute("SELECT holder FROM cybertrain_leases WHERE name = ? FOR SHARE", [name])
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

      # How Test::Database's refusals begin (SQLite's say the same).
      TEST_DATABASE_WHO = "Test::Database refuses to empty"

      # Deletes every row of `table`.
      # @param conn [Cybertrain::DB::Connection]
      # @return [nil]
      def self.test_database_clear_table(conn, table)
        quoted = Dialect.quote_ident(table)
        conn.execute("DELETE FROM #{quoted}")
        nil
      end

      # Marks the database as one `cybertrain test` took: the table
      # MySQL::TestDatabase::MARKER_TABLE, created when it is not there
      # (DDL: outside any transaction). `marker` is SQLite's application_id,
      # not used here.
      # @param conn [Cybertrain::DB::Connection]
      # @param marker [Integer]
      # @return [nil]
      def self.test_database_mark(conn, marker)
        Cybertrain::DB::MySQL::TestDatabase.mark(conn)
      end

      # Test::Database's refusal of the connected database, decided before
      # it connects: "" when env is "test" and the URL's database name ends
      # in "_test", else "Test::Database refuses to empty <url without
      # password>: <reason>" (MySQL::TestDatabase.url_refusal).
      # `file_verdict` is the refusal of a database that is a file
      # (Test::Database.refusal), which the SQLite Dialect answers; a MySQL
      # database is on a server, and it is not used here.
      # @param env [String]
      # @param target [String] the URL the pool was connected to
      # @param file_verdict [String]
      # @return [String]
      def self.test_database_refusal(env, target, file_verdict)
        Cybertrain::DB::MySQL::TestDatabase.url_refusal(TEST_DATABASE_WHO, env, target)
      end

      # Test::Database's check on the connection, before it deletes
      # anything: "" when the database holds the marker table, or holds no
      # table and the marker table was created now (DDL, so never inside a
      # transaction); else the refusal (MySQL::TestDatabase.claim_refusal).
      # @param conn [Cybertrain::DB::Connection]
      # @param target [String] the URL the pool was connected to
      # @return [String]
      def self.test_database_claim(conn, target)
        Cybertrain::DB::MySQL::TestDatabase.claim_refusal(TEST_DATABASE_WHO, conn, target)
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
      # <parent>" (in a table without an id column, "<table> row with
      # <column> <value> -> <parent>") joined with ", "; "" when there is
      # none.
      # @param conn [Cybertrain::DB::Connection]
      # @return [String]
      def self.migrator_foreign_key_check(conn)
        found = Array.new(0) { "" }
        Dialect.foreign_key_columns(conn, "").each do |fk|
          table = Cybertrain::Cast.str(fk["t"])
          column = Cybertrain::Cast.str(fk["c"])
          parent = Cybertrain::Cast.str(fk["p"])
          with_id = Dialect.id_column?(conn, table)
          rows = Dialect.orphan_rows(conn, table, column, parent, Cybertrain::Cast.str(fk["r"]), 1_000_000, with_id)
          rows.each do |r|
            if with_id
              found << "#{table} row #{Cybertrain::Cast.int(r["id"])} -> #{parent}"
            else
              found << "#{table} row with #{column} #{Cybertrain::Cast.str(r["v"])} -> #{parent}"
            end
          end
        end
        found.join(", ")
      end

      # False: MySQL adds a foreign key to an existing table, so an
      # :add_reference and its :add_foreign_key run as their own statements
      # (the Migrator's steps, without a transaction).
      # @param op [Cybertrain::Migration::Operation]
      # @param next_op [Cybertrain::Migration::Operation]
      # @return [Boolean]
      def self.migrator_folds_reference?(op, next_op)
        false
      end

      # The :add_reference `op`'s statements, then the ALTER TABLE that adds
      # its foreign key to `to_table` (what the two operations run one by
      # one; the Migrator never folds them on MySQL).
      # @param op [Cybertrain::Migration::Operation]
      # @param to_table [String]
      # @return [Array<String>]
      def self.migrator_reference_statements(op, to_table)
        stmts = Cybertrain::DB::MySQL::DDL.statements(op)
        stmts << "ALTER TABLE #{Dialect.quote_ident(op.table_text)} ADD " +
                 Cybertrain::DB::MySQL::DDL.foreign_key_sql(op.name, to_table, op.on_delete)
        stmts
      end

      # DROP INDEX `name` ON `table` (a MySQL index belongs to its table).
      # @param table [String]
      # @param name [String]
      # @return [String]
      def self.migrator_drop_index_sql(table, name)
        "DROP INDEX #{Dialect.quote_ident(name)} ON #{Dialect.quote_ident(table)}"
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
