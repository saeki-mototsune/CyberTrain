# Cybertrain::Migration -- the migration DSL (Cybertrain::Migration::Base)
# and the recorded-operation data it produces. This is a pure data model:
# nothing here talks to a database. The SQLite adapter that turns
# `Operation#kind` into DDL is `cybertrain/db/sqlite_ddl.rb`; the migrator
# that issues it is `cybertrain/db/migrator.rb`.
require "cybertrain/schema"
require "cybertrain/cast"

module Cybertrain
  module Migration
    # Raised when rolling back a `change` that recorded an operation with no
    # automatic inverse (anything but create_table, add_column, add_index,
    # rename_column, rename_table, {Base#reversible} and the
    # change_column_default / change_column_null calls whose previous state
    # is known, including an {Base#execute}); write `down` (and `up` where
    # `change` cannot run forward either) instead.
    # @api public
    class IrreversibleMigration < StandardError
    end

    # One recorded migration step. `table` holds a String table name for
    # every kind except :create_table, where it holds the actual
    # Cybertrain::Schema::Table built by the block (there is no separate
    # table name to carry -- the Table already has one). Callers that need
    # a name from either shape use `Operation.table_name`.
    #
    # An :execute operation (Base#execute) carries its SQL in `exec_sql` and
    # its binds in `exec_binds` instead; every other kind leaves them "" and
    # empty. The names are distinctive on purpose: Relation has a `binds`
    # (spikes/NOTES.md rules 10/34).
    #
    # An :add_column's decimal `precision`/`scale` (0 and -1 for none), an
    # :add_index's partial `where` ("" for none) and an :add_reference's or
    # :add_foreign_key's `on_delete` (:no_action by default) are assigned
    # after `new` too, the same way and for the same reason.
    #
    # The kinds that rebuild a table (`rebuilds?`): :change_column (name,
    # type, null, default, limit, precision, scale), :change_column_default
    # (name; `default` the new one, `from_default` the previous one when
    # `from_given`), :change_column_null (name, null; a backfill UPDATE in
    # `exec_sql` / `exec_binds` when a default was given), :remove_reference
    # (name: the "<ref>_id" column) and :remove_foreign_key (name: the
    # column, to_table). :rename_table keeps the old name in `table` and the
    # new one in `new_name`. :reversible_up / :reversible_down carry one
    # statement of a {Base#reversible} block in `exec_sql` / `exec_binds`;
    # the Migrator runs the up ones and skips the down ones, and `inverse`
    # swaps the two kinds.
    class Operation
      attr_reader :kind, :table, :name, :type, :null, :default, :limit,
                  :to_table, :columns, :unique, :new_name, :exec_sql, :exec_binds,
                  :precision, :scale, :where, :on_delete, :from_default, :from_given

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
        @exec_sql = ""
        @exec_binds = Operation.no_binds
        @precision = 0
        @scale = -1
        @where = ""
        @on_delete = :no_action
        @from_default = Operation.no_default
        @from_given = false
      end

      # true for the kinds the Migrator applies by rebuilding the table
      # (SqliteDDL.rebuild_table).
      def rebuilds?
        case @kind
        when :change_column, :change_column_default, :change_column_null, :remove_reference, :remove_foreign_key
          true
        else
          false
        end
      end

      # nil typed as the String-or-nil a default holds.
      def self.no_default
        values = ["", nil]
        values[1]
      end

      # An empty bind list typed for the values Cast.to_sql returns (nil,
      # Integer, Float, String), seeded per spikes/NOTES.md rule 9 the way
      # Relation seeds its own.
      def self.no_binds
        binds = [nil, 0, 0.0, ""]
        binds.clear
        binds
      end

      # `binds` is already converted (Cast.to_sql). The SQL and binds are
      # assigned after `new` rather than passed to it, so the eleven
      # schema-shaped arguments every other kind passes stay as they are.
      def self.for_execute(sql, binds)
        op = new(:execute, "", "", :string, true, nil, 0, "", [], false, "")
        op.assign_exec(sql, binds)
        op
      end

      # Public only so for_execute (a class method) can call it
      # (spikes/NOTES.md rule 38).
      def assign_exec(sql, binds)
        @exec_sql = sql
        @exec_binds = binds
        nil
      end

      # Public for the same reason as assign_exec.
      def assign_decimal(precision, scale)
        @precision = precision
        @scale = scale
        nil
      end

      def assign_where(where)
        @where = where
        nil
      end

      def assign_on_delete(action)
        @on_delete = action
        nil
      end

      def assign_from(given, value)
        @from_given = given
        @from_default = value
        nil
      end

      def self.for_create_table(table)
        new(:create_table, table, "", :string, true, nil, 0, "", [], false, "")
      end

      def self.for_drop_table(name)
        new(:drop_table, name, "", :string, true, nil, 0, "", [], false, "")
      end

      def self.for_add_column(table, name, type, null, default, limit, precision = 0, scale = -1)
        op = new(:add_column, table, name, type, null, default, limit, "", [], false, "")
        op.assign_decimal(precision, scale)
        op
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
      # `where` non-empty makes it a partial index.
      def self.for_add_index(table, columns, unique, name, where = "")
        op = new(:add_index, table, name, :string, true, nil, 0, "", columns, unique, "")
        op.assign_where(where)
        op
      end

      def self.for_remove_index(table, columns)
        new(:remove_index, table, "", :string, true, nil, 0, "", columns, false, "")
      end

      def self.for_add_reference(table, name, null, on_delete = :no_action)
        op = new(:add_reference, table, name, :integer, null, nil, 0, "", [], false, "")
        op.assign_on_delete(on_delete)
        op
      end

      def self.for_add_foreign_key(from_table, to_table, column, on_delete = :no_action)
        op = new(:add_foreign_key, from_table, column, :string, true, nil, 0, to_table, [], false, "")
        op.assign_on_delete(on_delete)
        op
      end

      def self.for_rename_table(old_name, new_name)
        new(:rename_table, old_name, "", :string, true, nil, 0, "", [], false, new_name)
      end

      def self.for_change_column(table, name, type, null, default, limit, precision, scale)
        op = new(:change_column, table, name, type, null, default, limit, "", [], false, "")
        op.assign_decimal(precision, scale)
        op
      end

      # `from_given` false: the previous default is unknown, so the
      # operation has no inverse.
      def self.for_change_column_default(table, name, from_given, from, to)
        op = new(:change_column_default, table, name, :string, true, to, 0, "", [], false, "")
        op.assign_from(from_given, from)
        op
      end

      # `binds` holds the backfill value (already Cast.to_sql) or nothing.
      def self.for_change_column_null(table, name, null, binds)
        op = new(:change_column_null, table, name, :string, null, nil, 0, "", [], false, "")
        op.assign_exec("UPDATE #{table} SET #{name} = ? WHERE #{name} IS NULL", binds) unless binds.empty?
        op
      end

      def self.for_remove_reference(table, column)
        new(:remove_reference, table, column, :integer, true, nil, 0, "", [], false, "")
      end

      def self.for_remove_foreign_key(from_table, to_table, column)
        new(:remove_foreign_key, from_table, column, :string, true, nil, 0, to_table, [], false, "")
      end

      # `kind` :reversible_up or :reversible_down, with the statement of
      # `op` (an :execute).
      def self.for_reversible(kind, op)
        result = new(kind, "", "", :string, true, nil, 0, "", [], false, "")
        result.assign_exec(op.exec_sql, op.exec_binds)
        result
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
    # A data step goes through {#execute}, which runs in order with the
    # schema operations, in the same transaction.
    # SQLite cannot add a foreign key to an existing table, so declare
    # references in `create_table` or with {#add_reference}.
    # {#change_column}, {#change_column_default}, {#change_column_null},
    # {#remove_reference} and {#remove_foreign_key} rebuild the table (SQLite
    # has no ALTER COLUMN), with foreign key enforcement off for the version
    # and checked before its commit. The rebuilt table is declared from the
    # schema, so a rebuild refuses (DB::Error "rebuilding <table> would drop
    # <what>: rewrite the migration with execute", before it touches the
    # table, and the version rolls back) a table whose CREATE TABLE has
    # what the schema does not model: a CHECK or inline UNIQUE constraint (a unique index is fine),
    # COLLATE, a generated column, ON UPDATE, ON DELETE SET DEFAULT,
    # DEFERRABLE, a foreign key to a column other than id, a column with no
    # type, a primary key other than id, WITHOUT ROWID or STRICT. Write
    # such a change as {#execute} statements. Not available:
    # `create_join_table`.
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
      # change_column_default's `from:` when it is not given (the previous
      # default is then unknown). Not a default anyone writes.
      UNKNOWN_DEFAULT = "<unknown default>"

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
      #   `:decimal`, `:boolean`, `:datetime`, `:date`, `:binary` (BLOB) or
      #   `:json`
      # @param null [Boolean]
      # @param default [String, nil] SQL literal text
      # @param limit [Integer] `VARCHAR(n)` for a string when positive;
      #   8 makes an integer a `BIGINT`
      # @param precision [Integer] a decimal's total digits; 0 for none
      # @param scale [Integer] a decimal's digits after the point; -1 for
      #   none (a scale needs a precision: ArgumentError otherwise)
      # @return [nil]
      # @api public
      def add_column(table, name, type, null: true, default: nil, limit: 0, precision: 0, scale: -1)
        Cybertrain::Schema::Column.check_decimal(precision, scale)
        @operations << Operation.for_add_column(table.to_s, name.to_s, type, null, default, limit, precision, scale)
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
      # @param where [String] a partial index's predicate
      #   (`"deleted_at IS NULL"`); "" for none
      # @return [nil]
      # @api public
      def add_index(table, columns, unique: false, name: "", where: "")
        cols = columns.map { |c| c.to_s }
        @operations << Operation.for_add_index(table.to_s, cols, unique, name.to_s, where.to_s)
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
      # @param on_delete [Symbol] `:no_action`, `:cascade`, `:nullify` (needs
      #   `null: true`) or `:restrict`, as {Schema::TableDef#references}
      # @return [nil]
      # @api public
      def add_reference(table, name, null: false, foreign_key: true, on_delete: :no_action)
        Cybertrain::Schema::ForeignKey.check_on_delete(on_delete)
        Cybertrain::Schema::ForeignKey.check_nullify(on_delete, null)
        column_name = "#{name}_id"
        @operations << Operation.for_add_reference(table.to_s, column_name, null, on_delete)
        if foreign_key
          to_table = Cybertrain::Inflector.pluralize(name.to_s)
          @operations << Operation.for_add_foreign_key(table.to_s, to_table, column_name, on_delete)
        end
        nil
      end

      # Runs a data statement (an UPDATE, an INSERT, a DELETE) at this point
      # of the migration, on the migrator's own connection and inside the
      # same transaction as the version's schema operations: operations
      # recorded before it have run when it runs, and those after it run
      # after it. Nothing runs while the migration is only being recorded,
      # so the migrator can call `up` to learn a version's operations (it
      # does, when rolling back) without repeating the statement.
      #
      # Without binds `sql` may hold several statements separated by `;`;
      # with binds it must be exactly one statement with `?` placeholders.
      #
      # Not reversible: rolling back a `change` that executes SQL raises
      # {IrreversibleMigration} before anything is reverted, unless the
      # migration defines {#down}. `db/schema.rb` is dumped from the
      # database, so a data statement never appears in it.
      # @example keep existing rows when a new column's default would change them
      #   class AddRetentionDaysToBackups < Cybertrain::Migration::Base
      #     def change
      #       add_column "backups", "retention_days", :integer, null: false, default: "90"
      #       execute "UPDATE backups SET retention_days = ?", [0]
      #     end
      #
      #     def down
      #       remove_column "backups", "retention_days"
      #     end
      #   end
      # @param sql [String]
      # @param binds [Array<String, Integer, Float, Boolean, Time, nil>]
      #   values for the `?` placeholders, in order
      # @return [nil]
      # @api public
      def execute(sql, binds = [])
        values = Operation.no_binds
        binds.each { |v| values << Cybertrain::Cast.to_sql(v) }
        @operations << Operation.for_execute(sql.to_s, values)
        nil
      end

      # Renames a table (`ALTER TABLE ... RENAME TO ...`); the foreign keys
      # that point at it follow. Its indexes keep their names. Reversible.
      # @param old_name [String, Symbol]
      # @param new_name [String, Symbol]
      # @return [nil]
      # @api public
      def rename_table(old_name, new_name)
        @operations << Operation.for_rename_table(old_name.to_s, new_name.to_s)
        nil
      end

      # Redefines a column: the table is rebuilt with the column declared
      # as given (everything not given is reset, as in Rails), its rows
      # copied over. Not reversible inside `change`: write `up` and `down`.
      # @example
      #   change_column :posts, :views, :bigint
      #   change_column :posts, :price, :decimal, precision: 10, scale: 2, null: false, default: "0"
      # @param table [String, Symbol]
      # @param column [String, Symbol]
      # @param type [Symbol] a type {#add_column} takes, or `:bigint`
      # @param null [Boolean]
      # @param default [String, nil] SQL literal text
      # @param limit [Integer] as {#add_column}
      # @param precision [Integer] as {#add_column}
      # @param scale [Integer] as {#add_column}
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when migrating, if the table has something a
      #   rebuild would drop (see the class notes); the version rolls back
      # @api public
      def change_column(table, column, type, null: true, default: nil, limit: 0, precision: 0, scale: -1)
        Cybertrain::Schema::Column.check_decimal(precision, scale)
        kind = type
        size = limit
        if type == :bigint
          kind = :integer
          size = 8
        end
        @operations << Operation.for_change_column(table.to_s, column.to_s, kind, null, default, size, precision, scale)
        nil
      end

      # Changes a column's default (by rebuilding the table). Reversible
      # when `from:` names the previous default (`from: nil` when there was
      # none); without it a rollback raises {IrreversibleMigration}.
      # @example
      #   change_column_default :posts, :state, from: nil, to: "'draft'"
      # @param table [String, Symbol]
      # @param column [String, Symbol]
      # @param from [String, nil] the previous default, SQL literal text
      # @param to [String, nil] the new default, SQL literal text; nil drops it
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when migrating, if the table has something a
      #   rebuild would drop (see the class notes); the version rolls back
      # @api public
      def change_column_default(table, column, from: UNKNOWN_DEFAULT, to:)
        given = from != UNKNOWN_DEFAULT
        previous = given ? from : Operation.no_default
        @operations << Operation.for_change_column_default(table.to_s, column.to_s, given, previous, to)
        nil
      end

      # Adds or drops a column's NOT NULL (by rebuilding the table). With
      # `null` false, `default` is first written into the cells that are
      # NULL (`UPDATE ... WHERE column IS NULL`); it does not become the
      # column's DEFAULT. Reversible, except that rolling back a `null`
      # true needs `default` for the cells that became NULL since.
      # @example
      #   change_column_null :posts, :title, false, "untitled"
      # @param table [String, Symbol]
      # @param column [String, Symbol]
      # @param null [Boolean]
      # @param default [String, Integer, Float, Boolean, Time, nil] a value
      #   (not SQL text) for the NULL cells
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when migrating, if the table has something a
      #   rebuild would drop (see the class notes); the version rolls back
      # @api public
      def change_column_null(table, column, null, default = nil)
        values = Operation.no_binds
        values << Cybertrain::Cast.to_sql(default) unless default.nil?
        @operations << Operation.for_change_column_null(table.to_s, column.to_s, null, values)
        nil
      end

      # Drops `<name>_id`, its indexes and its foreign key (by rebuilding
      # the table). Not reversible inside `change`.
      # @param table [String, Symbol]
      # @param name [Symbol, String] the singular (`:author`)
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when migrating, if the table has something a
      #   rebuild would drop (see the class notes); the version rolls back
      # @api public
      def remove_reference(table, name)
        @operations << Operation.for_remove_reference(table.to_s, "#{name}_id")
        nil
      end

      # Drops the foreign key from `from_table` to `to_table` (by rebuilding
      # the table); the column and its index stay. Not reversible inside
      # `change`.
      # @param from_table [String, Symbol]
      # @param to_table [String, Symbol]
      # @param column [String] the referencing column; "" means
      #   singularize(to_table) + "_id"
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when migrating, if the table has something a
      #   rebuild would drop (see the class notes); the version rolls back
      # @api public
      def remove_foreign_key(from_table, to_table, column: "")
        col = column.to_s
        col = Cybertrain::Schema::ForeignKey.default_column(to_table) if col == ""
        @operations << Operation.for_remove_foreign_key(from_table.to_s, to_table.to_s, col)
        nil
      end

      # A data step written both ways inside `change`: `dir.up`'s
      # {#execute} statements run on migrate, `dir.down`'s on rollback.
      # Only {#execute} goes inside the blocks.
      # @example
      #   reversible do |dir|
      #     dir.up { execute "UPDATE posts SET slug = lower(title)" }
      #     dir.down { execute "UPDATE posts SET slug = NULL" }
      #   end
      # @yieldparam dir [Direction]
      # @return [nil]
      # @api public
      def reversible
        yield Direction.new(self)
        nil
      end

      # Turns the :execute operations recorded since index `start` into
      # `kind` (:reversible_up / :reversible_down). Public for Direction.
      #
      # A down block's statements are stored in reverse: the Migrator skips
      # :reversible_down going forward, so their order there does not
      # matter, and a rollback (the default `down`) reverses the whole list,
      # which puts them back in the order they were written. An up block's
      # stay as written: they run forward, and a rollback turns them into
      # skipped :reversible_down operations.
      def mark_reversible(start, kind)
        segment = Array.new(0) { Operation.for_drop_table("") }
        i = start
        while i < @operations.size
          op = @operations[i]
          if op.kind != :execute
            message = "only execute goes inside reversible's up and down blocks, not #{op.kind}"
            raise ArgumentError, message
          end
          segment << Operation.for_reversible(kind, op)
          i += 1
        end
        segment = segment.reverse if kind == :reversible_down
        j = 0
        while j < segment.size
          @operations[start + j] = segment[j]
          j += 1
        end
        nil
      end

      def add_foreign_key(from_table, to_table, column: "", on_delete: :no_action)
        Cybertrain::Schema::ForeignKey.check_on_delete(on_delete)
        col = column
        col = Cybertrain::Schema::ForeignKey.default_column(to_table) if col == ""
        @operations << Operation.for_add_foreign_key(from_table.to_s, to_table.to_s, col.to_s, on_delete)
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
      # mechanically-reversible kinds invert (change_column_default when its
      # `from:` was given, change_column_null when the state before it can
      # be restored); everything else (drops, removals, references, foreign
      # keys, change_column) needs an explicit `down` and raises here.
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
        when :rename_table
          Operation.for_rename_table(op.new_name, Operation.table_name(op.table))
        when :change_column_default
          unless op.from_given
            raise IrreversibleMigration, "change_column_default without from: has no automatic inverse; pass from: or write down"
          end
          Operation.for_change_column_default(op.table, op.name, true, op.default, op.from_default)
        when :change_column_null
          if op.null && op.exec_binds.empty?
            raise IrreversibleMigration,
                  "change_column_null to null: true has no automatic inverse without a default for the NULL cells; " \
                  "pass the fourth argument or write down"
          end
          Operation.for_change_column_null(op.table, op.name, !op.null, op.exec_binds)
        when :reversible_up
          Operation.for_reversible(:reversible_down, op)
        when :reversible_down
          Operation.for_reversible(:reversible_up, op)
        when :execute
          raise IrreversibleMigration, "it executes SQL in change; write down"
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

    # The `dir` a {Base#reversible} block receives.
    # @api public
    class Direction
      def initialize(migration)
        @migration = migration
      end

      # The block's {Base#execute} statements run when migrating.
      # @return [nil]
      # @api public
      def up
        start = @migration.operations.size
        yield
        @migration.mark_reversible(start, :reversible_up)
        nil
      end

      # The block's {Base#execute} statements run when rolling back.
      # @return [nil]
      # @api public
      def down
        start = @migration.operations.size
        yield
        @migration.mark_reversible(start, :reversible_down)
        nil
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
