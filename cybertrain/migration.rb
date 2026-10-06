# Cybertrain::Migration -- the migration DSL (Cybertrain::Migration::Base)
# and the recorded-operation data it produces. This is a pure data model:
# nothing here talks to a database. The SQLite adapter that turns
# `Operation#kind` into DDL is `cybertrain/db/sqlite_ddl.rb`; the migrator
# that issues it is `cybertrain/db/migrator.rb`.
require "cybertrain/schema"

module Cybertrain
  module Migration
    # Raised when rolling back a `change` that recorded an operation with no
    # automatic inverse (anything but create_table, add_column, add_index and
    # rename_column); write `up` and `down` instead.
    # @api public
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

    # The superclass of every migration in `db/migrate/`. A file is named
    # `<version>_<name>.rb` (`20260925174942_create_articles.rb`) and holds
    # the class `<Name>` (`CreateArticles`); the version is the file's
    # prefix. `cybertrain generate scaffold` writes one, and
    # `cybertrain db migrate` applies the pending ones (`db rollback [N]`
    # reverts), each in a transaction, then rewrites `db/schema.rb` from the
    # database. Never edit `db/schema.rb` by hand.
    #
    # Write `change` when every operation is reversible (create_table,
    # add_column, add_index, rename_column); otherwise write `up` and `down`.
    # SQLite cannot add a foreign key to an existing table, so declare
    # references in `create_table` or with {#add_reference}. Not available:
    # `rename_table`, `change_column`, `change_column_default`,
    # `change_column_null`, `create_join_table`.
    # @example
    #   class CreateComments < Cybertrain::Migration::Base
    #     def change
    #       create_table "comments" do |t|
    #         t.string "commenter"
    #         t.text "body"
    #         t.references :article
    #         t.timestamps
    #       end
    #     end
    #   end
    # @example up and down
    #   class RemoveSubtitleFromArticles < Cybertrain::Migration::Base
    #     def up
    #       remove_column "articles", "subtitle"
    #     end
    #
    #     def down
    #       add_column "articles", "subtitle", :string
    #     end
    #   end
    # @api public
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

      # Override with the migration's operations; `cybertrain db migrate`
      # runs them, and `db rollback` runs their inverses in reverse order.
      #
      # Subclasses override `change` (recorded both ways via `inverse`) or
      # `up`/`down` directly when a migration is not mechanically reversible.
      # @return [void]
      # @api public
      def change
      end

      # What `db migrate` runs: `change`, unless you override it (together
      # with {#down}) because `change` cannot be reversed automatically.
      #
      # Both `up` and `down` reset `@operations` before running `change` so
      # calling either one twice (or calling both on the same instance)
      # never duplicates or mixes forward/backward operations.
      # @return [void]
      # @api public
      def up
        @operations = empty_operations
        change
        nil
      end

      # What `db rollback` runs: the inverse of `change`, unless you override
      # it (together with {#up}).
      #
      # The default `down` runs `change` to record the forward operations,
      # then replaces them with their inverses in reverse order -- it must
      # NOT simply re-run `change` and keep the forward operations, or a
      # rollback would re-apply the migration instead of undoing it. Raises
      # IrreversibleMigration (via `inverse`) when `change` recorded an
      # operation with no automatic inverse.
      # @return [void]
      # @raise [IrreversibleMigration]
      # @api public
      def down
        @operations = empty_operations
        change
        @operations = @operations.reverse.map { |op| inverse(op) }
        nil
      end

      # Creates a table with an `id` primary key and the columns the block
      # declares. Reversible.
      # @param name [String, Symbol] the plural (`"articles"`)
      # @yieldparam t [Schema::TableDef]
      # @return [void]
      # @api public
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

      # Drops a table. Not reversible.
      # @param name [String, Symbol]
      # @return [nil]
      # @api public
      def drop_table(name)
        @operations << Operation.for_drop_table(name.to_s)
        nil
      end

      # Adds a column. Reversible. SQLite adds a NOT NULL column to an
      # existing table only with a non-NULL `default:`.
      # @example
      #   add_column "articles", "published", :boolean, null: false, default: "false"
      # @param table [String, Symbol]
      # @param name [String, Symbol]
      # @param type [Symbol] `:string`, `:text`, `:integer`, `:float`,
      #   `:boolean`, `:datetime` or `:date`
      # @param null [Boolean]
      # @param default [String, nil] SQL literal text
      # @param limit [Integer] `VARCHAR(n)` for a string when positive
      # @return [nil]
      # @api public
      def add_column(table, name, type, null: true, default: nil, limit: 0)
        @operations << Operation.for_add_column(table.to_s, name.to_s, type, null, default, limit)
        nil
      end

      # Drops a column (`ALTER TABLE ... DROP COLUMN`). Not reversible. Drop
      # its indexes first.
      # @param table [String, Symbol]
      # @param name [String, Symbol]
      # @return [nil]
      # @api public
      def remove_column(table, name)
        @operations << Operation.for_remove_column(table.to_s, name.to_s)
        nil
      end

      # Renames a column. Reversible.
      # @param table [String, Symbol]
      # @param from [String, Symbol]
      # @param to [String, Symbol]
      # @return [nil]
      # @api public
      def rename_column(table, from, to)
        @operations << Operation.for_rename_column(table.to_s, from.to_s, to.to_s)
        nil
      end

      # Adds an index, named `index_<table>_on_<col>_and_<col>` unless
      # `name:` is given. Reversible.
      # @example
      #   add_index "articles", ["slug"], unique: true
      # @param table [String, Symbol]
      # @param columns [Array<String, Symbol>]
      # @param unique [Boolean]
      # @param name [String]
      # @return [nil]
      # @api public
      def add_index(table, columns, unique: false, name: "")
        cols = columns.map { |c| c.to_s }
        @operations << Operation.for_add_index(table.to_s, cols, unique, name.to_s)
        nil
      end

      # Drops the index on these columns. Not reversible.
      # @param table [String, Symbol]
      # @param columns [Array<String, Symbol>]
      # @return [nil]
      # @api public
      def remove_index(table, columns)
        cols = columns.map { |c| c.to_s }
        @operations << Operation.for_remove_index(table.to_s, cols)
        nil
      end

      # Adds `<name>_id` (an integer, NOT NULL by default), an index on it
      # and, unless `foreign_key: false`, a foreign key to the plural table.
      # Not reversible. SQLite adds a NOT NULL column to an existing table
      # only with a default, so pass `null: true` here; in a new table use
      # {Schema::TableDef#references} instead.
      # @param table [String, Symbol]
      # @param name [Symbol, String] the singular (`:author`)
      # @param null [Boolean]
      # @param foreign_key [Boolean]
      # @return [nil]
      # @api public
      def add_reference(table, name, null: false, foreign_key: true)
        column_name = "#{name}_id"
        @operations << Operation.for_add_reference(table.to_s, column_name, null)
        if foreign_key
          to_table = Cybertrain::Inflector.pluralize(name.to_s)
          @operations << Operation.for_add_foreign_key(table, to_table, column_name)
        end
        nil
      end

      def add_foreign_key(from_table, to_table, column: "")
        col = column
        col = "#{Cybertrain::Inflector.singularize(to_table.to_s)}_id" if col == ""
        @operations << Operation.for_add_foreign_key(from_table.to_s, to_table.to_s, col.to_s)
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

    # The registry gen/migrations.rb (written by
    # cybertrain/generator/migrations_emitter.rb) fills with one `register`
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
