# Cybertrain::Schema::{Column,Index,ForeignKey,Table,TableDef} -- the plain
# data objects a schema is made of, plus the `t` builder that `create_table`
# yields. Everything here is pure in-memory data: no database, no SQL
# generation (that belongs to cybertrain/db/sqlite_ddl.rb).
require "cybertrain/generator/inflector"

module Cybertrain
  module Schema
    class Column
      attr_reader :name, :type, :null, :default, :limit, :precision, :scale

      # type: Symbol (:string, :text, :integer, :float, :decimal, :boolean,
      # :datetime, :date, :binary, :json). default: String|nil holding the SQL
      # literal text exactly as written in the DSL (e.g. "0", "'x'",
      # "false"), never a Ruby value. limit: a string's VARCHAR length, or 8
      # for a bigint (an :integer declared BIGINT); 0 none. precision and
      # scale: a decimal's DECIMAL(p,s); precision 0 and scale -1 mean none.
      def initialize(name, type, null, default, limit, precision = 0, scale = -1)
        @name = name.to_s
        @type = type
        @null = null
        @default = default
        @limit = limit
        @precision = precision
        @scale = scale
      end

      # Raises when a decimal's `scale:` comes without a `precision:`:
      # DECIMAL(,s) does not exist, so the scale would be dropped silently.
      # Shared by TableDef#decimal and Migration::Base#add_column.
      def self.check_decimal(precision, scale)
        if scale >= 0 && precision <= 0
          raise ArgumentError, "scale: #{scale} needs a precision: (DECIMAL(precision,scale))"
        end
        nil
      end
    end

    class Index
      attr_reader :table, :columns, :unique, :name, :where, :expression

      # `name` overrides the derived "index_<table>_on_<cols>" name when
      # non-empty; this is what lets the exact text Dumper.to_ruby prints
      # (which always includes `name:`, since the name is deterministic)
      # round-trip through Definition#add_index without ever landing on a
      # name that disagrees with the derived one.
      #
      # `where` is a partial index's predicate (`"deleted_at IS NULL"`) and
      # `expression` an expression index's key text (`"LOWER(email)"`, with
      # `columns` empty); "" means none for both, never nil (one type per
      # attribute).
      def initialize(table, columns, unique, name = "", where = "", expression = "")
        @table = table.to_s
        @columns = columns
        @unique = unique
        @name = name == "" ? Index.derived_name(@table, @columns) : name
        @where = where
        @expression = expression
      end

      # "index_<table>_on_<col>_and_<col>": the one definition of the
      # derived name, shared with SqliteDDL.derived_index_name (DROP INDEX
      # for a remove_index without `name:`, and the Migrator's bookkeeping).
      def self.derived_name(table, columns)
        "index_#{table}_on_#{columns.join("_and_")}"
      end
    end

    class ForeignKey
      attr_reader :from_table, :column, :to_table, :on_delete

      # on_delete: :no_action (the default; the DDL writes no ON DELETE),
      # :cascade, :nullify (SET NULL) or :restrict.
      def initialize(from_table, column, to_table, on_delete = :no_action)
        @from_table = from_table.to_s
        @column = column.to_s
        @to_table = to_table.to_s
        @on_delete = on_delete
      end

      # Raises unless `action` is one of the four on_delete Symbols, so a
      # typo (`on_delete: :casade`) fails where it is written.
      def self.check_on_delete(action)
        case action
        when :no_action, :cascade, :nullify, :restrict
          nil
        else
          raise ArgumentError, "on_delete must be :no_action, :cascade, :nullify or :restrict, got #{action.inspect}"
        end
      end

      # Raises for on_delete: :nullify on a NOT NULL column: SET NULL would
      # fail at delete time. Shared by TableDef#references and
      # Migration::Base#add_reference.
      def self.check_nullify(action, null)
        if action == :nullify && !null
          raise ArgumentError, "on_delete: :nullify needs null: true (the column is NOT NULL)"
        end
        nil
      end

      # The column a foreign key to `to_table` uses when none is given:
      # "<singular of to_table>_id" ("people" -> "person_id"). Shared by
      # Definition#add_foreign_key and Migration::Base#add_foreign_key.
      def self.default_column(to_table)
        "#{Cybertrain::Inflector.singularize(to_table.to_s)}_id"
      end
    end

    class Table
      attr_reader :name, :columns, :indexes, :foreign_keys

      def initialize(name)
        @name = name.to_s
        # Seeded with their element type per spikes/NOTES.md rule 9, so a
        # table that never gets a column/index/foreign key still compiles.
        @columns = Array.new(0) { Column.new("", :string, true, nil, 0) }
        @indexes = Array.new(0) { Index.new("", [], false) }
        @foreign_keys = Array.new(0) { ForeignKey.new("", "", "") }
        @without_id = false
      end

      # True for a table declared `create_table "x", id: false` (a join
      # table, or one a dump found with no `id INTEGER PRIMARY KEY`): its
      # DDL has no implicit id, and the generator makes no model of it.
      def without_id?
        @without_id
      end

      # Package-internal: Definition#create_table's `id: false`.
      def mark_without_id
        @without_id = true
        nil
      end

      def column(name)
        target = name.to_s
        @columns.each do |c|
          return c if c.name == target
        end
        nil
      end

      # The implicit "id" primary key is never in `columns`, so a foreign
      # key's referenced table always has its own separate "id" column --
      # `references` just reports the foreign keys this table declared.
      def references
        @foreign_keys
      end

      # Package-internal writers used by TableDef and Definition while a
      # table is being built. Not part of the task's public Interfaces.
      #
      # Each ends with an explicit `nil` rather than the implicit
      # `Array#<<` result: Migration::Base and Definition each declare their
      # own `add_column`/`add_index`/`add_foreign_key` DSL methods, and
      # Spinel infers a method's return type per name across every
      # unrelated class that defines it -- when the inferred types disagree
      # (here: Array from the push vs. whatever the DSL method returns) the
      # compiler corrupts one of them ("cannot box type N into a poly
      # value"). Giving every same-named mutator a `nil` return keeps them
      # unifiable. See spikes/NOTES.md rule 10.
      def add_column(column)
        @columns << column
        nil
      end

      def add_index(index)
        @indexes << index
        nil
      end

      def add_foreign_key(foreign_key)
        @foreign_keys << foreign_key
        nil
      end
    end

    # The `t` a `create_table` block yields.
    #
    # Every table also gets `id INTEGER PRIMARY KEY AUTOINCREMENT`; do not
    # declare it. The types are those below; there is no `time`.
    # `default:` is SQL literal text, and a new
    # record starts with it when it is a plain literal.
    # @example
    #   create_table "articles" do |t|
    #     t.string "title", null: false
    #     t.text "body"
    #     t.boolean "published", null: false, default: "false"
    #     t.references :author
    #     t.timestamps
    #   end
    # @api public
    class TableDef
      def initialize(table)
        @table = table
      end

      # A `VARCHAR` column, a String in the model.
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"'draft'"`
      # @param limit [Integer] `VARCHAR(n)` when positive
      # @return [nil]
      # @api public
      def string(name, null: true, default: nil, limit: 0)
        push_column(name, :string, null, default, limit)
      end

      # A `TEXT` column, a String in the model.
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`, `"'draft'"`,
      #   `"false"`
      # @param limit [Integer] ignored
      # @return [nil]
      # @api public
      def text(name, null: true, default: nil, limit: 0)
        push_column(name, :text, null, default, limit)
      end

      # An `INTEGER` column, an Integer in the model.
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`, `"'draft'"`,
      #   `"false"`
      # @param limit [Integer] ignored
      # @return [nil]
      # @api public
      def integer(name, null: true, default: nil, limit: 0)
        push_column(name, :integer, null, default, limit)
      end

      # A `REAL` column, a Float in the model.
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`, `"'draft'"`,
      #   `"false"`
      # @param limit [Integer] ignored
      # @return [nil]
      # @api public
      def float(name, null: true, default: nil, limit: 0)
        push_column(name, :float, null, default, limit)
      end

      # A `BOOLEAN` column (0/1), true/false in the model.
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`, `"'draft'"`,
      #   `"false"`
      # @param limit [Integer] ignored
      # @return [nil]
      # @api public
      def boolean(name, null: true, default: nil, limit: 0)
        push_column(name, :boolean, null, default, limit)
      end

      # A `DATETIME` column, a UTC Time in the model (stored as
      # `"2026-10-05T09:00:00Z"`, to the second).
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`, `"'draft'"`,
      #   `"false"`
      # @param limit [Integer] ignored
      # @param precision [Integer] accepted for Rails' `precision: 6` and
      #   ignored (Rails' `datetime(6)` reads back as a plain datetime)
      # @return [nil]
      # @api public
      def datetime(name, null: true, default: nil, limit: 0, precision: 0)
        push_column(name, :datetime, null, default, limit)
      end

      # A `DECIMAL(precision,scale)` column (`DECIMAL(precision)` without a
      # scale, plain `DECIMAL` without either), as Rails declares one.
      # @example
      #   t.decimal "price", precision: 18, scale: 8
      # @param name [String, Symbol]
      # @param precision [Integer] total digits; 0 for none
      # @param scale [Integer] digits after the point; -1 for none (a
      #   scale needs a precision: ArgumentError otherwise)
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`
      # @return [nil]
      # @api public
      def decimal(name, precision: 0, scale: -1, null: true, default: nil)
        Cybertrain::Schema::Column.check_decimal(precision, scale)
        @table.add_column(Column.new(name, :decimal, null, default, 0, precision, scale))
      end

      # A `JSON` column, as Rails declares one on SQLite (the text of the
      # document).
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"'{}'"`
      # @return [nil]
      # @api public
      def json(name, null: true, default: nil)
        push_column(name, :json, null, default, 0)
      end

      # A `BIGINT` column, an Integer in the model: an `:integer` column
      # with `limit` 8.
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`
      # @return [nil]
      # @api public
      def bigint(name, null: true, default: nil)
        push_column(name, :integer, null, default, 8)
      end

      # A `DATE` column, a String (`"2026-10-05"`) in the model.
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"0"`, `"'draft'"`,
      #   `"false"`
      # @param limit [Integer] ignored
      # @return [nil]
      # @api public
      def date(name, null: true, default: nil, limit: 0)
        push_column(name, :date, null, default, limit)
      end

      # A `BLOB` column, a String of raw bytes in the model (NUL and bytes
      # above 127 included; the model binds it as a {DB::Blob}).
      # @param name [String, Symbol]
      # @param null [Boolean] false adds NOT NULL
      # @param default [String, nil] SQL literal text: `"x''"`
      # @param limit [Integer] ignored
      # @return [nil]
      # @api public
      def binary(name, null: true, default: nil, limit: 0)
        push_column(name, :binary, null, default, limit)
      end

      # Adds "<name>_id" (Integer), an index on it, and -- unless
      # `foreign_key: false` -- a foreign key to the pluralized table name
      # ("post" -> "posts", "person" -> "people" via Cybertrain::Inflector).
      #
      # The foreign key is what gives the two models their association
      # readers (`comment.article`, `article.comments`).
      # @example
      #   t.references :article   # article_id, NOT NULL, indexed, -> articles
      # @param name [Symbol, String] the singular (`:article`)
      # @param null [Boolean] the column is NOT NULL unless true
      # @param foreign_key [Boolean]
      # @param on_delete [Symbol] what deleting the referenced row does:
      #   `:no_action` (refused while referenced), `:cascade` (deletes this
      #   row too), `:nullify` (sets the column NULL; pass `null: true`) or
      #   `:restrict`
      # @param index [Boolean] false skips the index
      # @return [nil]
      # @api public
      def references(name, null: false, foreign_key: true, on_delete: :no_action, index: true)
        Cybertrain::Schema::ForeignKey.check_on_delete(on_delete)
        Cybertrain::Schema::ForeignKey.check_nullify(on_delete, null)
        column_name = "#{name}_id"
        push_column(column_name, :integer, null, nil, 0)
        @table.add_index(Index.new(@table.name, [column_name], false)) if index
        if foreign_key
          to_table = Cybertrain::Inflector.pluralize(name.to_s)
          @table.add_foreign_key(ForeignKey.new(@table.name, column_name, to_table, on_delete))
        end
        nil
      end

      # `created_at` and `updated_at`, NOT NULL datetimes that
      # {Model#save} fills in.
      # @return [nil]
      # @api public
      def timestamps
        push_column("created_at", :datetime, false, nil, 0)
        push_column("updated_at", :datetime, false, nil, 0)
      end

      private

      def push_column(name, type, null, default, limit)
        @table.add_column(Column.new(name, type, null, default, limit))
      end
    end
  end
end
