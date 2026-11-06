require "cybertrain/db/connection"
require "cybertrain/cast"

module Cybertrain
  module DB
    # Cybertrain::DB::Normalizer -- rewrites the DATETIME cells that
    # CyberTrain 0.4 stored as "2026-10-05T09:00:00Z" (and any other form
    # Cast.parse_time reads) into the stored format "YYYY-MM-DD
    # HH:MM:SS.ffffff" (UTC), so they sort correctly against new rows.
    # Behind `db normalize`.
    module Normalizer
      # SQL LIKE pattern of a cell already in the stored format.
      CANONICAL = "____-__-__ __:__:__.______"

      # Normalizes every DATETIME column of every user table, in one
      # transaction. A cell Cast.parse_time cannot read is left alone and
      # counted. A table without an `id` column cannot be updated by row and
      # is reported with rewritten -1 and skipped.
      # @param connection [Cybertrain::DB::Connection]
      # @return [Array<Array>] one [table, column, rewritten, skipped] per
      #   DATETIME column
      def self.run(connection)
        report = Array.new(0) { ["", "", 0, 0] }
        connection.transaction do
          tables = connection.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
          )
          tables.each do |t|
            table = t["name"].to_s
            normalize_table(connection, table, report)
          end
        end
        report
      end

      # @param connection [Cybertrain::DB::Connection]
      # @param table [String]
      # @param report [Array<Array>] receives one entry per DATETIME column
      # @return [nil]
      def self.normalize_table(connection, table, report)
        columns = connection.execute("PRAGMA table_info(#{table})")
        has_id = false
        datetimes = Array.new(0) { "" }
        columns.each do |c|
          name = c["name"].to_s
          has_id = true if name == "id"
          datetimes << name if c["type"].to_s.upcase == "DATETIME"
        end
        datetimes.each do |column|
          if has_id
            report << normalize_column(connection, table, column)
          else
            report << [table, column, -1, 0]
          end
        end
        nil
      end

      # @param connection [Cybertrain::DB::Connection]
      # @param table [String]
      # @param column [String]
      # @return [Array] [table, column, rewritten, skipped]
      def self.normalize_column(connection, table, column)
        rows = connection.execute(
          "SELECT id, #{column} AS v FROM #{table} WHERE #{column} IS NOT NULL AND #{column} NOT LIKE '#{CANONICAL}'"
        )
        rewritten = 0
        skipped = 0
        rows.each do |r|
          time = Cybertrain::Cast.parse_time(r["v"].to_s)
          if time.nil?
            skipped += 1
          else
            connection.execute(
              "UPDATE #{table} SET #{column} = ? WHERE id = ?",
              [Cybertrain::Cast.sql_datetime(time), r["id"]]
            )
            rewritten += 1
          end
        end
        [table, column, rewritten, skipped]
      end
    end
  end
end
