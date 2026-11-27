require "cybertrain/cast"

module Cybertrain
  module DB
    module MySQL
      # Cybertrain::DB::MySQL::SchemaReader -- the live schema read from
      # information_schema in the shape SQLite's PRAGMAs answer it, for the
      # DB::Dialect schema readers (SchemaDumper, the Migrator). The point
      # is that SchemaDumper turns the same migrations into the same
      # db/schema.rb on both adapters, so the column type and default are
      # given as SqliteDDL declares them:
      #
      # - type: VARCHAR for varchar(255) (MySQL's VARCHAR without a limit),
      #   VARCHAR(n) otherwise; TEXT for every text type; BOOLEAN for
      #   tinyint(1); INTEGER for int, and for a bigint whose name ends in
      #   `_id` (a reference: MySQL::DDL); BIGINT for any other bigint;
      #   REAL for double and float; DECIMAL for decimal(10,0) (MySQL's
      #   DECIMAL without a precision); DATETIME for datetime(N); BLOB for
      #   every blob type; any other type as MySQL spells it, upper case
      #   (DECIMAL(18,8), JSON, DATE, SMALLINT, ...);
      # - dflt_value: NULL for none; false / true for a boolean's 0 / 1; a
      #   quoted '...' literal for a string, date or time type (MySQL keeps
      #   the bare text); an expression default (DEFAULT_GENERATED) as
      #   MySQL spells it; any other as it is (a number).
      module SchemaReader
        STRING_TYPES = "'char', 'varchar', 'tinytext', 'text', 'mediumtext', 'longtext', " \
                       "'date', 'datetime', 'timestamp', 'time', 'year', 'enum', 'set'"

        COLUMN_TYPE = "CASE " \
                      "WHEN c.data_type = 'varchar' AND c.character_maximum_length = 255 THEN 'VARCHAR' " \
                      "WHEN c.data_type = 'varchar' THEN CONCAT('VARCHAR(', c.character_maximum_length, ')') " \
                      "WHEN c.data_type IN ('tinytext', 'text', 'mediumtext', 'longtext') THEN 'TEXT' " \
                      "WHEN c.column_type = 'tinyint(1)' THEN 'BOOLEAN' " \
                      "WHEN c.column_type = 'int' THEN 'INTEGER' " \
                      "WHEN c.column_type = 'bigint' AND RIGHT(c.column_name, 3) = '_id' THEN 'INTEGER' " \
                      "WHEN c.column_type = 'bigint' THEN 'BIGINT' " \
                      "WHEN c.data_type IN ('double', 'float') THEN 'REAL' " \
                      "WHEN c.column_type = 'decimal(10,0)' THEN 'DECIMAL' " \
                      "WHEN c.data_type = 'datetime' THEN 'DATETIME' " \
                      "WHEN c.data_type IN ('tinyblob', 'blob', 'mediumblob', 'longblob') THEN 'BLOB' " \
                      "ELSE UPPER(c.column_type) END"

        COLUMN_DEFAULT = "CASE " \
                         "WHEN c.column_default IS NULL THEN NULL " \
                         "WHEN c.extra LIKE '%DEFAULT_GENERATED%' THEN c.column_default " \
                         "WHEN c.column_type = 'tinyint(1)' AND c.column_default = '0' THEN 'false' " \
                         "WHEN c.column_type = 'tinyint(1)' AND c.column_default = '1' THEN 'true' " \
                         "WHEN c.data_type IN (#{STRING_TYPES}) " \
                         "THEN CONCAT('''', REPLACE(c.column_default, '''', ''''''), '''') " \
                         "ELSE c.column_default END"

        COLUMNS_SQL = "SELECT c.column_name AS name, #{COLUMN_TYPE} AS type, " \
                      "IF(c.is_nullable = 'NO', 1, 0) AS notnull, #{COLUMN_DEFAULT} AS dflt_value, " \
                      "COALESCE((SELECT k.ordinal_position FROM information_schema.key_column_usage k " \
                      "WHERE k.table_schema = c.table_schema AND k.table_name = c.table_name " \
                      "AND k.column_name = c.column_name AND k.constraint_name = 'PRIMARY'), 0) AS pk " \
                      "FROM information_schema.columns c WHERE c.table_schema = DATABASE() AND c.table_name = ? " \
                      "ORDER BY c.ordinal_position"

        # The table's columns (see the module notes), one row each in
        # declaration order: "name", "type", "notnull" (0/1), "dflt_value"
        # and "pk" (0, or the column's place in the primary key).
        # @param conn [Cybertrain::DB::Connection]
        # @param table [String]
        # @return [Array<Hash{String => Object}>]
        def self.column_rows(conn, table)
          conn.execute(COLUMNS_SQL, [table])
        end

        # A CREATE INDEX text for an index with an expression among its key
        # parts (MySQL's functional key parts), "CREATE INDEX `name` ON
        # `table` (<part>, ...)" with each part its expression, in
        # parentheses as MySQL declares one, or its quoted column, so that
        # SchemaDumper reads it as an expression index (whose key
        # MySQL::DDL declares again as it is); ""
        # for an index of columns only, which the dumper reads by its
        # columns.
        # @param conn [Cybertrain::DB::Connection]
        # @param table [String]
        # @param index [String]
        # @return [String]
        def self.expression_index_sql(conn, table, index)
          rows = conn.execute("SELECT column_name AS name, expression AS expr FROM information_schema.statistics " \
                              "WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ? " \
                              "ORDER BY seq_in_index", [table, index])
          parts = Array.new(0) { "" }
          expressions = 0
          rows.each do |r|
            expr = Cybertrain::Cast.str_or_nil(r["expr"])
            if expr.nil?
              parts << Cybertrain::DB::Dialect.quote_ident(Cybertrain::Cast.str(r["name"]))
            else
              parts << "(#{expr})"
              expressions += 1
            end
          end
          return "" if expressions == 0

          "CREATE INDEX #{Cybertrain::DB::Dialect.quote_ident(index)} ON " \
            "#{Cybertrain::DB::Dialect.quote_ident(table)} (#{parts.join(", ")})"
        end
      end
    end
  end
end