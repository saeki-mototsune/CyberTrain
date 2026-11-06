require "cybertrain/db/connection"
require "cybertrain/cast"
require "cybertrain/relation"

module Cybertrain
  module DB
    # Cybertrain::DB::Normalizer -- rewrites the DATETIME cells that
    # CyberTrain 0.4 stored as "2026-10-05T09:00:00Z" (and any other form
    # Cast.parse_time reads) into the stored format "YYYY-MM-DD
    # HH:MM:SS.ffffff" (UTC), so they sort correctly against new rows.
    # Behind `db normalize`.
    module Normalizer
      # SQL GLOB pattern of a cell already in the stored format (a [0-9]
      # class at every digit: LIKE's "_" would take any character).
      CANONICAL = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] " \
                  "[0-9][0-9]:[0-9][0-9]:[0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]"

      # The skipped slot of a rewritten -1 entry says why: WITHOUT ROWID.
      WITHOUT_ROWID = 1
      # ... or a column named _rowid_ that shadows SQLite's alias.
      DECLARES_ROWID = 2

      # Normalizes every DATETIME column of every user table, in one
      # transaction. A cell Cast.parse_time cannot read is left alone and
      # counted. Rows are located by SQLite's _rowid_, so a table needs no `id`
      # column; one that has no rowid (WITHOUT ROWID) or declares a column
      # named _rowid_ is reported with rewritten -1 and skipped, the reason
      # (WITHOUT_ROWID or DECLARES_ROWID) in the skipped slot and the count
      # of its cells that still need normalization in the pending slot.
      # @param connection [Cybertrain::DB::Connection]
      # @return [Array<Array>] one [table, column, rewritten, skipped,
      #   pending] per DATETIME column; pending is 0 for a normalized column
      def self.run(connection)
        report = Array.new(0) { ["", "", 0, 0, 0] }
        connection.transaction do
          tables = connection.execute(
            "SELECT name, sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
          )
          tables.each do |t|
            table = t["name"].to_s
            normalize_table(connection, table, t["sql"].to_s, report)
          end
        end
        report
      end

      # @param connection [Cybertrain::DB::Connection]
      # @param table [String]
      # @param create_sql [String] the table's CREATE statement
      # @param report [Array<Array>] receives one entry per DATETIME column
      # @return [nil]
      def self.normalize_table(connection, table, create_sql, report)
        # table_xinfo, not table_info: it also lists generated columns
        # (hidden 2 or 3), whose names can shadow _rowid_ too.
        columns = connection.execute("PRAGMA table_xinfo(#{pragma_quote(table)})")
        reason = 0
        reason = WITHOUT_ROWID if without_rowid?(create_sql)
        datetimes = Array.new(0) { "" }
        columns.each do |c|
          name = c["name"].to_s
          # Identifiers are case-insensitive: _ROWID_ shadows the alias too.
          reason = DECLARES_ROWID if name.downcase == "_rowid_" && reason == 0
          # hidden 2/3 is a generated column: it shadows _rowid_ like any
          # other, but cannot be written, so it is not normalized.
          writable = c["hidden"].to_i == 0
          datetimes << name if writable && Connection.datetime_decl?(c["type"].to_s)
        end
        datetimes.each do |column|
          if reason == 0
            report << normalize_column(connection, table, column)
          else
            report << [table, column, -1, reason, pending(connection, table, column)]
          end
        end
        nil
      end

      # True when the table options -- the text after the CREATE
      # statement's last ")" -- contain WITHOUT ROWID, in any case, with any
      # run of whitespace between the words and in either order with STRICT.
      # @param create_sql [String]
      # @return [Boolean]
      def self.without_rowid?(create_sql)
        s = create_sql.to_s
        n = s.bytesize
        last = -1
        i = 0
        while i < n
          last = i if s.getbyte(i) == 41 # ")"
          i += 1
        end
        tail = +""
        space = false
        i = last + 1
        while i < n
          b = s.getbyte(i)
          # 32 space, 9 tab, 10 newline, 13 carriage return
          if b == 32 || b == 9 || b == 10 || b == 13
            space = true
          else
            tail << " " if space
            space = false
            tail << s.byteslice(i, 1)
          end
          i += 1
        end
        tail.upcase.include?("WITHOUT ROWID")
      end

      # "a\"b" -> "\"a\"\"b\"": PRAGMA takes a double-quoted identifier.
      # @param name [String]
      # @return [String]
      def self.pragma_quote(name)
        "\"" + name.gsub("\"", "\"\"") + "\""
      end

      # @param connection [Cybertrain::DB::Connection]
      # @param table [String]
      # @param column [String]
      # @return [Array] [table, column, rewritten, skipped, 0]
      def self.normalize_column(connection, table, column)
        t = Cybertrain::Relation.quote_ident(table)
        c = Cybertrain::Relation.quote_ident(column)
        rows = connection.execute(
          "SELECT _rowid_ AS rid, #{c} AS v FROM #{t} WHERE #{c} IS NOT NULL AND #{c} NOT GLOB '#{CANONICAL}'"
        )
        rewritten = 0
        skipped = 0
        rows.each do |r|
          time = Cybertrain::Cast.parse_time(r["v"].to_s)
          if time.nil?
            skipped += 1
          else
            connection.execute(
              "UPDATE #{t} SET #{c} = ? WHERE _rowid_ = ?",
              [Cybertrain::Cast.sql_datetime(time), r["rid"]]
            )
            rewritten += 1
          end
        end
        [table, column, rewritten, skipped, 0]
      end

      # The number of cells of a skipped column that are not in the stored
      # format (read-only, so it works on a WITHOUT ROWID table too).
      # @param connection [Cybertrain::DB::Connection]
      # @param table [String]
      # @param column [String]
      # @return [Integer]
      def self.pending(connection, table, column)
        t = Cybertrain::Relation.quote_ident(table)
        c = Cybertrain::Relation.quote_ident(column)
        rows = connection.execute(
          "SELECT COUNT(*) AS n FROM #{t} WHERE #{c} IS NOT NULL AND #{c} NOT GLOB '#{CANONICAL}'"
        )
        rows[0]["n"].to_i
      end
    end
  end
end
