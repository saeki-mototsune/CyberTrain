require "cybertrain/schema"
require "cybertrain/migration"

module Cybertrain
  module DB
    # Cybertrain::DB::DDLText -- the DDL pieces that are the same on every
    # adapter: SqliteDDL (cybertrain/db/sqlite_ddl.rb) and MySQL::DDL
    # (cybertrain/db/mysql/ddl.rb) both call them, so neither adapter's
    # program carries the other's DDL. Pure text and in-memory schema:
    # nothing here touches a Connection.
    module DDLText
      # A copy of `table` with the rebuild operation `op` applied: a
      # changed column (change_column, change_column_default,
      # change_column_null), a dropped reference column with its indexes
      # and foreign keys (remove_reference), a dropped foreign key
      # (remove_foreign_key). `table` itself is left as it was. Raises
      # ArgumentError when the column or the foreign key does not exist.
      def self.table_after(table, op)
        result = Cybertrain::Schema::Table.new(table.name)
        result.mark_without_id if table.without_id?
        found = false
        table.columns.each do |c|
          if c.name != op.name
            result.add_column(c)
          else
            found = true
            case op.kind
            when :change_column
              result.add_column(Cybertrain::Schema::Column.new(c.name, op.type, op.null, op.default, op.limit, op.precision, op.scale))
            when :change_column_default
              result.add_column(Cybertrain::Schema::Column.new(c.name, c.type, c.null, op.default, c.limit, c.precision, c.scale))
            when :change_column_null
              result.add_column(Cybertrain::Schema::Column.new(c.name, c.type, op.null, c.default, c.limit, c.precision, c.scale))
            when :remove_reference
              nil
            else
              result.add_column(c)
            end
          end
        end
        unless found || op.kind == :remove_foreign_key
          message = "#{op.kind}: no column #{table.name}.#{op.name}"
          raise ArgumentError, message
        end
        table.indexes.each do |idx|
          result.add_index(idx) unless op.kind == :remove_reference && idx.columns.include?(op.name)
        end
        removed = false
        table.foreign_keys.each do |fk|
          drop = false
          drop = true if op.kind == :remove_reference && fk.column == op.name
          drop = true if op.kind == :remove_foreign_key && fk.column == op.name && fk.to_table == op.to_table
          if drop
            removed = true
          else
            result.add_foreign_key(fk)
          end
        end
        if op.kind == :remove_foreign_key && !removed
          message = "remove_foreign_key: no foreign key from #{table.name}.#{op.name} to #{op.to_table}"
          raise ArgumentError, message
        end
        result
      end

      # The ON DELETE clause for a foreign key's action, with its leading
      # space; "" for :no_action (the default of SQLite and MySQL alike).
      def self.on_delete_clause(action)
        case action
        when :cascade then " ON DELETE CASCADE"
        when :nullify then " ON DELETE SET NULL"
        when :restrict then " ON DELETE RESTRICT"
        else ""
        end
      end
    end
  end
end
