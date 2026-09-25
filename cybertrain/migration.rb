# Cybertrain::Migration -- the migration DSL (Cybertrain::Migration::Base)
# and the recorded-operation data it produces. This is a pure data model:
# nothing here talks to a database. The SQLite migrator that walks
# `Operation#kind` and issues DDL is Wave M2b's `cybertrain/db/migrator.rb`.
require "cybertrain/schema"

module Cybertrain
  module Migration
    class IrreversibleMigration < StandardError
    end

    # One recorded migration step. `table` holds a String table name for
    # every kind except :create_table, where it holds the actual
    # Cybertrain::Schema::Table built by the block (there is no separate
    # table name to carry -- the Table already has one). Callers that need
    # a name from either shape use `Operation.table_name`.
    class Operation
      attr_reader :kind, :table, :name, :type, :null, :default, :limit,
                  :to_table, :columns, :unique, :new_name

      def initialize(kind, table, name, type, null, default, limit, to_table, columns, unique, new_name)
        @kind = kind
        @table = table
        @name = name.to_s
        @type = type
        @null = null
        @default = default
        @limit = limit
        @to_table = to_table.to_s
        @columns = columns
        @unique = unique
        @new_name = new_name.to_s
      end

      def self.for_create_table(table)
        new(:create_table, table, "", :string, true, nil, 0, "", [], false, "")
      end

      def self.for_drop_table(name)
        new(:drop_table, name, "", :string, true, nil, 0, "", [], false, "")
      end

      def self.for_add_column(table, name, type, null, default, limit)
        new(:add_column, table, name, type, null, default, limit, "", [], false, "")
      end

      def self.for_remove_column(table, name)
        new(:remove_column, table, name, :string, true, nil, 0, "", [], false, "")
      end

      def self.for_rename_column(table, from, to)
        new(:rename_column, table, from, :string, true, nil, 0, "", [], false, to)
      end

      # `name` overrides the derived index name (empty means "derive it the
      # way Cybertrain::Schema::Index does"), for symmetry with
      # Definition#add_index.
      def self.for_add_index(table, columns, unique, name)
        new(:add_index, table, name, :string, true, nil, 0, "", columns, unique, "")
      end

      def self.for_remove_index(table, columns)
        new(:remove_index, table, "", :string, true, nil, 0, "", columns, false, "")
      end

      def self.for_add_reference(table, name, null)
        new(:add_reference, table, name, :integer, null, nil, 0, "", [], false, "")
      end

      def self.for_add_foreign_key(from_table, to_table, column)
        new(:add_foreign_key, from_table, column, :string, true, nil, 0, to_table, [], false, "")
      end

      # `table` is a String for every kind except :create_table (a Table);
      # this narrows it back to a plain name either way.
      def self.table_name(value)
        case value
        when Cybertrain::Schema::Table
          value.name
        when String
          value
        else
          ""
        end
      end
    end

    class Base
      # Migration version strings ("20260924120000") declared per subclass
      # via `self.version(v)`. Keyed by class name (a String) rather than a
      # per-subclass class ivar, per spikes/NOTES.md rule 4.
      # Seeded with its element type per spikes/NOTES.md rule 9 (h = { "" =>
      # "" }; h.delete("")), so a program that never declares a migration
      # version still compiles.
      VERSIONS = begin
        h = { "" => "" }
        h.delete("")
        h
      end

      def initialize
        @operations = empty_operations
      end

      # Subclasses override `change` (recorded both ways via `inverse`) or
      # `up`/`down` directly when a migration is not mechanically reversible.
      def change
      end

      # Both `up` and `down` reset `@operations` before running `change` so
      # calling either one twice (or calling both on the same instance)
      # never duplicates or mixes forward/backward operations.
      def up
        @operations = empty_operations
        change
        nil
      end

      # The default `down` runs `change` to record the forward operations,
      # then replaces them with their inverses in reverse order -- it must
      # NOT simply re-run `change` and keep the forward operations, or a
      # rollback would re-apply the migration instead of undoing it. Raises
      # IrreversibleMigration (via `inverse`) when `change` recorded an
      # operation with no automatic inverse.
      def down
        @operations = empty_operations
        change
        @operations = @operations.reverse.map { |op| inverse(op) }
        nil
      end

      def create_table(name)
        table = Cybertrain::Schema::Table.new(name)
        yield Cybertrain::Schema::TableDef.new(table)
        @operations << Operation.for_create_table(table)
        table
      end

      # Every DSL method below ends with an explicit `nil`: Cybertrain::Schema
      # (Definition, Table) declares methods of the same name for its own
      # `db/schema.rb` DSL, and Spinel infers one return type per method
      # name across every unrelated class that defines it, so an implicit
      # `Array#<<` return here would fight their `nil`/object returns and
      # corrupt one of them. See spikes/NOTES.md rule 10.
      def drop_table(name)
        @operations << Operation.for_drop_table(name)
        nil
      end

      def add_column(table, name, type, null: true, default: nil, limit: 0)
        @operations << Operation.for_add_column(table, name, type, null, default, limit)
        nil
      end

      def remove_column(table, name)
        @operations << Operation.for_remove_column(table, name)
        nil
      end

      def rename_column(table, from, to)
        @operations << Operation.for_rename_column(table, from, to)
        nil
      end

      def add_index(table, columns, unique: false, name: "")
        cols = columns.map { |c| c.to_s }
        @operations << Operation.for_add_index(table, cols, unique, name)
        nil
      end

      def remove_index(table, columns)
        cols = columns.map { |c| c.to_s }
        @operations << Operation.for_remove_index(table, cols)
        nil
      end

      def add_reference(table, name, null: false, foreign_key: true)
        column_name = "#{name}_id"
        @operations << Operation.for_add_reference(table, column_name, null)
        if foreign_key
          to_table = Cybertrain::Schema.pluralize(name.to_s)
          @operations << Operation.for_add_foreign_key(table, to_table, column_name)
        end
        nil
      end

      def add_foreign_key(from_table, to_table, column: "")
        col = column
        col = "#{Cybertrain::Schema.singularize(to_table.to_s)}_id" if col == ""
        @operations << Operation.for_add_foreign_key(from_table, to_table, col)
        nil
      end

      def operations
        @operations
      end

      def self.version(v)
        VERSIONS[self.name] = v.to_s
      end

      def self.version_string
        VERSIONS[self.name] || ""
      end

      # The `down` counterpart of one `change`-recorded operation. Only the
      # four mechanically-reversible kinds invert; everything else (drops,
      # removals, references, foreign keys) needs an explicit `down` and
      # raises here.
      def inverse(op)
        case op.kind
        when :create_table
          Operation.for_drop_table(Operation.table_name(op.table))
        when :add_column
          Operation.for_remove_column(op.table, op.name)
        when :add_index
          Operation.for_remove_index(op.table, op.columns)
        when :rename_column
          Operation.for_rename_column(op.table, op.new_name, op.name)
        else
          raise IrreversibleMigration, "no automatic inverse for #{op.kind}"
        end
      end

      private

      # Seeded with its element type per spikes/NOTES.md rule 9, so a
      # migration whose `change`/`up`/`down` never records anything still
      # compiles.
      def empty_operations
        Array.new(0) { Operation.for_create_table(Cybertrain::Schema::Table.new("")) }
      end
    end

    # The registry gen/migrations.rb (Task 14) fills with one `register`
    # call per migration file, in file order; `all` always hands them back
    # sorted by version so the migrator applies them in the right order
    # regardless of registration order. Seeded with its element type per
    # spikes/NOTES.md rule 9, so a program that never registers a migration
    # still compiles.
    def self.empty_entries
      Array.new(0) { ["", Base.new] }
    end

    @entries = empty_entries

    def self.register(version, migration)
      @entries << [version.to_s, migration]
      @entries = @entries.sort_by { |entry| entry[0] }
    end

    def self.all
      @entries
    end

    def self.reset!
      @entries = empty_entries
    end
  end
end
