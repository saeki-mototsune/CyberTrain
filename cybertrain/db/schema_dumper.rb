require "cybertrain/schema"
require "cybertrain/schema/dumper"
require "cybertrain/cast"

module Cybertrain
  module DB
    # Cybertrain::DB::SchemaDumper -- introspects a live SQLite database back
    # into a Cybertrain::Schema::Definition, the reverse of SqliteDDL.
    #
    # SqliteDDL declares one SQL type name per schema type (VARCHAR, TEXT,
    # INTEGER, BIGINT, REAL, DECIMAL, BOOLEAN, DATETIME, DATE, BLOB, JSON) and
    # SQLite keeps that name in PRAGMA table_info, so the dump recovers :text
    # vs :string, :boolean vs :integer, :datetime/:date, :decimal, :json and
    # :binary exactly. Rails' SQLite adapter writes the same names in lower
    # case (`decimal(18,8)`, `json`, `bigint`, `datetime(6)`), so a database
    # Rails created dumps the same way. Unknown names (a table created by
    # hand) fall back to SQLite's own affinity rules.
    module SchemaDumper
      def self.dump(connection)
        definition = Cybertrain::Schema::Definition.new(max_version(connection))
        names = table_names(connection)
        names.each do |name|
          with_id = id_primary_key?(connection, name)
          definition.create_table(name, id: with_id) { |t| add_columns(t, connection, name, with_id) }
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

      # Every user table, excluding schema_migrations and Rails'
      # ar_internal_metadata, the framework's own
      # cybertrain_jobs, cybertrain_leases, cybertrain_messages,
      # cybertrain_schedules, cybertrain_cache and cybertrain_feeds (Job,
      # Lease, Stream, Scheduler::Timetable, Cache and WebSocket::FeedTable
      # create them at run time; in
      # db/schema.rb the generator would make models of them) and SQLite's
      # bookkeeping tables (sqlite_sequence, sqlite_stat*, ...).
      def self.table_names(connection)
        rows = connection.execute("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        names = Array.new(0) { "" }
        rows.each do |r|
          name = r["name"].to_s
          next if name == "schema_migrations" || name == "ar_internal_metadata" || name.start_with?("sqlite_")
          next if name == "cybertrain_jobs" || name == "cybertrain_leases" || name == "cybertrain_messages"
          next if name == "cybertrain_schedules" || name == "cybertrain_cache" || name == "cybertrain_feeds"
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

      # Whether the table's primary key is an integer column named id (any
      # case), as every table the framework (or Rails, by default) creates
      # has: its declared type has INTEGER affinity (contains INT: integer,
      # bigint). A table without one -- a Rails join table, or Rails'
      # `id: :uuid` / `id: :string` (a varchar id, which a model reading
      # ids as Integers would save to no row) -- is dumped as
      # `create_table "x", id: false`, with every column; the PRIMARY KEY
      # of a kept column is not recorded.
      def self.id_primary_key?(connection, table_name)
        rows = connection.execute("PRAGMA table_info(#{table_name})")
        rows.each do |r|
          next unless Cybertrain::Cast.int(r["pk"]) != 0 && r["name"].to_s.downcase == "id"

          return r["type"].to_s.upcase.include?("INT")
        end
        false
      end

      # The declared columns; the primary key is left out when it is the
      # implicit id (with_id), and kept as a plain column otherwise.
      def self.add_columns(t, connection, table_name, with_id = true)
        rows = connection.execute("PRAGMA table_info(#{table_name})")
        rows.each do |r|
          next if with_id && Cybertrain::Cast.int(r["pk"]) != 0
          name = r["name"].to_s
          null = Cybertrain::Cast.int(r["notnull"]) == 0
          default = Cybertrain::Cast.str_or_nil(r["dflt_value"])
          default = default_sql(default.to_s) unless default.nil?
          declared = r["type"].to_s
          limit = type_limit(declared)
          case column_type(declared)
          when :string then t.string(name, null: null, default: default, limit: limit)
          when :text then t.text(name, null: null, default: default)
          when :integer
            if bigint_decl?(declared)
              t.bigint(name, null: null, default: default)
            else
              t.integer(name, null: null, default: default)
            end
          when :float then t.float(name, null: null, default: default)
          when :decimal
            t.decimal(name, precision: decimal_precision(declared), scale: decimal_scale(declared),
                            null: null, default: default)
          when :json then t.json(name, null: null, default: default)
          when :boolean then t.boolean(name, null: null, default: default)
          when :datetime then t.datetime(name, null: null, default: default)
          when :date then t.date(name, null: null, default: default)
          when :binary then t.binary(name, null: null, default: default)
          else t.text(name, null: null, default: default)
          end
        end
        nil
      end

      # A column default as DDL can declare it again. PRAGMA table_info
      # reports an expression default without the parentheses it was
      # declared in (`DEFAULT (datetime('now'))`, as Rails writes one, reads
      # as `datetime('now')`), and `DEFAULT datetime('now')` is a syntax
      # error, so anything but a plain literal -- a number, a '...' string,
      # an X'...' blob, NULL, TRUE / FALSE, CURRENT_TIME / CURRENT_DATE /
      # CURRENT_TIMESTAMP -- gets them back.
      def self.default_sql(text)
        s = text.to_s.strip
        return s if plain_literal?(s)
        "(#{s})"
      end

      def self.plain_literal?(text)
        s = text.to_s
        case s.upcase
        when "NULL", "TRUE", "FALSE", "CURRENT_TIME", "CURRENT_DATE", "CURRENT_TIMESTAMP"
          return true
        end
        return number_literal?(s) unless s.start_with?("'") || s.upcase.start_with?("X'")
        sql_string_literal?(s.upcase.start_with?("X'") ? s.byteslice(1, s.bytesize - 1) : s)
      end

      # One '...' literal and nothing after it ('' inside is a quote).
      def self.sql_string_literal?(text)
        s = text.to_s
        n = s.bytesize
        return false if n < 2 || s.getbyte(0) != 39
        i = 1
        while i < n
          if s.getbyte(i) == 39
            return true if i == n - 1
            return false if s.getbyte(i + 1) != 39
            i += 2
          else
            i += 1
          end
        end
        false
      end

      # [+-]digits[.digits][e[+-]digits], or [+-].digits[...].
      def self.number_literal?(text)
        s = text.to_s
        n = s.bytesize
        i = 0
        i += 1 if i < n && (s.getbyte(i) == 43 || s.getbyte(i) == 45)
        digits = 0
        while i < n && s.getbyte(i) >= 48 && s.getbyte(i) <= 57
          i += 1
          digits += 1
        end
        if i < n && s.getbyte(i) == 46
          i += 1
          while i < n && s.getbyte(i) >= 48 && s.getbyte(i) <= 57
            i += 1
            digits += 1
          end
        end
        return false if digits == 0
        if i < n && (s.getbyte(i) == 101 || s.getbyte(i) == 69)
          i += 1
          i += 1 if i < n && (s.getbyte(i) == 43 || s.getbyte(i) == 45)
          exponent = 0
          while i < n && s.getbyte(i) >= 48 && s.getbyte(i) <= 57
            i += 1
            exponent += 1
          end
          return false if exponent == 0
        end
        i == n
      end

      # "VARCHAR(80)" -> :string. Exact names first (what SqliteDDL writes),
      # then SQLite's affinity rules for anything else. "DATETIME(6)" is a
      # plain :datetime (its precision is dropped; Connection reads any
      # DATETIME(N) back as a Time).
      def self.column_type(declared)
        base = declared.upcase
        paren = base.index("(")
        base = base[0, paren].strip unless paren.nil?
        case base
        when "VARCHAR" then :string
        when "TEXT" then :text
        when "INTEGER", "INT", "BIGINT" then :integer
        when "REAL", "FLOAT", "DOUBLE" then :float
        when "DECIMAL", "NUMERIC" then :decimal
        when "JSON" then :json
        when "BOOLEAN" then :boolean
        when "DATETIME", "TIMESTAMP" then :datetime
        when "DATE" then :date
        when "BLOB" then :binary
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
        type_params(declared).to_i
      end

      # The text between a declared type's parentheses ("18,8" for
      # "decimal(18,8)"), "" when it has none.
      def self.type_params(declared)
        open = declared.index("(")
        close = declared.index(")")
        return "" if open.nil? || close.nil? || close < open
        declared[open + 1, close - open - 1].strip
      end

      # "BIGINT" (Rails' `bigint`) is an :integer with limit 8.
      def self.bigint_decl?(declared)
        base = declared.upcase.strip
        base == "BIGINT" || base.start_with?("BIGINT(")
      end

      # "decimal(18,8)" -> 18; 0 when there is no precision.
      def self.decimal_precision(declared)
        params = type_params(declared)
        comma = params.index(",")
        return params.to_i if comma.nil?
        params[0, comma].strip.to_i
      end

      # "decimal(18,8)" -> 8; -1 when there is no scale.
      def self.decimal_scale(declared)
        params = type_params(declared)
        comma = params.index(",")
        return -1 if comma.nil?
        params[comma + 1, params.size - comma - 1].strip.to_i
      end

      # A plain index's columns come from PRAGMA index_info; its CREATE
      # INDEX text in sqlite_master gives the rest: the key, when it is not
      # a list of column names, is an expression index's expression, and a
      # WHERE after it a partial index's predicate.
      def self.add_indexes(definition, connection, table_name)
        rows = connection.execute("PRAGMA index_list(#{table_name})")
        rows.each do |r|
          name = r["name"].to_s
          next if name.start_with?("sqlite_autoindex_")
          unique = Cybertrain::Cast.int(r["unique"]) != 0
          parts = index_key_and_where(index_sql_text(connection, name))
          if parts[0] == "" || column_list?(parts[0])
            columns = index_columns(connection, name)
            definition.add_index(table_name, columns, unique: unique, name: name, where: parts[1])
          else
            definition.add_index(table_name, parts[0], unique: unique, name: name, where: parts[1])
          end
        end
        nil
      end

      def self.index_sql_text(connection, index_name)
        rows = connection.execute("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?", [index_name])
        return "" if rows.empty?
        Cybertrain::Cast.str_or_nil(rows[0]["sql"]).to_s
      end

      # CREATE INDEX text -> [key, where]: the text between the first "("
      # after " ON " and its matching ")", and the predicate after a WHERE
      # that follows it ("" when there is none). Quoted text ('...', "...",
      # `...`, [...]) is skipped, so a parenthesis inside a string literal
      # or a quoted name does not count. Byte-level on a `to_s` local
      # (spikes/NOTES.md rule 62). ["", ""] when the text has no key.
      def self.index_key_and_where(text)
        s = text.to_s
        n = s.bytesize
        i = 0
        quote = 0
        depth = 0
        open = -1
        close = -1
        seen_on = false
        while i < n
          b = s.getbyte(i)
          if quote != 0
            quote = 0 if b == quote
          elsif b == 39 || b == 34 || b == 96
            quote = b
          elsif b == 91
            quote = 93
          elsif open < 0
            seen_on = true if !seen_on && b == 32 && s.byteslice(i, 4).upcase == " ON "
            if seen_on && b == 40
              open = i
              depth = 1
            end
          elsif b == 40
            depth += 1
          elsif b == 41
            depth -= 1
            if depth == 0
              close = i
              break
            end
          end
          i += 1
        end
        return ["", ""] if close < 0
        key = s.byteslice(open + 1, close - open - 1).strip
        rest = s.byteslice(close + 1, n - close - 1).strip
        where = ""
        where = rest.byteslice(5, rest.bytesize - 5).strip if rest.upcase.start_with?("WHERE")
        [key, where]
      end

      # True when an index key is a comma list of column names, bare or
      # quoted ("views", `views`, [views], views); anything else (a call,
      # an operator, a COLLATE or DESC) makes it an expression.
      def self.column_list?(key)
        parts = key.to_s.split(",")
        return false if parts.empty?
        parts.each do |part|
          return false unless identifier?(part.strip)
        end
        true
      end

      def self.identifier?(text)
        s = text.to_s
        n = s.bytesize
        return false if n == 0
        first = s.getbyte(0)
        last = s.getbyte(n - 1)
        quoted = (first == 34 && last == 34) || (first == 96 && last == 96) || (first == 91 && last == 93)
        if quoted
          return false if n < 3
          i = 1
          while i < n - 1
            b = s.getbyte(i)
            return false if b == first || b == last
            i += 1
          end
          return true
        end
        i = 0
        while i < n
          b = s.getbyte(i)
          letter = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
          digit = b >= 48 && b <= 57
          return false unless letter || (digit && i > 0)
          i += 1
        end
        true
      end

      def self.index_columns(connection, index_name)
        rows = connection.execute("PRAGMA index_info(#{index_name})")
        ordered = rows.sort_by { |r| Cybertrain::Cast.int(r["seqno"]) }
        ordered.map { |r| r["name"].to_s }
      end

      def self.add_foreign_keys(definition, connection, table_name)
        rows = connection.execute("PRAGMA foreign_key_list(#{table_name})")
        rows.each do |r|
          definition.add_foreign_key(table_name, r["table"].to_s, column: r["from"].to_s,
                                                                  on_delete: on_delete_action(r["on_delete"].to_s))
        end
        nil
      end

      # PRAGMA foreign_key_list's on_delete text -> the ForeignKey Symbol.
      # SET DEFAULT has no Symbol (the DSL does not support it) and reads
      # as :no_action, like NO ACTION itself.
      def self.on_delete_action(text)
        case text.upcase
        when "CASCADE" then :cascade
        when "SET NULL" then :nullify
        when "RESTRICT" then :restrict
        else :no_action
        end
      end
    end
  end
end
