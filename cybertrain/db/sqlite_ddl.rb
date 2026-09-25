require "cybertrain/schema"
require "cybertrain/migration"

module Cybertrain
  module DB
    # Cybertrain::DB::SqliteDDL -- turns Schema::Table/Migration::Operation
    # data into the SQL strings SQLite understands. Pure text generation:
    # nothing here touches a Connection.
    #
    # Every schema type gets its own declared SQL type name, as Rails'
    # SQLite adapter does (VARCHAR, TEXT, INTEGER, REAL, BOOLEAN, DATETIME,
    # DATE). SQLite derives the storage affinity from the name (VARCHAR ->
    # TEXT, BOOLEAN/DATETIME/DATE -> NUMERIC, which keeps ISO 8601 strings
    # as text) and remembers the name itself, so SchemaDumper can read the
    # original type back: db/schema.rb is dumped from the database and the
    # model generator types attributes from it.
    module SqliteDDL
      # Schema::Table -> the full CREATE TABLE statement, implicit "id"
      # primary key first, then declared columns, then foreign keys.
      def self.create_table(table)
        buf = +"CREATE TABLE #{table.name} (id INTEGER PRIMARY KEY AUTOINCREMENT"
        table.columns.each { |c| buf << ", " << column_def(c.name, c.type, c.null, c.default, c.limit) }
        table.foreign_keys.each { |fk| buf << ", FOREIGN KEY (#{fk.column}) REFERENCES #{fk.to_table}(id)" }
        buf << ")"
        buf
      end

      # Migration::Operation -> the Array<String> of statements it takes to
      # apply that one operation.
      def self.statements(op)
        case op.kind
        when :create_table
          create_table_statements(op)
        when :drop_table
          [drop_table_sql(op)]
        when :add_column
          [add_column_sql(op)]
        when :remove_column
          [remove_column_sql(op)]
        when :rename_column
          [rename_column_sql(op)]
        when :add_index
          [add_index_sql(op)]
        when :remove_index
          [remove_index_sql(op)]
        when :add_reference
          add_reference_statements(op)
        when :add_foreign_key
          raise Cybertrain::Migration::IrreversibleMigration,
                "SQLite cannot add a foreign key to an existing table; declare it in create_table " \
                "(or use add_reference, which adds it with the column)"
        else
          raise ArgumentError, "unknown operation kind #{op.kind}"
        end
      end

      def self.create_table_statements(op)
        stmts = Array.new(0) { "" }
        table = op.table
        case table
        when Cybertrain::Schema::Table
          stmts << create_table(table)
          table.indexes.each { |idx| stmts << index_sql(idx.table, idx.columns, idx.unique, idx.name) }
        end
        stmts
      end

      def self.drop_table_sql(op)
        "DROP TABLE #{Cybertrain::Migration::Operation.table_name(op.table)}"
      end

      def self.add_column_sql(op)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        "ALTER TABLE #{table} ADD COLUMN #{column_def(op.name, op.type, op.null, op.default, op.limit)}"
      end

      def self.remove_column_sql(op)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        "ALTER TABLE #{table} DROP COLUMN #{op.name}"
      end

      def self.rename_column_sql(op)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        "ALTER TABLE #{table} RENAME COLUMN #{op.name} TO #{op.new_name}"
      end

      def self.add_index_sql(op)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        index_sql(table, op.columns, op.unique, op.name)
      end

      def self.remove_index_sql(op)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        name = op.name == "" ? derived_index_name(table, op.columns) : op.name
        drop_index_sql(name)
      end

      # `to_table` non-empty adds the foreign key inline: SQLite cannot add a
      # constraint to an existing table, but it does accept a REFERENCES
      # clause on the column ALTER TABLE ADD COLUMN creates.
      def self.add_reference_statements(op, to_table = "")
        table = Cybertrain::Migration::Operation.table_name(op.table)
        column = add_column_sql(op)
        column = "#{column} REFERENCES #{to_table}(id)" if to_table != ""
        [column, index_sql(table, [op.name], false, "")]
      end

      # Base#add_reference (foreign_key: true, the default) records
      # :add_reference followed by :add_foreign_key for the same table and
      # column; true when `fk_op` is that follower, so the caller can emit
      # both through add_reference_statements(ref_op, fk_op.to_table).
      def self.folds_foreign_key?(ref_op, fk_op)
        return false unless ref_op.kind == :add_reference && fk_op.kind == :add_foreign_key
        ref_table = Cybertrain::Migration::Operation.table_name(ref_op.table)
        fk_table = Cybertrain::Migration::Operation.table_name(fk_op.table)
        ref_table == fk_table && ref_op.name == fk_op.name
      end

      def self.drop_index_sql(name)
        "DROP INDEX #{name}"
      end

      def self.column_def(name, type, null, default, limit)
        buf = +""
        buf << name.to_s << " " << sql_type(type)
        buf << "(#{limit})" if limit != 0 && type == :string
        buf << " NOT NULL" unless null
        buf << " DEFAULT #{default}" unless default.nil?
        buf
      end

      def self.sql_type(type)
        case type
        when :string then "VARCHAR"
        when :integer then "INTEGER"
        when :float then "REAL"
        when :boolean then "BOOLEAN"
        when :datetime then "DATETIME"
        when :date then "DATE"
        else "TEXT"
        end
      end

      def self.index_sql(table, columns, unique, name)
        index_name = name == "" ? derived_index_name(table, columns) : name
        kind = unique ? "CREATE UNIQUE INDEX" : "CREATE INDEX"
        "#{kind} #{index_name} ON #{table}(#{columns.join(", ")})"
      end

      def self.derived_index_name(table, columns)
        "index_#{table}_on_#{columns.join("_and_")}"
      end
    end
  end
end
