# Cybertrain::Schema::Definition -- what `Cybertrain::Schema.define do |s|
# ... end` builds: an ordered set of tables plus any indexes/foreign keys
# declared outside a `create_table` block.
require "cybertrain/schema/table"

module Cybertrain
  module Schema
    class Definition
      attr_reader :tables, :version

      def initialize(version)
        @version = version.to_s
        # Seeded with its element type per spikes/NOTES.md rule 9, so a
        # schema with no tables still compiles.
        @tables = Array.new(0) { Table.new("") }
      end

      # `id: false` declares a table with no implicit `id` primary key (a
      # join table): SqliteDDL writes none, and the generator makes no model.
      def create_table(name, id: true)
        table = Table.new(name)
        table.mark_without_id unless id
        yield TableDef.new(table)
        @tables << table
        resort_tables!
        table
      end

      # Returns nil, not the created Index: Migration::Base declares its own
      # `add_index`, and Spinel unifies a method's inferred return type
      # across every unrelated class that defines the same name, so the two
      # must agree. See spikes/NOTES.md rule 10 and the note on
      # Cybertrain::Schema::Table's writers.
      #
      # `name:` overrides the derived index name; it exists so the exact
      # text Dumper.to_ruby prints (which always includes `name:`) loads
      # back through this same method. Raises when the table is unknown --
      # a typo in db/schema.rb must be loud, not a silently dropped index.
      #
      # `columns` is an Array of column names, or a String holding an
      # expression index's key (`"LOWER(email)"`), which needs `name:`.
      # `where:` makes it a partial index (`"deleted_at IS NULL"`).
      def add_index(table_name, columns, unique: false, name: "", where: "")
        cols = Array.new(0) { "" }
        expression = ""
        case columns
        when String
          expression = columns.to_s
        when Array
          columns.each { |c| cols << c.to_s }
        end
        target = table(table_name)
        raise ArgumentError, "unknown table #{table_name.to_s}" if target.nil?
        if expression != "" && name.to_s == ""
          raise ArgumentError, "an expression index on #{table_name.to_s} needs name:"
        end
        index = Index.new(table_name, cols, unique, name.to_s, where.to_s, expression)
        target.add_index(index)
        nil
      end

      # Returns nil for the same reason as `add_index` above. Raises when
      # the table is unknown, for the same reason as `add_index` above.
      # `on_delete:` is :no_action, :cascade, :nullify or :restrict.
      def add_foreign_key(from_table, to_table, column: "", on_delete: :no_action)
        Cybertrain::Schema::ForeignKey.check_on_delete(on_delete)
        col = column
        col = Cybertrain::Schema::ForeignKey.default_column(to_table) if col == ""
        target = table(from_table)
        raise ArgumentError, "unknown table #{from_table.to_s}" if target.nil?
        foreign_key = ForeignKey.new(from_table, col, to_table, on_delete)
        target.add_foreign_key(foreign_key)
        nil
      end

      # Swaps in `table` for the table of the same name (the Migrator's
      # in-memory picture of a rebuild). Raises when there is none.
      def replace_table(table)
        i = 0
        while i < @tables.size
          if @tables[i].name == table.name
            @tables[i] = table
            return nil
          end
          i += 1
        end
        message = "unknown table #{table.name}"
        raise ArgumentError, message
      end

      def table(name)
        target = name.to_s
        @tables.each do |t|
          return t if t.name == target
        end
        nil
      end

      private

      def resort_tables!
        @tables = @tables.sort_by { |t| t.name }
      end
    end
  end
end
