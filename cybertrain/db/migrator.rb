require "cybertrain/db/error"
require "cybertrain/db/sqlite_ddl"
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
      # order they were given (Migration.all is already version-sorted).
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
          @connection.transaction do
            run_operations(ops, empty_operations)
            @connection.execute("INSERT INTO schema_migrations (version) VALUES (?)", [version])
          end
          puts "done"
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
          @connection.transaction do
            run_operations(ops, forward)
            @connection.execute("DELETE FROM schema_migrations WHERE version = ?", [version])
          end
          puts "done"
          count += 1
        end
        count
      end

      # Array<[status "up"/"down", version, class name]> for every entry of
      # `migrations`, in the order given.
      def status(migrations)
        applied = applied_versions
        result = Array.new(0) { ["", "", ""] }
        migrations.each do |entry|
          version = entry[0]
          migration = entry[1]
          state = applied.include?(version) ? "up" : "down"
          result << [state, version, migration.class.name]
        end
        result
      end

      private

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

      # Runs `ops` in order. Two operations get special handling:
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
            if op.kind == :remove_index && op.name == ""
              @connection.exec_script(Cybertrain::DB::SqliteDDL.drop_index_sql(index_to_remove(op, forward)))
            else
              run_sql(Cybertrain::DB::SqliteDDL.statements(op))
            end
            i += 1
          end
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
