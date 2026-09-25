# Cybertrain::Schema::Dumper -- renders a Definition back into the
# `db/schema.rb` Ruby source, in the same spirit as Rails' schema dumper.
# Tables and their columns are emitted in definition order (Definition
# already keeps `tables` sorted by name, and `create_table` keeps columns in
# the order they were declared); indexes and foreign keys are gathered
# across every table and sorted for a deterministic dump.
require "cybertrain/schema/table"
require "cybertrain/schema/definition"

module Cybertrain
  module Schema
    module Dumper
      def self.to_ruby(definition)
        buf = +""
        buf << "Cybertrain::Schema.define(version: \"#{definition.version}\") do |s|\n"
        definition.tables.each do |table|
          buf << table_block(table)
        end

        indexes = collect_indexes(definition)
        indexes.each do |index|
          buf << "  s.add_index \"#{index.table}\", #{array_literal(index.columns)}#{index_options(index)}\n"
        end
        buf << "\n" unless indexes.empty?

        foreign_keys = collect_foreign_keys(definition)
        foreign_keys.each do |fk|
          buf << "  s.add_foreign_key \"#{fk.from_table}\", \"#{fk.to_table}\", column: \"#{fk.column}\"\n"
        end

        buf << "end\n"
        buf
      end

      def self.table_block(table)
        buf = +""
        buf << "  s.create_table \"#{table.name}\" do |t|\n"
        table.columns.each do |c|
          buf << "    t.#{c.type} \"#{c.name}\"#{column_options(c)}\n"
        end
        buf << "  end\n\n"
        buf
      end

      def self.column_options(c)
        opts = +""
        opts << ", null: false" unless c.null
        opts << ", default: \"#{escape_string_literal(c.default)}\"" unless c.default.nil?
        opts << ", limit: #{c.limit}" if c.limit != 0
        opts
      end

      # Escapes a value for embedding inside a double-quoted Ruby string
      # literal in the dumped source: a default containing `\`, `"` or `#`
      # (which could otherwise start a `#{...}` interpolation) would
      # produce invalid or injected Ruby in db/schema.rb.
      def self.escape_string_literal(s)
        out = +""
        s.to_s.each_char do |ch|
          case ch
          when "\\"
            out << "\\\\"
          when "\""
            out << "\\\""
          when "#"
            out << "\\#"
          else
            out << ch
          end
        end
        out
      end

      def self.index_options(i)
        opts = +""
        opts << ", unique: true" if i.unique
        opts << ", name: \"#{i.name}\""
        opts
      end

      def self.array_literal(strings)
        parts = []
        strings.each { |s| parts << "\"#{s}\"" }
        "[#{parts.join(", ")}]"
      end

      def self.collect_indexes(definition)
        all = []
        definition.tables.each do |t|
          t.indexes.each { |i| all << i }
        end
        all.sort_by { |i| i.name }
      end

      def self.collect_foreign_keys(definition)
        all = []
        definition.tables.each do |t|
          t.foreign_keys.each { |fk| all << fk }
        end
        all.sort_by { |fk| "#{fk.from_table}_#{fk.column}" }
      end
    end
  end
end
