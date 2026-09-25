# Cybertrain::Schema::{Column,Index,ForeignKey,Table,TableDef} -- the plain
# data objects a schema is made of, plus the `t` builder that `create_table`
# yields. Everything here is pure in-memory data: no database, no SQL
# generation (that belongs to the SQLite adapter, Wave M2b).
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
    class TableDef
      def initialize(table)
        @table = table
      end

      def string(name, null: true, default: nil, limit: 0)
        push_column(name, :string, null, default, limit)
      end

      def text(name, null: true, default: nil, limit: 0)
        push_column(name, :text, null, default, limit)
      end

      def integer(name, null: true, default: nil, limit: 0)
        push_column(name, :integer, null, default, limit)
      end

      def float(name, null: true, default: nil, limit: 0)
        push_column(name, :float, null, default, limit)
      end

      def boolean(name, null: true, default: nil, limit: 0)
        push_column(name, :boolean, null, default, limit)
      end

      def datetime(name, null: true, default: nil, limit: 0)
        push_column(name, :datetime, null, default, limit)
      end

      def date(name, null: true, default: nil, limit: 0)
        push_column(name, :date, null, default, limit)
      end

      # Adds "<name>_id" (Integer), an index on it, and -- unless
      # `foreign_key: false` -- a foreign key to the pluralized table name
      # ("post" -> "posts"). Task 8's Inflector will replace
      # Cybertrain::Schema's minimal pluralize once it lands.
      def references(name, null: false, foreign_key: true)
        column_name = "#{name}_id"
        push_column(column_name, :integer, null, nil, 0)
        @table.add_index(Index.new(@table.name, [column_name], false))
        if foreign_key
          to_table = Cybertrain::Schema.pluralize(name.to_s)
          @table.add_foreign_key(ForeignKey.new(@table.name, column_name, to_table))
        end
      end

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
