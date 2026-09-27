# Cybertrain::Schema::Definition -- what `Cybertrain::Schema.define do |s|
# ... end` builds: an ordered set of tables plus any indexes/foreign keys
# declared outside a `create_table` block.
require "cybertrain/generator/inflector"
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

      def create_table(name)
        table = Table.new(name)
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
      def add_index(table_name, columns, unique: false, name: "")
        cols = columns.map { |c| c.to_s }
        target = table(table_name)
        raise ArgumentError, "unknown table #{table_name.to_s}" if target.nil?
        index = Index.new(table_name, cols, unique, name)
        target.add_index(index)
        nil
      end

      # Returns nil for the same reason as `add_index` above. Raises when
      # the table is unknown, for the same reason as `add_index` above.
      def add_foreign_key(from_table, to_table, column: "")
        col = column
        col = "#{Cybertrain::Inflector.singularize(to_table.to_s)}_id" if col == ""
        target = table(from_table)
        raise ArgumentError, "unknown table #{from_table.to_s}" if target.nil?
        foreign_key = ForeignKey.new(from_table, col, to_table)
        target.add_foreign_key(foreign_key)
        nil
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
