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
        @path = path
        @size = path == ":memory:" ? 1 : size
        @connections = []
        # Guards @connections: `with` runs on every connection thread and
        # reopen rewrites the list (the SizedQueue covers the handing out).
        @lock = Mutex.new
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
      # A slot holding a closed connection (check_in closed it after a
      # failed ROLLBACK) is reopened here, on the checkout that needs it:
      # should the open fail, its error reaches this caller before the block
      # runs (no exception of the block's is masked) and the ensure puts the
      # closed connection back, so the slot survives and the next checkout
      # tries again.
      def with
        conn = @available.pop
        begin
          conn = reopen(conn) if conn.closed?
          yield conn
        ensure
          check_in(conn)
        end
      end

      def close_all
        @lock.synchronize { @connections.each(&:close) }
      end

      private

      # The connection always goes back, whatever the rollback or the logger
      # does: a logger whose IO is gone (EPIPE at shutdown) must not leak the
      # slot from the pool, which with the one-connection ":memory:" pool
      # would block every later `with` for good.
      # A connection whose ROLLBACK failed (:failed) is still inside the
      # transaction, where the next checkout's plain `execute` would write
      # into it and a later check-in would discard that write under the wrong
      # block's name; so it is closed, and `with` reopens the slot on the next
      # checkout. Not for ":memory:": that one connection *is* the database,
      # closing it would drop every table, so it stays and the error line is
      # the only remedy.
      # Returns nil: the `if` must not be the method's value (a Logger
      # subclass's `warn` can type differently from Logger#warn, rule 10).
      def check_in(conn)
        begin
          outcome = conn.abandon_transaction!
          if outcome == :rolled_back
            Cybertrain.logger.warn("rolled back a transaction left open on a pooled connection (a BEGIN without COMMIT)")
          elsif outcome == :failed
            if @path == ":memory:"
              Cybertrain.logger.error("could not roll back a transaction left open on the :memory: connection; " \
                                      "it stays in the pool inside that transaction (closing it would drop the database)")
            else
              Cybertrain.logger.error("could not roll back a transaction left open on a pooled connection; " \
                                      "closed it, the next checkout reopens #{@path}")
              conn.close
            end
          end
          nil
        ensure
          @available << conn
        end
        nil
      end

      # A fresh connection for a slot whose connection was closed, taking the
      # closed one's place in @connections (a persistent disk fault must not
      # grow the list). Never for ":memory:": that one connection is the
      # database, a fresh one would be an empty database with no tables and
      # no trace, so a closed ":memory:" connection (user code closed it) is
      # an error on every later checkout, as it was before the pool reopened
      # anything.
      def reopen(closed)
        if @path == ":memory:"
          raise Error, "the :memory: connection was closed (Connection#close inside a checkout); " \
                       "reopening it would start an empty database"
        end
        fresh = Connection.new(@path)
        # Under the lock, so two threads reopening two slots at once cannot
        # both take the same closed entry and strand one fresh connection
        # outside the list (unreachable by close_all).
        @lock.synchronize do
          replaced = false
          i = 0
          while i < @connections.size
            if !replaced && @connections[i].closed?
              @connections[i] = fresh
              replaced = true
            end
            i += 1
          end
          @connections << fresh unless replaced
        end
        fresh
      end
    end
  end
end
