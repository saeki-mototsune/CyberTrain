module Cybertrain
  module WebSocket
    # Where {WebSocket.publish_status} writes a feed's status row. The
    # default writes nothing; cybertrain/websocket/feed_table.rb registers
    # the one that writes `cybertrain_feeds` ({FeedTable}), and
    # cybertrain/feeds requires it. cybertrain/websocket requires
    # cybertrain/feeds (and so the core, with SQLite), so every program that
    # subscribes publishes; `require "cybertrain/websocket"` no longer loads
    # under CRuby or without the database (docs/design.md D85). The
    # registry keeps the frame and client files free of the table. The same
    # pattern as Background::Service: a base-class registry, a subclass
    # instance added by the file that has the real one.
    # @api public
    class StatusWriter
      # Writes one feed's row.
      # @param name [String] the subscription's name
      # @param process [String] "<hostname>:<pid>"
      # @param connected [Boolean]
      # @param started_at [Integer] epoch seconds
      # @param last_activity_at [Integer] epoch seconds, 0 for none yet
      # @param restarts [Integer]
      # @param now [Integer] epoch seconds, the row's updated_at
      # @return [Boolean] true when it wrote the row
      # @api public
      def status_write(name, process, connected, started_at, last_activity_at, restarts, now)
        false
      end

      # Deletes the rows `process` wrote (its feeds were stopped cleanly).
      # @param process [String] "<hostname>:<pid>"
      # @return [Integer] how many rows it deleted
      # @api public
      def status_withdraw(process)
        0
      end
    end

    # The registered writers: a constant, rooted for the collector (NOTES
    # rule 64), seeded with the base class and emptied (rule 9).
    STATUS_WRITERS = Array.new(0) { StatusWriter.new }
  end
end
