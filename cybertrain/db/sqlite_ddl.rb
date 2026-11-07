require "cybertrain/schema"
require "cybertrain/migration"

module Cybertrain
  module DB
    # Cybertrain::DB::SqliteDDL -- turns Schema::Table/Migration::Operation
    # data into the SQL strings SQLite understands. Pure text generation:
    # nothing here touches a Connection.
    #
    # Every schema type gets its own declared SQL type name, as Rails'
    # SQLite adapter does (VARCHAR, TEXT, INTEGER, BIGINT, REAL, DECIMAL,
    # BOOLEAN, DATETIME, DATE, BLOB, JSON). SQLite derives the storage
    # affinity from the name (VARCHAR -> TEXT, BOOLEAN/DATETIME/DATE/DECIMAL/
    # JSON -> NUMERIC, which keeps ISO 8601 strings and JSON documents as
    # text) and remembers the name itself, so SchemaDumper can read the
    # original type back: db/schema.rb is dumped from the database and the
    # model generator types attributes from it.
    module SqliteDDL
      # Schema::Table -> the full CREATE TABLE statement, implicit "id"
      # primary key first (none for an `id: false` table), then declared
      # columns, then foreign keys. `name`
      # replaces the table's own name (rebuild_table's "<table>_new").
      def self.create_table(table, name = "")
        table_name = name == "" ? table.name : name
        parts = Array.new(0) { "" }
        parts << "id INTEGER PRIMARY KEY AUTOINCREMENT" unless table.without_id?
        table.columns.each do |c|
          parts << column_def(c.name, c.type, c.null, c.default, c.limit, c.precision, c.scale)
        end
        table.foreign_keys.each do |fk|
          parts << "FOREIGN KEY (#{fk.column}) REFERENCES #{fk.to_table}(id)" + on_delete_clause(fk.on_delete)
        end
        buf = +"CREATE TABLE #{table_name} ("
        buf << parts.join(", ")
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
        when :rename_table
          ["ALTER TABLE #{Cybertrain::Migration::Operation.table_name(op.table)} RENAME TO #{op.new_name}"]
        when :change_column, :change_column_default, :change_column_null, :remove_reference, :remove_foreign_key
          message = "#{op.kind} rebuilds the table from the live schema (SqliteDDL.rebuild_table)"
          raise ArgumentError, message
        else
          raise ArgumentError, "unknown operation kind #{op.kind}"
        end
      end

      # SQLite's procedure for a change ALTER TABLE cannot make: the
      # statements that rebuild `table_name` as `definition_after` declares
      # it. `<table>_new` is created from the new definition, the columns it
      # shares with the old table (all of its own: a rebuild only changes or
      # drops columns) are copied with their ids, the old table is dropped
      # and the new one renamed, then the table's indexes and `triggers_sql`
      # (its CREATE TRIGGER statements, read before the drop, which drops
      # them) are recreated. `sequence` is the table's sqlite_sequence value
      # before the drop (-1 for no row): it is put back when it is above the
      # copied rows' highest id, so AUTOINCREMENT never hands out the id of
      # a deleted row again. Run with foreign key enforcement off (the
      # Migrator does), or the DROP would fire the children's ON DELETE.
      def self.rebuild_table(definition_after, table_name, triggers_sql, sequence)
        stmts = Array.new(0) { "" }
        table = definition_after.table(table_name)
        if table.nil?
          message = "no table #{table_name} to rebuild"
          raise ArgumentError, message
        end
        temp = "#{table_name}_new"
        names = Array.new(0) { "" }
        names << "id"
        table.columns.each { |c| names << c.name }
        columns = names.join(", ")
        stmts << create_table(table, temp)
        stmts << "INSERT INTO #{temp} (#{columns}) SELECT #{columns} FROM #{table_name}"
        stmts << "DROP TABLE #{table_name}"
        stmts << rename_new_sql(table_name)
        table.indexes.each do |idx|
          stmts << index_sql(table_name, idx.columns, idx.unique, idx.name, idx.where, idx.expression)
        end
        triggers_sql.each { |sql| stmts << sql }
        if sequence >= 0
          quoted = "'#{table_name.gsub("'", "''")}'"
          stmts << "UPDATE sqlite_sequence SET seq = max(seq, #{sequence}) WHERE name = #{quoted}"
          stmts << "INSERT INTO sqlite_sequence (name, seq) SELECT #{quoted}, #{sequence} " \
                   "WHERE NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = #{quoted})"
        end
        stmts
      end

      # The rebuild's RENAME of `<table>_new` back to `<table>`. The Migrator
      # runs it with `PRAGMA legacy_alter_table = ON`: otherwise SQLite
      # checks every view and trigger that names `<table>` while it does not
      # exist yet and refuses the RENAME.
      def self.rename_new_sql(table_name)
        "ALTER TABLE #{table_name}_new RENAME TO #{table_name}"
      end

      # What a rebuild of the table declared by `create_sql` (its CREATE
      # TABLE text from sqlite_master) would silently lose, because the
      # schema (and so the rebuilt table) does not model it: "a CHECK
      # constraint", "a UNIQUE constraint" (a UNIQUE INDEX is kept), "a
      # COLLATE clause", "a generated column", "an ON UPDATE action", "an ON
      # DELETE SET DEFAULT action", "a DEFERRABLE foreign key", "a foreign
      # key to <table>(<column>)" (a column other than id), "the untyped
      # column <name>" (the copy would turn its integers into text), "a
      # primary key on <name>" (one other than id), "a non-integer primary
      # key on id" (a varchar id, Rails' id: :uuid), "the table option
      # <word>" (WITHOUT ROWID, STRICT). "" when there is nothing. Words
      # inside quotes and comments do not count.
      def self.rebuild_refusal(create_sql)
        tokens = sql_tokens(create_sql)
        i = 0
        while i < tokens.size
          case tokens[i].upcase
          when "CHECK" then return "a CHECK constraint"
          when "UNIQUE" then return "a UNIQUE constraint"
          when "COLLATE" then return "a COLLATE clause"
          when "GENERATED" then return "a generated column"
          when "DEFERRABLE" then return "a DEFERRABLE foreign key"
          when "ON"
            return "an ON UPDATE action" if i + 1 < tokens.size && tokens[i + 1].upcase == "UPDATE"
            if i + 3 < tokens.size && tokens[i + 1].upcase == "DELETE" && tokens[i + 2].upcase == "SET" &&
               tokens[i + 3].upcase == "DEFAULT"
              return "an ON DELETE SET DEFAULT action"
            end
          when "REFERENCES"
            target = refused_reference(tokens, i)
            return target if target != ""
          end
          i += 1
        end
        refused_definition(tokens)
      end

      # "a foreign key to t(col)" when the REFERENCES at `at` names a
      # column list with anything but id, else "".
      def self.refused_reference(tokens, at)
        return "" if at + 2 >= tokens.size || tokens[at + 2] != "("
        target = identifier_text(tokens[at + 1])
        j = at + 3
        while j < tokens.size && tokens[j] != ")"
          name = identifier_text(tokens[j])
          return "a foreign key to #{target}(#{name})" if tokens[j] != "," && name.downcase != "id"
          j += 1
        end
        ""
      end

      # The column definitions and table options: an untyped column, a
      # primary key other than id, a generated column's `AS (...)`, a word
      # after the closing parenthesis.
      def self.refused_definition(tokens)
        i = 0
        i += 1 while i < tokens.size && tokens[i] != "("
        i += 1
        depth = 1
        segment = Array.new(0) { "" }
        while i < tokens.size
          token = tokens[i]
          if depth == 1 && (token == "," || token == ")")
            refused = refused_segment(segment)
            return refused if refused != ""
            segment = Array.new(0) { "" }
            if token == ")"
              i += 1
              break
            end
          else
            depth += 1 if token == "("
            depth -= 1 if token == ")"
            segment << token
          end
          i += 1
        end
        return "the table option #{tokens[i]}" if i < tokens.size
        ""
      end

      CONSTRAINT_WORDS = ["CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT", "COLLATE",
                          "REFERENCES", "GENERATED", "AS"].freeze

      def self.refused_segment(segment)
        return "" if segment.empty?
        first = segment[0].upcase
        return "a PRIMARY KEY table constraint" if first == "PRIMARY"
        if first == "CONSTRAINT"
          return segment.size > 2 && segment[2].upcase == "PRIMARY" ? "a PRIMARY KEY table constraint" : ""
        end
        return "" if first == "FOREIGN" || first == "UNIQUE" || first == "CHECK"
        name = identifier_text(segment[0])
        if segment.size < 2 || CONSTRAINT_WORDS.include?(segment[1].upcase) || segment[1] == "("
          return "the untyped column #{name}"
        end
        depth = 0
        segment.each do |token|
          depth += 1 if token == "("
          depth -= 1 if token == ")"
          word = token.upcase
          return "a generated column" if depth == 0 && word == "AS"
          next unless depth == 0 && word == "PRIMARY"
          return "a primary key on #{name}" if name.downcase != "id"
          # Rails' id: :uuid / id: :string: the rebuilt id would be INTEGER.
          return "a non-integer primary key on id" unless segment[1].upcase.include?("INT")
        end
        ""
      end

      # A quoted identifier token ("\"name") as its name; any other token
      # as it is.
      def self.identifier_text(token)
        t = token.to_s
        return t.byteslice(1, t.bytesize - 1) if t.start_with?("\"")
        t
      end

      # SQL text -> tokens: unquoted words as written, a quoted identifier
      # ("...", `...`, [...]) as `"` plus its text, a '...' string as `'`,
      # every other character but white space on its own; comments
      # dropped. Byte-level on a `to_s` local (spikes/NOTES.md rule 62).
      def self.sql_tokens(sql)
        s = sql.to_s
        n = s.bytesize
        tokens = Array.new(0) { "" }
        i = 0
        while i < n
          b = s.getbyte(i)
          if b == 32 || b == 9 || b == 10 || b == 13
            i += 1
          elsif b == 45 && i + 1 < n && s.getbyte(i + 1) == 45
            i += 1 while i < n && s.getbyte(i) != 10
          elsif b == 47 && i + 1 < n && s.getbyte(i + 1) == 42
            i += 2
            i += 1 while i + 1 < n && !(s.getbyte(i) == 42 && s.getbyte(i + 1) == 47)
            i += 2
          elsif b == 39 || b == 34 || b == 96 || b == 91
            close = b == 91 ? 93 : b
            j = i + 1
            while j < n
              if s.getbyte(j) == close
                break unless close != 93 && j + 1 < n && s.getbyte(j + 1) == close
                j += 1
              end
              j += 1
            end
            tokens << (b == 39 ? "'" : "\"#{s.byteslice(i + 1, j - i - 1)}")
            i = j + 1
          elsif ddl_word_byte?(b)
            j = i
            j += 1 while j < n && ddl_word_byte?(s.getbyte(j))
            tokens << s.byteslice(i, j - i)
            i = j
          else
            tokens << s.byteslice(i, 1)
            i += 1
          end
        end
        tokens
      end

      def self.ddl_word_byte?(b)
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 36 || b >= 128
      end

      # A copy of `table` with the rebuild operation `op` applied: a
      # changed column (change_column, change_column_default,
      # change_column_null), a dropped reference column with its indexes
      # and foreign keys (remove_reference), a dropped foreign key
      # (remove_foreign_key). `table` itself is left as it was. Raises
      # ArgumentError when the column or the foreign key does not exist.
      def self.table_after(table, op)
        result = Cybertrain::Schema::Table.new(table.name)
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

      def self.create_table_statements(op)
        stmts = Array.new(0) { "" }
        table = op.table
        case table
        when Cybertrain::Schema::Table
          stmts << create_table(table)
          table.indexes.each do |idx|
            stmts << index_sql(idx.table, idx.columns, idx.unique, idx.name, idx.where, idx.expression)
          end
        end
        stmts
      end

      def self.drop_table_sql(op)
        "DROP TABLE #{Cybertrain::Migration::Operation.table_name(op.table)}"
      end

      def self.add_column_sql(op)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        "ALTER TABLE #{table} ADD COLUMN #{column_def(op.name, op.type, op.null, op.default, op.limit, op.precision, op.scale)}"
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
        index_sql(table, op.columns, op.unique, op.name, op.where, "")
      end

      def self.remove_index_sql(op)
        table = Cybertrain::Migration::Operation.table_name(op.table)
        name = op.name == "" ? derived_index_name(table, op.columns) : op.name
        drop_index_sql(name)
      end

      # `to_table` non-empty adds the foreign key inline: SQLite cannot add a
      # constraint to an existing table, but it does accept a REFERENCES
      # clause on the column ALTER TABLE ADD COLUMN creates. Its ON DELETE
      # is the reference's own `on_delete` (Base#add_reference records the
      # same action on both operations).
      def self.add_reference_statements(op, to_table = "")
        table = Cybertrain::Migration::Operation.table_name(op.table)
        column = add_column_sql(op)
        column = "#{column} REFERENCES #{to_table}(id)#{on_delete_clause(op.on_delete)}" if to_table != ""
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

      # precision/scale: a decimal's DECIMAL(p,s); 0 and -1 mean none.
      def self.column_def(name, type, null, default, limit, precision = 0, scale = -1)
        buf = +""
        buf << name.to_s << " " << sql_type(type, limit)
        buf << "(#{limit})" if limit != 0 && type == :string
        if type == :decimal && precision > 0
          buf << (scale >= 0 ? "(#{precision},#{scale})" : "(#{precision})")
        end
        buf << " NOT NULL" unless null
        buf << " DEFAULT #{default}" unless default.nil?
        buf
      end

      # An :integer with limit 8 is a bigint.
      def self.sql_type(type, limit = 0)
        case type
        when :string then "VARCHAR"
        when :integer then limit == 8 ? "BIGINT" : "INTEGER"
        when :float then "REAL"
        when :decimal then "DECIMAL"
        when :json then "JSON"
        when :boolean then "BOOLEAN"
        when :datetime then "DATETIME"
        when :date then "DATE"
        when :binary then "BLOB"
        else "TEXT"
        end
      end

      # `expression` non-empty is the key of an expression index and
      # replaces the column list; `where` non-empty makes it partial.
      def self.index_sql(table, columns, unique, name, where = "", expression = "")
        index_name = name == "" ? derived_index_name(table, columns) : name
        kind = unique ? "CREATE UNIQUE INDEX" : "CREATE INDEX"
        key = expression == "" ? columns.join(", ") : expression
        sql = "#{kind} #{index_name} ON #{table}(#{key})"
        sql = "#{sql} WHERE #{where}" if where != ""
        sql
      end

      # The ON DELETE clause for a foreign key's action, with its leading
      # space; "" for :no_action (SQLite's default).
      def self.on_delete_clause(action)
        case action
        when :cascade then " ON DELETE CASCADE"
        when :nullify then " ON DELETE SET NULL"
        when :restrict then " ON DELETE RESTRICT"
        else ""
        end
      end

      def self.derived_index_name(table, columns)
        Cybertrain::Schema::Index.derived_name(table, columns)
      end
    end
  end
end
