require "cybertrain/schema"
require "cybertrain/schema/dumper"
require "cybertrain/cast"

module Cybertrain
  module DB
    # Cybertrain::DB::SchemaDumper -- introspects a live SQLite database back
    # into a Cybertrain::Schema::Definition, the reverse of SqliteDDL.
    #
    # SqliteDDL declares one SQL type name per schema type (VARCHAR, TEXT,
    # INTEGER, REAL, BOOLEAN, DATETIME, DATE) and SQLite keeps that name in
    # PRAGMA table_info, so the dump recovers :text vs :string, :boolean vs
    # :integer and :datetime/:date exactly. Unknown names (a table created
    # by hand) fall back to SQLite's own affinity rules.
    module SchemaDumper
      def self.dump(connection)
        definition = Cybertrain::Schema::Definition.new(max_version(connection))
        names = table_names(connection)
        names.each do |name|
          definition.create_table(name) { |t| add_columns(t, connection, name) }
        end
        names.each do |name|
          add_indexes(definition, connection, name)
          add_foreign_keys(definition, connection, name)
        end
        definition
      end

      def self.dump_to_ruby(connection)
        Cybertrain::Schema::Dumper.to_ruby(dump(connection))
      end

      # Every user table, excluding schema_migrations and SQLite's own
      # bookkeeping tables (sqlite_sequence, sqlite_stat*, ...).
      def self.table_names(connection)
        rows = connection.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        names = Array.new(0) { "" }
        rows.each do |r|
          name = r["name"].to_s
          next if name == "schema_migrations" || name.start_with?("sqlite_")
          names << name
        end
        names
      end

      # The highest applied migration version, or "0" when schema_migrations
      # does not exist yet (a database no Migrator has ever touched).
      def self.max_version(connection)
        exists = connection.execute(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_migrations'"
        )
        return "0" if exists.empty?
        rows = connection.execute("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1")
        rows.empty? ? "0" : rows[0]["version"].to_s
      end

      def self.add_columns(t, connection, table_name)
        rows = connection.execute("PRAGMA table_info(#{table_name})")
        rows.each do |r|
          next if Cybertrain::Cast.int(r["pk"]) != 0
          name = r["name"].to_s
          null = Cybertrain::Cast.int(r["notnull"]) == 0
          default = Cybertrain::Cast.str_or_nil(r["dflt_value"])
          declared = r["type"].to_s
          limit = type_limit(declared)
          case column_type(declared)
          when :string then t.string(name, null: null, default: default, limit: limit)
          when :text then t.text(name, null: null, default: default)
          when :integer then t.integer(name, null: null, default: default)
          when :float then t.float(name, null: null, default: default)
          when :boolean then t.boolean(name, null: null, default: default)
          when :datetime then t.datetime(name, null: null, default: default)
          when :date then t.date(name, null: null, default: default)
          else t.text(name, null: null, default: default)
          end
        end
        nil
      end

      # "VARCHAR(80)" -> :string. Exact names first (what SqliteDDL writes),
      # then SQLite's affinity rules for anything else.
      def self.column_type(declared)
        base = declared.upcase
        paren = base.index("(")
        base = base[0, paren].strip unless paren.nil?
        case base
        when "VARCHAR" then :string
        when "TEXT" then :text
        when "INTEGER", "INT", "BIGINT" then :integer
        when "REAL", "FLOAT", "DOUBLE" then :float
        when "BOOLEAN" then :boolean
        when "DATETIME", "TIMESTAMP" then :datetime
        when "DATE" then :date
        else
          if !base.index("INT").nil?
            :integer
          elsif !base.index("CHAR").nil? || !base.index("CLOB").nil?
            :string
          elsif !base.index("REAL").nil? || !base.index("FLOA").nil? || !base.index("DOUB").nil?
            :float
          else
            :text
          end
        end
      end

      # "VARCHAR(80)" -> 80; 0 when the declared type has no length.
      def self.type_limit(declared)
        open = declared.index("(")
        close = declared.index(")")
        return 0 if open.nil? || close.nil? || close < open
        declared[open + 1, close - open - 1].strip.to_i
      end

      def self.add_indexes(definition, connection, table_name)
        rows = connection.execute("PRAGMA index_list(#{table_name})")
        rows.each do |r|
          name = r["name"].to_s
          next if name.start_with?("sqlite_autoindex_")
          columns = index_columns(connection, name)
          definition.add_index(table_name, columns, unique: Cybertrain::Cast.int(r["unique"]) != 0, name: name)
        end
        nil
      end

      def self.index_columns(connection, index_name)
        rows = connection.execute("PRAGMA index_info(#{index_name})")
        ordered = rows.sort_by { |r| Cybertrain::Cast.int(r["seqno"]) }
        ordered.map { |r| r["name"].to_s }
      end

      def self.add_foreign_keys(definition, connection, table_name)
        rows = connection.execute("PRAGMA foreign_key_list(#{table_name})")
        rows.each do |r|
          definition.add_foreign_key(table_name, r["table"].to_s, column: r["from"].to_s)
        end
        nil
      end
    end
  end
end
