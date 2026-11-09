module Cybertrain
  module WebSocket
    # Where {WebSocket.publish_status} writes a feed's status row. The
    # default writes nothing; cybertrain/websocket/feed_table.rb registers
    # the one that writes `cybertrain_feeds` ({FeedTable}), and the
    # framework entry point (cybertrain.rb) requires it, so every
    # application publishes while a program that requires only
    # cybertrain/websocket links no SQLite (and runs under CRuby). The same
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
    end

    # The registered writers: a constant, rooted for the collector (NOTES
    # rule 64), seeded with the base class and emptied (rule 9).
    STATUS_WRITERS = Array.new(0) { StatusWriter.new }
  end
end
