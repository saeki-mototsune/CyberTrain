require "digest"
require "cybertrain/cast"
require "cybertrain/schema"
require "cybertrain/migration"
require "cybertrain/db/error"
require "cybertrain/db/ddl_text"

module Cybertrain
  module DB
    module MySQL
      # Cybertrain::DB::MySQL::DDL -- Schema::Table and Migration::Operation
      # data as MySQL 8.0's DDL: what DB::Dialect.ddl_statements and
      # DB::Dialect.migrator_rebuild run on MySQL (cybertrain/db/sqlite_ddl.rb
      # is SQLite's). Every name is quoted with backticks.
      #
      # The types (docs/superpowers/specs/2026-11-27-mysql-adapter-design.md,
      # the type table): string VARCHAR(255) (or VARCHAR(limit)), text
      # MEDIUMTEXT, integer INT, an integer with limit 8 BIGINT, float DOUBLE,
      # decimal DECIMAL(p,s), boolean TINYINT(1), datetime DATETIME(6), date
      # DATE, json JSON, binary LONGBLOB. The id is BIGINT NOT NULL
      # AUTO_INCREMENT PRIMARY KEY, and a reference is BIGINT too: an
      # integer column whose name ends in `_id` (what references and
      # add_reference make, polymorphic ones included) is a BIGINT, since a
      # foreign key's column must have its parent id's type. The schema
      # reader (cybertrain/db/mysql/schema.rb) reads such a BIGINT back as a
      # plain integer, so db/schema.rb says what it says on SQLite.
      #
      # Every CREATE TABLE ends in TABLE_OPTIONS. A create_table's indexes
      # are declared in the CREATE TABLE, before its foreign keys, so a
      # foreign key finds its index there and MySQL makes none of its own.
      # A partial index (`where:`) does not exist in MySQL and is refused
      # with PARTIAL_INDEX (gen refuses it first: Gen::Dialect). An index
      # name longer than MySQL's 64 characters (a derived
      # index_<table>_on_<a>_and_<b> can be) is shortened the same way
      # wherever one is written (index_name).
      module DDL
        TABLE_OPTIONS = " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin"

        PARTIAL_INDEX = "partial indexes (where:) are not supported on MySQL"

        # MySQL's longest identifier, in characters (error 1059 past it).
        MAX_NAME = 64

        # "posts" -> "`posts`" (DB::Dialect.quote_ident).
        # @param name [String]
        # @return [String]
        def self.q(name)
          Cybertrain::DB::Dialect.quote_ident(name.to_s)
        end

        # The statements one operation runs, those that do not read the
        # live schema: every kind but the rebuild ones (op.rebuilds?, which
        # go through `rebuild_sql`). A :remove_index drops the index op.name
        # names (the Migrator gives it the one it found), else the derived
        # name.
        # @param op [Cybertrain::Migration::Operation]
        # @return [Array<String>]
        def self.statements(op)
          table = op.table_text
          case op.kind
          when :create_table
            create_table_statements(op)
          when :drop_table
            ["DROP TABLE #{q(table)}"]
          when :add_column
            ["ALTER TABLE #{q(table)} ADD COLUMN " +
              column_sql(op.name, op.type, op.null, op.default, op.limit, op.precision, op.scale)]
          when :remove_column
            ["ALTER TABLE #{q(table)} DROP COLUMN #{q(op.name)}"]
          when :rename_column
            ["ALTER TABLE #{q(table)} RENAME COLUMN #{q(op.name)} TO #{q(op.new_name)}"]
          when :add_index
            [create_index_sql(table, op.columns, op.unique, op.name, op.where, "")]
          when :remove_index
            name = op.name == "" ? Cybertrain::Schema::Index.derived_name(table, op.columns) : op.name
            ["DROP INDEX #{q(index_name(name))} ON #{q(table)}"]
          when :add_reference
            ["ALTER TABLE #{q(table)} ADD COLUMN " + column_sql(op.name, :integer, op.null, nil, 0),
             create_index_sql(table, [op.name], false, "", "", "")]
          when :add_foreign_key
            ["ALTER TABLE #{q(table)} ADD " + foreign_key_sql(op.name, op.to_table, op.on_delete)]
          when :rename_table
            ["RENAME TABLE #{q(table)} TO #{q(op.new_name)}"]
          when :change_column, :change_column_default, :change_column_null, :remove_reference, :remove_foreign_key
            message = "#{op.kind} reads the live schema (DB::Dialect.migrator_rebuild)"
            raise ArgumentError, message
          else
            message = "unknown operation kind #{op.kind}"
            raise ArgumentError, message
          end
        end

        def self.create_table_statements(op)
          stmts = Array.new(0) { "" }
          table = op.table
          case table
          when Cybertrain::Schema::Table
            stmts << create_table_sql(table)
          end
          stmts
        end

        # Schema::Table -> its CREATE TABLE: the id first (none for an `id:
        # false` table), the columns, the indexes, the foreign keys, then
        # TABLE_OPTIONS.
        # @param table [Cybertrain::Schema::Table]
        # @return [String]
        def self.create_table_sql(table)
          parts = Array.new(0) { "" }
          parts << "#{q("id")} BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY" unless table.without_id?
          table.columns.each do |c|
            parts << column_sql(c.name, c.type, c.null, c.default, c.limit, c.precision, c.scale)
          end
          table.indexes.each do |idx|
            parts << index_clause(table.name, idx.columns, idx.unique, idx.name, idx.where, idx.expression)
          end
          table.foreign_keys.each do |fk|
            parts << foreign_key_sql(fk.column, fk.to_table, fk.on_delete)
          end
          buf = +"CREATE TABLE #{q(table.name)} ("
          buf << parts.join(", ")
          buf << ")"
          buf << TABLE_OPTIONS
          buf
        end

        # One column's definition. precision/scale: a decimal's; 0 and -1
        # mean none. A default on a MEDIUMTEXT, JSON or LONGBLOB column is
        # written as an expression (`DEFAULT ('{}')`), the only default
        # MySQL takes on those.
        # @return [String]
        def self.column_sql(name, type, null, default, limit, precision = 0, scale = -1)
          buf = +""
          buf << q(name) << " " << type_sql(name, type, limit, precision, scale)
          buf << " NOT NULL" unless null
          unless default.nil?
            text = default.to_s
            text = "(#{text})" if expression_default?(type) && !text.start_with?("(")
            buf << " DEFAULT " << text
          end
          buf
        end

        def self.expression_default?(type)
          type == :text || type == :json || type == :binary
        end

        # The column type of `type` (see the module notes).
        # @return [String]
        def self.type_sql(name, type, limit, precision, scale)
          case type
          when :string then limit > 0 ? "VARCHAR(#{limit})" : "VARCHAR(255)"
          when :integer then limit == 8 || reference_name?(name) ? "BIGINT" : "INT"
          when :float then "DOUBLE"
          when :decimal
            if precision <= 0
              "DECIMAL"
            elsif scale >= 0
              "DECIMAL(#{precision},#{scale})"
            else
              "DECIMAL(#{precision})"
            end
          when :json then "JSON"
          when :boolean then "TINYINT(1)"
          when :datetime then "DATETIME(6)"
          when :date then "DATE"
          when :binary then "LONGBLOB"
          else "MEDIUMTEXT"
          end
        end

        # "article_id": a reference's column.
        def self.reference_name?(name)
          name.to_s.end_with?("_id")
        end

        # CREATE [UNIQUE] INDEX for a table that exists.
        # @return [String]
        def self.create_index_sql(table, columns, unique, name, where, expression)
          quoted = q(checked_index_name(table, columns, name, where))
          kind = unique ? "CREATE UNIQUE INDEX" : "CREATE INDEX"
          "#{kind} #{quoted} ON #{q(table)} (#{key_sql(columns, expression)})"
        end

        # The index in a CREATE TABLE: [UNIQUE] KEY name (key).
        # @return [String]
        def self.index_clause(table, columns, unique, name, where, expression)
          quoted = q(checked_index_name(table, columns, name, where))
          kind = unique ? "UNIQUE KEY" : "KEY"
          "#{kind} #{quoted} (#{key_sql(columns, expression)})"
        end

        # The name an index is created with: `name`, or the derived one when
        # it is "", as index_name writes it; a partial index is refused.
        # @return [String]
        def self.checked_index_name(table, columns, name, where)
          refuse_partial(where)
          given = name == "" ? Cybertrain::Schema::Index.derived_name(table, columns) : name
          index_name(given)
        end

        # `name` as MySQL can hold it: itself up to MAX_NAME characters,
        # else its first 53 and "_" and the first 10 hex digits of its
        # SHA-256, so that the same long name is always the same short one
        # (a remove_index finds the index add_index made). The short name
        # is what the schema dump then reads.
        # @param name [String]
        # @return [String]
        def self.index_name(name)
          text = name.to_s
          return text if text.size <= MAX_NAME

          digest = Digest::SHA256.hexdigest(text)[0, 10].to_s
          head = text[0, MAX_NAME - 11].to_s
          "#{head}_#{digest}"
        end

        # The quoted columns, or an expression index's key as MySQL's
        # functional key part: the expression in its own parentheses, unless
        # it starts with one (the key parts SchemaReader dumps, each in its
        # parentheses already: "(lower(`title`)), `id`").
        def self.key_sql(columns, expression)
          return expression if expression.start_with?("(")
          return "(#{expression})" if expression != ""

          quoted = Array.new(0) { "" }
          columns.each { |c| quoted << q(c) }
          quoted.join(", ")
        end

        def self.refuse_partial(where)
          raise Cybertrain::DB::Error, PARTIAL_INDEX if where != ""

          nil
        end

        # FOREIGN KEY (`column`) REFERENCES `to_table` (`id`) [ON DELETE ...].
        # @return [String]
        def self.foreign_key_sql(column, to_table, on_delete)
          "FOREIGN KEY (#{q(column)}) REFERENCES #{q(to_table)} (#{q("id")})" +
            Cybertrain::DB::DDLText.on_delete_clause(on_delete)
        end

        # The one ALTER TABLE a rebuild operation (op.rebuilds?) is on
        # MySQL, which changes a table in place. `definition` is the live
        # schema dumped just before (SchemaDumper): a change_column is that
        # column with the operation applied (DDLText.table_after, the same
        # in-memory step SQLite rebuilds from), MODIFY'd with the type the
        # migration states. A change_column_default or change_column_null
        # changes only the default or the nullability of the column as the
        # server has it (column_change_sql): the dump does not carry every
        # type (BIGINT UNSIGNED, ENUM), a collation or a comment. A removed foreign
        # key is found by its column and parent (`conn`); a removed
        # reference drops its foreign keys, every index on the column and
        # the column, in the one statement. change_column_null's backfill
        # UPDATE is not part of it: the Migrator runs it first, as a
        # statement of its own.
        # @param conn [Cybertrain::DB::Connection]
        # @param op [Cybertrain::Migration::Operation]
        # @param definition [Cybertrain::Schema::Definition]
        # @return [String]
        def self.rebuild_sql(conn, op, definition)
          table_name = op.table_text
          table = definition.table(table_name)
          if table.nil?
            message = "cannot #{op.kind} on #{table_name}: no such table"
            raise Cybertrain::DB::Error, message
          end
          after = Cybertrain::DB::DDLText.table_after(table, op)
          if op.kind == :remove_foreign_key
            names = foreign_key_names(conn, table_name, op.name, op.to_table)
            if names.empty?
              message = "remove_foreign_key: no foreign key from #{table_name}.#{op.name} to #{op.to_table}"
              raise ArgumentError, message
            end
            return "ALTER TABLE #{q(table_name)} DROP FOREIGN KEY #{q(names[0])}"
          end
          if op.kind == :remove_reference
            drops = Array.new(0) { "" }
            foreign_key_names(conn, table_name, op.name, "").each { |name| drops << "DROP FOREIGN KEY #{q(name)}" }
            table.indexes.each do |idx|
              drops << "DROP INDEX #{q(idx.name)}" if idx.columns.include?(op.name)
            end
            drops << "DROP COLUMN #{q(op.name)}"
            return "ALTER TABLE #{q(table_name)} " + drops.join(", ")
          end
          if op.kind == :change_column_default || op.kind == :change_column_null
            return column_change_sql(conn, table_name, op)
          end
          column = after.column(op.name)
          if column.nil?
            message = "#{op.kind}: no column #{table_name}.#{op.name}"
            raise ArgumentError, message
          end
          "ALTER TABLE #{q(table_name)} MODIFY COLUMN " +
            column_sql(column.name, column.type, column.null, column.default, column.limit, column.precision, column.scale)
        end

        # The data types whose default MySQL takes only as an expression,
        # and only in a column definition (ALTER COLUMN ... SET DEFAULT
        # refuses them, error 1101).
        EXPRESSION_DEFAULT_TYPES = ["tinytext", "text", "mediumtext", "longtext", "json", "tinyblob", "blob",
                                    "mediumblob", "longblob", "geometry", "point", "linestring", "polygon",
                                    "multipoint", "multilinestring", "multipolygon", "geometrycollection"].freeze

        # The statement of a change_column_default or change_column_null,
        # from the column as the server has it, so that nothing but its
        # default or its nullability changes (a type the schema dump does
        # not carry, BIGINT UNSIGNED or ENUM(...), its character set,
        # collation, comment, ON UPDATE and AUTO_INCREMENT stay as they
        # are):
        # - a default dropped: ALTER COLUMN ... DROP DEFAULT;
        # - a default set to a literal or a parenthesized expression, on a
        #   type that takes one there: ALTER COLUMN ... SET DEFAULT <to>;
        # - any other default (CURRENT_TIMESTAMP, or one on a text, blob,
        #   json or geometry column), and a nullability: MODIFY COLUMN with
        #   the column's definition as SHOW CREATE TABLE prints it, its
        #   DEFAULT clause or its NULL / NOT NULL replaced. A NOT NULL drops
        #   a DEFAULT NULL, which MySQL refuses beside it (SQLite's rebuild
        #   leaves such a column with no default).
        # A generated column is refused (DB::Error): its NULL / NOT NULL
        # follows its expression.
        # @param conn [Cybertrain::DB::Connection]
        # @param table [String]
        # @param op [Cybertrain::Migration::Operation]
        # @return [String]
        def self.column_change_sql(conn, table, op)
          info = conn.execute("SELECT column_type AS t, data_type AS d, generation_expression AS g " \
                              "FROM information_schema.columns WHERE table_schema = DATABASE() " \
                              "AND table_name = ? AND column_name = ?", [table, op.name])
          if info.empty?
            message = "#{op.kind}: no column #{table}.#{op.name}"
            raise ArgumentError, message
          end
          column_type = Cybertrain::Cast.str(info[0]["t"])
          data_type = Cybertrain::Cast.str(info[0]["d"]).downcase
          if Cybertrain::Cast.str(info[0]["g"]) != ""
            message = "#{op.kind}: #{table}.#{op.name} is a generated column (MySQL)"
            raise Cybertrain::DB::Error, message
          end
          head = "ALTER TABLE #{q(table)}"
          col = q(op.name)
          expression_type = EXPRESSION_DEFAULT_TYPES.include?(data_type)
          if op.kind == :change_column_default
            return "#{head} ALTER COLUMN #{col} DROP DEFAULT" if op.default.nil?

            to = op.default.to_s
            return "#{head} ALTER COLUMN #{col} SET DEFAULT #{to}" if !expression_type && literal_default?(to)
          end
          line = live_column_definition(conn, table, op.name, column_type)
          unless line.start_with?(column_type)
            message = "#{op.kind}: cannot read the definition of #{table}.#{op.name} from SHOW CREATE TABLE"
            raise Cybertrain::DB::Error, message
          end
          at = after_charset(line, column_type.size)
          type_part = line[0, at]
          null_part = ""
          rest = line[at, line.size - at]
          if rest.start_with?(" NOT NULL")
            null_part = " NOT NULL"
          elsif rest.start_with?(" NULL")
            null_part = " NULL"
          end
          rest = rest[null_part.size, rest.size - null_part.size]
          invisible = ""
          if rest.start_with?(" /*!80023 INVISIBLE */")
            invisible = " /*!80023 INVISIBLE */"
            rest = rest[invisible.size, rest.size - invisible.size]
          end
          default_part = ""
          if rest.start_with?(" DEFAULT ")
            stop = default_token_end(rest, 9)
            default_part = rest[0, stop]
            rest = rest[stop, rest.size - stop]
          end
          if op.kind == :change_column_null
            null_part = op.null ? " NULL" : " NOT NULL"
            default_part = "" if !op.null && default_part == " DEFAULT NULL"
          else
            to = op.default.to_s
            to = "(#{to})" if expression_type && !to.start_with?("(")
            default_part = " DEFAULT #{to}"
          end
          "#{head} MODIFY COLUMN #{col} #{type_part}#{null_part}#{invisible}#{default_part}#{rest}"
        end

        # Whether ALTER COLUMN ... SET DEFAULT takes `to` as it is: a quoted
        # or numeric literal, NULL, TRUE, FALSE, a bit or hex literal, or an
        # expression in parentheses (not CURRENT_TIMESTAMP and the like,
        # which only a column definition takes bare).
        def self.literal_default?(to)
          return false if to.empty?
          return true if ["NULL", "TRUE", "FALSE"].include?(to.upcase)

          first = to[0]
          return true if "'(-+.0123456789".include?(first)

          to.start_with?("b'") || to.start_with?("B'") || to.start_with?("x'") || to.start_with?("X'")
        end

        # The definition of `table`'s column `column` (of type
        # `column_type`) as SHOW CREATE TABLE prints it, after its quoted
        # name: "bigint unsigned NOT NULL DEFAULT '0' COMMENT 'x'"; "" when
        # the table has no such line. A bare COLLATE that is the table's
        # own (which MySQL 8.0 prints on every text column) is left out, so
        # that the MODIFY does not pin the column's character set where
        # the table's applied.
        # @return [String]
        def self.live_column_definition(conn, table, column, column_type)
          rows = conn.execute("SHOW CREATE TABLE #{q(table)}")
          return "" if rows.empty?

          text = Cybertrain::Cast.str(rows[0]["Create Table"])
          want = "  #{q(column)} "
          found = ""
          options = ""
          text.split("\n").each do |line|
            found = line[want.size, line.size - want.size] if found.empty? && line.start_with?(want)
            options = line if line.start_with?(") ")
          end
          found = found[0, found.size - 1] if found.end_with?(",")
          at = options.index(" COLLATE=")
          return found if at.nil?

          start = at + 9
          stop = options.index(" ", start)
          stop = options.size if stop.nil?
          own = "#{column_type} COLLATE #{options[start, stop - start]}"
          return found unless found.start_with?(own)
          return found if found.size > own.size && found[own.size] != " "

          column_type + found[own.size, found.size - own.size].to_s
        end

        # The offset in `line` past its type (`at`) and the CHARACTER SET
        # and COLLATE clauses that may follow it.
        # @return [Integer]
        def self.after_charset(line, at)
          pos = at
          ["CHARACTER SET", "COLLATE"].each do |word|
            lead = " #{word} "
            if line[pos, line.size - pos].start_with?(lead)
              pos += lead.size
              pos += 1 while pos < line.size && line[pos] != " "
            end
          end
          pos
        end

        # The offset in `text` where the value that starts at `from` ends: at
        # the first space outside quotes and parentheses (a quoted literal
        # with its '' and backslash escapes, an expression in parentheses,
        # a word such as CURRENT_TIMESTAMP(6)).
        # @return [Integer]
        def self.default_token_end(text, from)
          pos = from
          depth = 0
          quote = ""
          while pos < text.size
            ch = text[pos]
            if quote != ""
              if ch == "\\"
                pos += 1
              elsif ch == quote
                quote = ""
              end
            elsif ch == "'" || ch == "\""
              quote = ch
            elsif ch == "("
              depth += 1
            elsif ch == ")"
              depth -= 1
            elsif ch == " " && depth == 0
              return pos
            end
            pos += 1
          end
          pos
        end

        # The names of the foreign keys from `table`.`column` (to `parent`,
        # when it is not ""), in name order; DDLText.table_after has
        # already refused a remove_foreign_key with none.
        # @return [Array<String>]
        def self.foreign_key_names(conn, table, column, parent)
          sql = +"SELECT constraint_name AS name FROM information_schema.key_column_usage " \
                 "WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ? " \
                 "AND referenced_table_name IS NOT NULL"
          binds = Cybertrain::Cast.empty_binds
          binds << table
          binds << column
          unless parent.empty?
            sql << " AND referenced_table_name = ?"
            binds << parent
          end
          sql << " ORDER BY constraint_name"
          names = Array.new(0) { "" }
          conn.execute(sql, binds).each { |r| names << Cybertrain::Cast.str(r["name"]) }
          names
        end
      end
    end
  end
end
