require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/websocket/status_writer"

module Cybertrain
  module WebSocket
    # Cybertrain::WebSocket::FeedTable -- the feeds' status, published
    # through the database so that a process that serves no HTTP (the
    # `feeds` role) can still be watched: `GET /up` in a `server` process
    # and `./<app> feeds status` read it.
    #
    # One row per subscription in `cybertrain_feeds`, which the framework
    # creates itself (`CREATE TABLE IF NOT EXISTS`, on first use) and leaves
    # out of `db/schema.rb`, like `cybertrain_schedules`. The supervisor of
    # every process that runs feeds writes them ({WebSocket.publish_status})
    # every {Config#feed_status_interval} seconds, through the
    # {StatusWriter} this file registers. Times are epoch seconds.
    # @api public
    module FeedTable
      TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_feeds (" \
                  "name TEXT PRIMARY KEY, " \
                  "process TEXT, " \
                  "connected INTEGER, " \
                  "started_at INTEGER NOT NULL, " \
                  "last_activity_at INTEGER, " \
                  "restarts INTEGER, " \
                  "updated_at INTEGER NOT NULL);"

      # A last activity of 0 is stored as NULL (none yet).
      WRITE_SQL = "INSERT INTO cybertrain_feeds " \
                  "(name, process, connected, started_at, last_activity_at, restarts, updated_at) " \
                  "VALUES (?, ?, ?, ?, NULLIF(?, 0), ?, ?) " \
                  "ON CONFLICT(name) DO UPDATE SET process = excluded.process, " \
                  "connected = excluded.connected, started_at = excluded.started_at, " \
                  "last_activity_at = excluded.last_activity_at, restarts = excluded.restarts, " \
                  "updated_at = excluded.updated_at"

      # The DB.generation the table was last ensured for; -1 for never (as
      # Scheduler::Timetable's).
      @installed_generation = -1

      # Creates the table if it is missing. The other methods call it once
      # per connected database.
      # @return [nil]
      # @api public
      def self.install!
        DB.with { |c| c.exec_script(TABLE_SQL) }
        # A CREATE inside a transaction that rolls back is undone, so only
        # one outside a transaction is remembered (as Job.install! does).
        pool = DB.pool
        @installed_generation = DB.generation if !pool.nil? && pool.held_index < 0
        nil
      end

      # install! unless it already ran since the last DB.connect.
      def self.ensure_installed
        install! unless @installed_generation == DB.generation
        nil
      end

      # Every row, ordered by name, as the Hashes Connection#execute gives,
      # keyed by column name:
      #
      # - `"name"` [String] the subscription's name
      # - `"process"` [String] who published it, `"<hostname>:<pid>"`
      # - `"connected"` [Integer] 1 when the feed was connected, else 0
      # - `"started_at"` [Integer] when that process started the feed
      # - `"last_activity_at"` [Integer, nil] the last message or pong
      #   answering the feed's ping; nil until the first
      # - `"restarts"` [Integer] how many times the supervisor started the
      #   feed's thread again after it died
      # - `"updated_at"` [Integer] when the row was written
      #
      # A feed is silent when `COALESCE(last_activity_at, started_at)` is
      # old, and its publisher stale when `updated_at` is.
      # @return [Array<Hash{String => Object}>]
      # @raise [Cybertrain::DB::Error] when the database is not reachable
      # @api public
      def self.read_feeds
        ensure_installed
        DB.with do |c|
          c.execute("SELECT name, process, connected, started_at, last_activity_at, restarts, updated_at " \
                    "FROM cybertrain_feeds ORDER BY name")
        end
      end

      # Writes a feed's row (inserting it or replacing it).
      # @param name [String] the subscription's name
      # @param process [String] the publishing process, "<hostname>:<pid>"
      # @param connected [Boolean]
      # @param started_at [Integer] epoch seconds
      # @param last_activity_at [Integer] epoch seconds; 0 for none yet
      #   (stored as NULL)
      # @param restarts [Integer]
      # @param now [Integer] epoch seconds, stored as updated_at
      # @return [nil]
      # @raise [Cybertrain::DB::Error] when the database is not reachable
      # @api public
      def self.upsert_feed(name, process, connected, started_at, last_activity_at, restarts, now)
        ensure_installed
        binds = Cast.binds(name, process, connected ? 1 : 0, started_at, last_activity_at, restarts, now)
        DB.with { |c| c.execute(WRITE_SQL, binds) }
        nil
      end
    end

    # The {StatusWriter} that writes `cybertrain_feeds` rows, when a
    # database is connected.
    # @api public
    class FeedTableWriter < StatusWriter
      # (see StatusWriter#status_write)
      # @raise [Cybertrain::DB::Error] when the database is not reachable
      # @api public
      def status_write(name, process, connected, started_at, last_activity_at, restarts, now)
        return false unless DB.connected?

        FeedTable.upsert_feed(name, process, connected, started_at, last_activity_at, restarts, now)
        true
      end
    end
  end
end

Cybertrain::WebSocket::STATUS_WRITERS << Cybertrain::WebSocket::FeedTableWriter.new
