require "cybertrain/db/error"
require "cybertrain/db/sqlite_ddl"
require "cybertrain/db/schema_dumper"
require "cybertrain/migration"

module Cybertrain
  module DB
    # Cybertrain::DB::Migrator -- runs Cybertrain::Migration::Base
    # subclasses against a Connection, tracking applied versions in a
    # `schema_migrations` table.
    #
    # `migrations` throughout is the Array<[version, migration]> shape
    # Cybertrain::Migration.all/register already use (sorted by version).
    class Migrator
      def initialize(connection)
        @connection = connection
        @connection.exec_script("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)")
      end

      def applied_versions
        rows = @connection.execute("SELECT version FROM schema_migrations ORDER BY version")
        rows.map { |r| r["version"].to_s }
      end

      # The subset of `migrations` not yet in `applied_versions`, in the
      # order they were given (Migration.all is already version-sorted). An
      # applied version that no entry carries (a database Rails created, its
      # db/migrate not copied) is not pending and is never run.
      def pending(migrations)
        applied = applied_versions
        result = Cybertrain::Migration.empty_entries
        migrations.each do |entry|
          result << entry unless applied.include?(entry[0])
        end
        result
      end

      # Runs every pending migration's forward operations (recorded by
      # `up`) inside one transaction per migration, then records its
      # version. Returns the number of migrations applied.
      def migrate(migrations)
        count = 0
        pending(migrations).each do |entry|
          version = entry[0]
          migration = entry[1]
          puts "== #{version} #{migration.class.name}: migrating"
          record(migration, true)
          ops = migration.operations
          apply_version(version, ops, empty_operations, "INSERT INTO schema_migrations (version) VALUES (?)")
          count += 1
        end
        count
      end

      # Reverts the last `steps` applied versions (newest first), using
      # `down` (the default `down` replays `change`'s inverse operations; a
      # migration that overrides `down` directly is honored the same way).
      # Returns the number reverted. Raises DB::Error before reverting
      # anything when one of those versions has no entry in `migrations`
      # (its file was deleted or renamed), as Rails'
      # UnknownMigrationVersionError does, instead of silently skipping it.
      # Raises Migration::IrreversibleMigration ("version N is irreversible:
      # ..."), also before reverting anything, when one of them cannot be
      # rolled back: a `change` that recorded an operation with no automatic
      # inverse (an `execute`, a `drop_table`) and no `down` of its own.
      def rollback(migrations, steps = 1)
        targets = Array.new(0) { "" }
        applied_versions.reverse.each do |version|
          break if targets.size >= steps
          targets << version
        end
        targets.each do |version|
          if find_migration(migrations, version).nil?
            raise Error, "no migration for applied version #{version} (was its file in db/migrate deleted or renamed?)"
          end
        end
        targets.each do |version|
          migration = find_migration(migrations, version)
          check_reversible(version, migration) unless migration.nil?
        end
        count = 0
        targets.each do |version|
          migration = find_migration(migrations, version)
          next if migration.nil?
          puts "== #{version} #{migration.class.name}: reverting"
          # The forward operations name the indexes the inverse drops
          # (Base#inverse turns add_index into a remove_index that keeps only
          # the columns), so they are recorded first and consulted below.
          record(migration, true)
          forward = migration.operations.dup
          record(migration, false)
          ops = migration.operations
          apply_version(version, ops, forward, "DELETE FROM schema_migrations WHERE version = ?")
          count += 1
        end
        count
      end

      # Array<[status "up"/"down", version, class name]> for every entry of
      # `migrations`, in the order given, with each applied version that no
      # entry carries listed as ["up", version, "applied (no file)"] among
      # them in version order.
      def status(migrations)
        applied = applied_versions
        known = migrations.map { |entry| entry[0] }
        orphans = applied.reject { |version| known.include?(version) }
        result = Array.new(0) { ["", "", ""] }
        k = 0
        migrations.each do |entry|
          version = entry[0]
          while k < orphans.size && orphans[k] < version
            result << ["up", orphans[k], "applied (no file)"]
            k += 1
          end
          migration = entry[1]
          state = applied.include?(version) ? "up" : "down"
          result << [state, version, migration.class.name]
        end
        while k < orphans.size
          result << ["up", orphans[k], "applied (no file)"]
          k += 1
        end
        result
      end

      private

      # The step migrate and rollback share: runs `ops` and `sql` (the
      # schema_migrations INSERT or DELETE for `version`) in one transaction,
      # then prints "done". The "== <version> <class>: <verb>" line stays in
      # the callers, before record(), so it still prints when up raises (an
      # irreversible down is caught earlier, by check_reversible).
      #
      # A version with an operation that rebuilds a table runs with foreign
      # key enforcement off, as SQLite's procedure requires: dropping the old
      # table would otherwise fire ON DELETE CASCADE on its children.
      # `PRAGMA foreign_keys = OFF` does nothing inside a transaction, so it
      # is issued before BEGIN, and enforcement is restored after the
      # version, whether it committed or not.
      def apply_version(version, ops, forward, sql)
        rebuilt = rebuilt_tables(ops)
        if rebuilt == ""
          run_version(version, ops, forward, sql, rebuilt)
        else
          enforced = foreign_keys_enforced?
          @connection.exec_script("PRAGMA foreign_keys = OFF")
          begin
            if foreign_keys_enforced?
              message = "cannot rebuild #{rebuilt}: foreign key enforcement stayed on (is a transaction open?)"
              raise Error, message
            end
            run_version(version, ops, forward, sql, rebuilt)
          ensure
            @connection.exec_script("PRAGMA foreign_keys = ON") if enforced
          end
        end
        puts "done"
        nil
      end

      # The version's transaction. With `rebuilt` (the rebuilt tables'
      # names) non-empty, `PRAGMA foreign_key_check` runs before the commit
      # and a violation raises, which rolls the version back. Called from a
      # method body so the transaction (a yielding method with rescue) is
      # never inside a nested block (spikes/NOTES.md rule 45).
      def run_version(version, ops, forward, sql, rebuilt)
        @connection.transaction do
          run_operations(ops, forward)
          check_foreign_keys(rebuilt) if rebuilt != ""
          @connection.execute(sql, [version])
        end
        nil
      end

      def foreign_keys_enforced?
        rows = @connection.execute("PRAGMA foreign_keys")
        !rows.empty? && Cybertrain::Cast.int(rows[0]["foreign_keys"]) != 0
      end

      # "posts, comments": the tables `ops` rebuild, each once, "" for none.
      def rebuilt_tables(ops)
        names = Array.new(0) { "" }
        ops.each do |op|
          next unless op.rebuilds?
          name = Cybertrain::Migration::Operation.table_name(op.table)
          names << name unless names.include?(name)
        end
        names.join(", ")
      end

      def check_foreign_keys(rebuilt)
        rows = @connection.execute("PRAGMA foreign_key_check")
        return nil if rows.empty?
        found = Array.new(0) { "" }
        rows.each { |r| found << "#{r["table"]} row #{r["rowid"]} -> #{r["parent"]}" }
        message = "foreign key check failed after rebuilding #{rebuilt}: #{found.join(", ")}"
        raise Error, message
      end

      # One rebuild operation: the live schema dumped now (after the
      # version's earlier operations), the operation applied to it in
      # memory, and the table rebuilt from the result with its triggers and
      # its sqlite_sequence value as they were. A change_column_null to NOT
      # NULL with a default first backfills the NULL cells.
      def run_rebuild(op)
        table_name = Cybertrain::Migration::Operation.table_name(op.table)
        definition = Cybertrain::DB::SchemaDumper.dump(@connection)
        table = definition.table(table_name)
        if table.nil?
          message = "cannot #{op.kind} on #{table_name}: no such table"
          raise Error, message
        end
        refused = Cybertrain::DB::SqliteDDL.rebuild_refusal(table_sql(table_name))
        if refused != ""
          message = "rebuilding #{table_name} would drop #{refused}: rewrite the migration with execute"
          raise Error, message
        end
        definition.replace_table(Cybertrain::DB::SqliteDDL.table_after(table, op))
        triggers = table_triggers(table_name)
        sequence = table_sequence(table_name)
        @connection.execute(op.exec_sql, op.exec_binds) if op.kind == :change_column_null && !op.null && op.exec_sql != ""
        rename = Cybertrain::DB::SqliteDDL.rename_new_sql(table_name)
        Cybertrain::DB::SqliteDDL.rebuild_table(definition, table_name, triggers, sequence).each do |sql|
          if sql == rename
            run_legacy_rename(sql)
          else
            @connection.exec_script(sql)
          end
        end
        nil
      end

      # The rebuild's RENAME with legacy_alter_table on, so the views and
      # the other tables' triggers that name the table are not checked
      # while it does not exist (they would refuse the RENAME). The pragma
      # is not transactional, so it is turned off again whatever happens.
      # Never used for a plain rename_table, which needs it off for the
      # references to follow the new name.
      def run_legacy_rename(sql)
        @connection.exec_script("PRAGMA legacy_alter_table = ON")
        begin
          @connection.exec_script(sql)
        ensure
          @connection.exec_script("PRAGMA legacy_alter_table = OFF")
        end
        nil
      end

      def table_sql(table_name)
        rows = @connection.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table_name])
        return "" if rows.empty?
        Cybertrain::Cast.str_or_nil(rows[0]["sql"]).to_s
      end

      def table_triggers(table_name)
        rows = @connection.execute("SELECT sql FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name", [table_name])
        result = Array.new(0) { "" }
        rows.each do |r|
          sql = Cybertrain::Cast.str_or_nil(r["sql"])
          result << sql.to_s unless sql.nil?
        end
        result
      end

      # The table's sqlite_sequence value, -1 when it has none (or the
      # database has no AUTOINCREMENT table at all).
      def table_sequence(table_name)
        exists = @connection.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'")
        return -1 if exists.empty?
        rows = @connection.execute("SELECT seq FROM sqlite_sequence WHERE name = ?", [table_name])
        return -1 if rows.empty?
        Cybertrain::Cast.int(rows[0]["seq"])
      end

      # Base#up/#down start from an empty operation list, but a migration
      # that overrides up/down itself only appends to it, so running the same
      # instance twice (migrate, rollback, migrate) would replay stale
      # operations. Clearing the list first makes every run record afresh.
      def record(migration, forward)
        migration.operations.clear
        if forward
          migration.up
        else
          migration.down
        end
        nil
      end

      # Records `down` once, only to learn whether it can be recorded at all,
      # and names the version in the error when it cannot. A non-yielding
      # method holding the rescue (spikes/NOTES.md rules 32/45).
      def check_reversible(version, migration)
        record(migration, false)
        nil
      rescue Cybertrain::Migration::IrreversibleMigration => e
        # A local first: a String made inside the argument list can be freed
        # before the exception holds it (spikes/NOTES.md rule 58).
        message = "version #{version} is irreversible: #{e.message}"
        raise Cybertrain::Migration::IrreversibleMigration, message
      end

      # Runs `ops` in order. An :execute (Base#execute) runs its statement on
      # this connection, inside the version's transaction like the rest;
      # without binds it goes through exec_script, so it may hold several
      # statements; a :reversible_up runs the same way and a :reversible_down
      # (the other direction's statement) is skipped. A rebuild operation
      # goes through `run_rebuild`. Two other operations get special handling:
      # - an :add_reference directly followed by its :add_foreign_key
      #   (Base#add_reference's default) runs as one ADD COLUMN ... REFERENCES,
      #   since SQLite cannot add a foreign key on its own;
      # - a :remove_index without a name drops the index `forward` (the
      #   migration's forward operations, when rolling back) created on those
      #   columns, else the derived index_<table>_on_<cols> when it exists,
      #   else the one index on exactly those columns.
      def run_operations(ops, forward)
        i = 0
        while i < ops.size
          op = ops[i]
          if i + 1 < ops.size && Cybertrain::DB::SqliteDDL.folds_foreign_key?(op, ops[i + 1])
            run_sql(Cybertrain::DB::SqliteDDL.add_reference_statements(op, ops[i + 1].to_table))
            i += 2
          else
            if op.kind == :execute || op.kind == :reversible_up
              run_data_statement(op)
            elsif op.kind == :reversible_down
              nil
            elsif op.rebuilds?
              run_rebuild(op)
            elsif op.kind == :remove_index && op.name == ""
              @connection.exec_script(Cybertrain::DB::SqliteDDL.drop_index_sql(index_to_remove(op, forward)))
            else
              run_sql(Cybertrain::DB::SqliteDDL.statements(op))
            end
            i += 1
          end
        end
        nil
      end

      def run_data_statement(op)
        if op.exec_binds.empty?
          @connection.exec_script(op.exec_sql)
        else
          @connection.execute(op.exec_sql, op.exec_binds)
        end
        nil
      end

      def run_sql(statements)
        statements.each { |sql| @connection.exec_script(sql) }
        nil
      end

      def index_to_remove(op, forward)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        forward.each do |f|
          next unless f.kind == :add_index && f.name != ""
          return f.name if Cybertrain::Migration::Operation.table_name(f.table) == table && f.columns == op.columns
        end
        derived = Cybertrain::DB::SqliteDDL.derived_index_name(table, op.columns)
        names = index_names_on(table, op.columns)
        return derived if names.empty? || names.include?(derived)
        names[0]
      end

      # Names of the indexes on `table` whose columns are exactly `columns`.
      def index_names_on(table, columns)
        result = Array.new(0) { "" }
        @connection.execute("PRAGMA index_list(#{table})").each do |row|
          name = row["name"].to_s
          cols = @connection.execute("PRAGMA index_info(#{name})").map { |r| r["name"].to_s }
          result << name if cols == columns
        end
        result
      end

      def empty_operations
        Array.new(0) { Cybertrain::Migration::Operation.for_drop_table("") }
      end

      def find_migration(migrations, version)
        migrations.each do |entry|
          return entry[1] if entry[0] == version
        end
        nil
      end
    end
  end
end
