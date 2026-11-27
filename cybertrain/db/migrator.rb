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
        @quiet = false
        @connection.exec_script("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)")
      end

      # Stops the progress lines (`== <version> <Class>: migrating`,
      # `done`): `cybertrain test` migrates its fresh database before the
      # tests and prints nothing of it.
      # @return [nil]
      def quiet!
        @quiet = true
        nil
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
          puts "== #{version} #{migration.class.name}: migrating" unless @quiet
          record(migration, true)
          ops = migration.operations
          apply_version(version, ops, Cybertrain::Migration::Operation.empty_list, "INSERT INTO schema_migrations (version) VALUES (?)")
          count += 1
        end
        count
      end

      # Reverts the last `steps` applied versions (newest first), using
      # `down` (the default `down` replays `change`'s inverse operations; a
      # migration that overrides `down` directly is honored the same way).
      # Returns the number reverted. Raises DB::Error before reverting
      # anything when one of those versions has no entry in `migrations`
      # (its file was deleted or renamed, or Rails applied it before the
      # takeover), as Rails' UnknownMigrationVersionError does, instead of
      # silently skipping it.
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
        # Each target's [version, migration] entry, looked up once: every
        # one is found, then every one checked, before any is reverted.
        chosen = Cybertrain::Migration.empty_entries
        targets.each do |version|
          at = entry_index(migrations, version)
          if at < 0
            message = "no migration for applied version #{version} (was its file in db/migrate deleted or renamed, " \
                      "or was it applied by Rails before the takeover?)"
            raise Error, message
          end
          chosen << migrations[at]
        end
        chosen.each { |entry| check_reversible(entry[0], entry[1]) }
        count = 0
        chosen.each do |entry|
          version = entry[0]
          migration = entry[1]
          puts "== #{version} #{migration.class.name}: reverting" unless @quiet
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
      # Turning it off (DB::Dialect.foreign_keys_off) does nothing inside a
      # transaction on SQLite, so it is issued before BEGIN, and enforcement
      # is restored after the version, whether it committed or not.
      def apply_version(version, ops, forward, sql)
        rebuilt = rebuilt_tables(ops)
        if rebuilt == ""
          run_version(version, ops, forward, sql, rebuilt)
        else
          enforced = Dialect.migrator_foreign_keys_enforced?(@connection)
          Dialect.foreign_keys_off(@connection)
          begin
            if Dialect.migrator_foreign_keys_enforced?(@connection)
              message = "cannot rebuild #{rebuilt}: foreign key enforcement stayed on (is a transaction open?)"
              raise Error, message
            end
            run_version(version, ops, forward, sql, rebuilt)
          ensure
            Dialect.foreign_keys_on(@connection) if enforced
          end
        end
        puts "done" unless @quiet
        nil
      end

      # The version's transaction. With `rebuilt` (the rebuilt tables'
      # names) non-empty, DB::Dialect.migrator_foreign_key_check runs before
      # the commit and a violation raises, which rolls the version back. Called from a
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

      # "posts, comments": the tables `ops` rebuild, each once, "" for none.
      def rebuilt_tables(ops)
        names = Array.new(0) { "" }
        ops.each do |op|
          next unless op.rebuilds?
          name = op.table_text
          names << name unless names.include?(name)
        end
        names.join(", ")
      end

      def check_foreign_keys(rebuilt)
        found = Dialect.migrator_foreign_key_check(@connection)
        return nil if found == ""
        message = "foreign key check failed after rebuilding #{rebuilt}: #{found}"
        raise Error, message
      end

      # One rebuild operation, from the live schema dumped now (after the
      # version's earlier operations): DB::Dialect.migrator_rebuild (on
      # SQLite the table rebuilt by its procedure, with its triggers and
      # its sqlite_sequence value as they were).
      def run_rebuild(op)
        definition = Cybertrain::DB::SchemaDumper.dump(@connection)
        Dialect.migrator_rebuild(@connection, op, definition)
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
      # - a :remove_index drops the index `forward` (the
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
            elsif op.kind == :remove_index
              @connection.exec_script(Cybertrain::DB::SqliteDDL.drop_index_sql(index_to_remove(op, forward)))
            else
              run_sql(Dialect.ddl_statements(op))
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
        table = op.table_text
        forward.each do |f|
          next unless f.kind == :add_index && f.name != ""
          return f.name if f.table_text == table && f.columns == op.columns
        end
        derived = Cybertrain::DB::SqliteDDL.derived_index_name(table, op.columns)
        names = index_names_on(table, op.columns)
        return derived if names.empty? || names.include?(derived)
        names[0]
      end

      # Names of the indexes on `table` whose columns are exactly `columns`.
      def index_names_on(table, columns)
        result = Array.new(0) { "" }
        Dialect.schema_index_rows(@connection, table).each do |row|
          name = row["name"].to_s
          cols = Dialect.schema_index_columns(@connection, table, name)
          result << name if cols == columns
        end
        result
      end

      # The index in `migrations` of the entry for `version`, or -1.
      def entry_index(migrations, version)
        i = 0
        while i < migrations.size
          return i if migrations[i][0] == version
          i += 1
        end
        -1
      end
    end
  end
end
