# Shared by the framework tests that load the fixture application's models
# into an in-memory database (each one
# `require_relative "support/schema_tables"`). Not a test program itself:
# script/gate and script/test-shard read test/*.rb only.
#
# CREATE TABLE statements for a schema definition (Cybertrain::Schema.current),
# so that the database always matches what the models were generated from.
# The declared types are deliberately plainer than the framework's own DDL
# (Cybertrain::DB::SqliteDDL): INTEGER for a boolean, TEXT for a time.
module SchemaTables
  def self.sql_type(column)
    case column.type
    when :integer, :boolean then "INTEGER"
    when :float then "REAL"
    when :decimal then "DECIMAL"
    else "TEXT"
    end
  end

  # One statement per table, with its FOREIGN KEY constraints, in one
  # String for exec_script.
  def self.create_sql(definition)
    sql = +""
    definition.tables.each do |table|
      parts = ["id INTEGER PRIMARY KEY AUTOINCREMENT"]
      table.columns.each do |c|
        part = +"\"#{c.name}\" #{SchemaTables.sql_type(c)}"
        part << " NOT NULL" unless c.null
        default = c.default
        part << " DEFAULT #{default}" unless default.nil?
        parts << part
      end
      table.foreign_keys.each do |fk|
        parts << "FOREIGN KEY (\"#{fk.column}\") REFERENCES \"#{fk.to_table}\"(id)"
      end
      sql << "CREATE TABLE \"#{table.name}\" (#{parts.join(", ")});"
    end
    sql
  end
end
