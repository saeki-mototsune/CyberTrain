# Cybertrain::Schema::{Column,Index,ForeignKey,Table,TableDef} -- the plain
# data objects a schema is made of, plus the `t` builder that `create_table`
# yields. Everything here is pure in-memory data: no database, no SQL
# generation (that belongs to cybertrain/db/sqlite_ddl.rb).
require "cybertrain/generator/inflector"

module Cybertrain
  module Schema
    class Column
      attr_reader :name, :type, :null, :default, :limit

      # type: Symbol (:string, :text, :integer, :float, :boolean, :datetime,
      # :date). default: String|nil holding the SQL literal text exactly as
      # written in the DSL (e.g. "0", "'x'", "false"), never a Ruby value.
      def initialize(name, type, null, default, limit)
        @name = name.to_s
        @type = type
        @null = null
        @default = default
        @limit = limit
      end
    end

    class Index
      attr_reader :table, :columns, :unique, :name

      # `name` overrides the derived "index_<table>_on_<cols>" name when
      # non-empty; this is what lets the exact text Dumper.to_ruby prints
      # (which always includes `name:`, since the name is deterministic)
      # round-trip through Definition#add_index without ever landing on a
      # name that disagrees with the derived one.
      def initialize(table, columns, unique, name = "")
        @table = table.to_s
        @columns = columns
        @unique = unique
        derived = "index_#{@table}_on_#{@columns.join("_and_")}"
        @name = name == "" ? derived : name
      end
    end

    class ForeignKey
      attr_reader :from_table, :column, :to_table

      def initialize(from_table, column, to_table)
        @from_table = from_table.to_s
        @column = column.to_s
        @to_table = to_table.to_s
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
    # declare it. The types are those below; there is no `decimal`, `bigint`,
    # `json`, `binary` or `time`. `default:` is SQL literal text, and a new
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
      # @return [nil]
      # @api public
      def datetime(name, null: true, default: nil, limit: 0)
        push_column(name, :datetime, null, default, limit)
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
      # @return [nil]
      # @api public
      def references(name, null: false, foreign_key: true)
        column_name = "#{name}_id"
        push_column(column_name, :integer, null, nil, 0)
        @table.add_index(Index.new(@table.name, [column_name], false))
        if foreign_key
          to_table = Cybertrain::Inflector.pluralize(name.to_s)
          @table.add_foreign_key(ForeignKey.new(@table.name, column_name, to_table))
        end
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
