require "cybertrain/db/connection"
require "cybertrain/logger"

module Cybertrain
  module DB
    # A fixed set of Connections shared by the server's threads. `with` blocks
    # (parking the green thread) until a connection is free.
    #
    # Every ":memory:" connection is its own private database, so a
    # ":memory:" pool always holds exactly one connection (and `size`
    # reports 1) whatever size was asked for: otherwise tables created
    # through one `with` would be missing from the next.
    class Pool
      attr_reader :size

      def initialize(path, size = 4)
        @size = path == ":memory:" ? 1 : size
        @connections = []
        @available = SizedQueue.new(@size)
        @size.times do
          conn = Connection.new(path)
          @connections << conn
          @available << conn
        end
      end

      # The connection goes back clean: a transaction the block left open
      # is rolled back first -- see Connection#abandon_transaction! -- and
      # the log says so, since the writes are gone and nothing else would.
      def with
        conn = @available.pop
        begin
          yield conn
        ensure
          check_in(conn)
        end
      end

      def close_all
        @connections.each(&:close)
      end

      private

      # The connection always goes back, whatever the rollback or the logger
      # does: a logger whose IO is gone (EPIPE at shutdown) must not leak the
      # connection from the pool, which with the one-connection ":memory:"
      # pool would block every later `with` for good.
      # Returns nil: the `if` must not be the method's value (a Logger
      # subclass's `warn` can type differently from Logger#warn, rule 10).
      def check_in(conn)
        begin
          rolled_back = conn.abandon_transaction!
          Cybertrain.logger.warn("rolled back a transaction left open on a pooled connection (a BEGIN without COMMIT)") if rolled_back
          nil
        ensure
          @available << conn
        end
        nil
      end
    end
  end
end
