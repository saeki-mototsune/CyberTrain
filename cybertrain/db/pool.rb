require "cybertrain/db/connection"
require "cybertrain/logger"

module Cybertrain
  module DB
    # A fixed set of Connections shared by the server's threads. `with` blocks
    # (parking the green thread) until a connection is free.
    #
    # Every private in-memory or temporary connection (":memory:", a
    # `file::memory:` or `mode=memory` URI, "" for a private temporary file)
    # is its own database, so such a pool always holds exactly one connection
    # (and `size` reports 1) whatever size was asked for: otherwise tables
    # created through one `with` would be missing from the next. A
    # `cache=shared` in-memory URI is one database for all its connections
    # (Connection.private_database? says no), so that pool keeps its full
    # size, and a checkout nested in another gets a second connection.
    class Pool
      attr_reader :size

      def initialize(path, size = 4)
        @path = path
        # What a private in-memory or temporary path means is decided in one
        # place, Connection.private_database? (Connection asks it too, for
        # WAL): its single connection *is* the database, so the pool holds
        # exactly one, never closes it after a failed ROLLBACK (check_in) and
        # never replaces a closed one (reopen): either would drop every
        # table. Another spelling is a change to the predicate only.
        @reopenable = !Connection.private_database?(path)
        @size = @reopenable ? size : 1
        @connections = []
        # Guards @connections: `with` runs on every connection thread and
        # reopen rewrites the list (the SizedQueue covers the handing out).
        @lock = Mutex.new
        # Set by close_all. Every connection is closed then but stays in
        # @available, so without this flag `with` would take them for slots
        # whose ROLLBACK failed (see check_in) and reopen them on a pool
        # nobody references any more.
        @closed = false
        @available = SizedQueue.new(@size)
        # A failure while opening slot k (SQLITE_BUSY on the WAL switch, EMFILE,
        # a file that is not a database) must not leak slots 0..k-1: the Pool
        # never reaches the caller, so close_all cannot. Close what is open
        # and re-raise (a rescue, not an ensure: NOTES rule 50; JSON::ParserError
        # named too, rule 33).
        begin
          @size.times do
            conn = Connection.new(path)
            @connections << conn
            @available << conn
          end
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          @connections.each(&:close)
          raise e
        end
      end

      # The connection goes back clean: a transaction the block left open
      # is rolled back first -- see Connection#abandon_transaction! -- and
      # the log says so, since the writes are gone and nothing else would.
      # A pool that close_all shut down raises "pool closed" before it pops
      # anything (the closed connections are still queued; nothing may be
      # reopened or run against them), every time.
      # Otherwise a slot holding a closed connection (check_in closed it after
      # a failed ROLLBACK) is reopened here, on the checkout that needs it:
      # should the open fail, its error reaches this caller before the block
      # runs (no exception of the block's is masked) and the ensure puts the
      # closed connection back, so the slot survives and the next checkout
      # tries again.
      # Inside a Cybertrain::DB.transaction on this thread, the block gets
      # that transaction's connection instead (see held_index), with no
      # checkout and no check_in (which would roll the transaction back), so
      # what it runs joins the transaction. Decided here, in the yielding
      # method, and not in DB.with with a `block.call`: that makes DB.with's
      # block a Proc, and test/db_sqlite.rb's `5.times do |i| DB.with { |c|
      # ... [i] ... } end` then stopped compiling (NOTES rule 68).
      def with
        raise Error, "pool closed" if @closed
        held = held_index
        if held >= 0
          yield @connections[held]
        else
          conn = @available.pop
          begin
            conn = reopen(conn) if conn.closed?
            yield conn
          ensure
            check_in(conn)
          end
        end
      end

      # The Thread.current key under which checkout_transaction records the
      # connection a Cybertrain::DB.transaction runs on, so that DB.with
      # (`with` above) and a nested DB.transaction on the same thread use that
      # connection instead of checking out another one (held_index). Per
      # thread, so a Thread started inside the block is not part of it.
      TRANSACTION_KEY = :cybertrain_db_transaction

      # Cybertrain::DB.transaction's checkout, without a block: `with`'s pop
      # and reopen, and the connection recorded as this thread's transaction
      # connection. DB.transaction runs the block itself and always calls
      # checkin_transaction afterwards, from an ensure. Not a yielding method
      # around the transaction: that one's rescue would sit in a yielding
      # method applications call from nested blocks (NOTES rules 32/45), and
      # its block, passed on as a Proc, would reach `block.call` without the
      # class of the connection it receives (NOTES rule 69).
      def checkout_transaction
        raise Error, "pool closed" if @closed
        conn = @available.pop
        begin
          conn = reopen(conn) if conn.closed?
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          # The slot goes back, as `with`'s ensure puts it back.
          @available << conn
          raise e
        end
        Thread.current[TRANSACTION_KEY] = conn
        conn
      end

      # Ends checkout_transaction: the thread no longer holds a transaction
      # connection, and the connection goes back through check_in, which
      # rolls back anything still open (a block that left the transaction
      # without COMMIT or ROLLBACK: CRuby's break/return). Returns nil.
      def checkin_transaction(conn)
        Thread.current[TRANSACTION_KEY] = nil
        check_in(conn)
        nil
      end

      # Where in @connections this thread's open DB.transaction connection
      # is, or -1: none open, or it belongs to another pool (a DB.connect
      # inside the block), or it was closed. No lock: the slot of a
      # connection this thread holds is not rewritten by anyone else (reopen
      # replaces only the closed connection it popped).
      def held_index
        held = Thread.current[TRANSACTION_KEY]
        return -1 if held.nil?
        i = 0
        while i < @connections.size
          conn = @connections[i]
          return (conn.closed? ? -1 : i) if conn.equal?(held)
          i += 1
        end
        -1
      end

      # The connection at a held_index.
      def connection_at(index)
        @connections[index]
      end

      # Marks the pool closed first (see `with`), then closes every connection.
      def close_all
        @lock.synchronize do
          @closed = true
          @connections.each(&:close)
        end
      end

      private

      # The connection always goes back, whatever the rollback or the logger
      # does: a logger whose IO is gone (EPIPE at shutdown) must not leak the
      # slot from the pool, which with the one-connection in-memory pool
      # would block every later `with` for good, and (see `note`) must not
      # replace the exception the block is propagating either: this runs from
      # `with`'s ensure.
      # A connection whose ROLLBACK failed (:failed) is still inside the
      # transaction, where the next checkout's plain `execute` would write
      # into it and a later check-in would discard that write under the wrong
      # block's name; so it is closed, and `with` reopens the slot on the next
      # checkout. Not when the pool is not @reopenable (in-memory or temporary,
      # see initialize): the connection stays and the error line is the only remedy.
      # Returns nil: the `if` must not be the method's value (a Logger
      # subclass's `warn` can type differently from Logger#warn, rule 10).
      def check_in(conn)
        begin
          outcome = conn.abandon_transaction!
          if outcome == :rolled_back
            note(:warn, "rolled back a transaction left open on a pooled connection (a BEGIN without COMMIT)")
          elsif outcome == :failed
            if @reopenable
              note(:error, "could not roll back a transaction left open on a pooled connection; " \
                           "closed it, the next checkout reopens #{@path}")
              conn.close
            else
              note(:error, "could not roll back a transaction left open on the in-memory or temporary connection; " \
                           "it stays in the pool inside that transaction (closing it would drop the database)")
            end
          end
          nil
        ensure
          @available << conn
        end
        nil
      end

      # Writes one log line from check_in. A logger whose IO is gone (EPIPE at
      # shutdown) must neither leak the connection nor replace the block's own
      # exception, which check_in's caller (`with`'s ensure) is still
      # propagating; and there is nowhere left to report the logging failure
      # itself, so it is dropped. A plain method with its own rescue, called
      # from check_in (not a yielding method, rules 32/45; compare `clean?` in
      # test/db_transaction.rb). The level is picked with an `if`, no `send`
      # (rule 1). Returns nil.
      def note(level, message)
        begin
          if level == :error
            Cybertrain.logger.error(message)
          else
            Cybertrain.logger.warn(message)
          end
        rescue StandardError
          nil
        end
        nil
      end

      # A fresh connection for a slot whose connection was closed, taking
      # exactly the closed one's place in @connections (matched by identity: with
      # two slots closed, one still checked out and one queued, the queued one
      # is the one being reopened, not whichever closed entry comes first; a
      # persistent disk fault must not grow the list either). Never when the
      # pool's @reopenable is false (in-memory or temporary, see initialize): a
      # fresh connection would be an empty database with no
      # tables and no trace, so a closed one (user code closed it) is an error
      # on every later checkout.
      # Nor once close_all ran: a `with` that popped its connection
      # just before close_all finds it closed by the shutdown, not by check_in.
      # That is checked twice: before the open (saves it in the common case)
      # and again under the lock, where close_all cannot interleave. A
      # close_all that ran while the fresh connection was opening has already
      # closed the list without it, so `fresh` is closed here (its WAL and shm
      # locks would otherwise never be released) and the checkout fails. The
      # flag, not a raise inside the block, since a non-local exit from a
      # block is not safe under Spinel (rule 44). A Connection.new that fails
      # after the open (a PRAGMA) closes its own handle, so a disk fault that
      # keeps failing here leaks nothing per checkout.
      def reopen(closed)
        raise Error, "pool closed" if @closed
        unless @reopenable
          raise Error, "the in-memory or temporary connection was closed (Connection#close inside a checkout); " \
                       "reopening it would start an empty database"
        end
        fresh = Connection.new(@path)
        # Under the lock, so two threads reopening two slots at once cannot
        # both overwrite the same entry and strand one fresh connection
        # outside the list (unreachable by close_all).
        shut = false
        broken = false
        @lock.synchronize do
          if @closed
            shut = true
          else
            replaced = false
            i = 0
            while i < @connections.size
              if @connections[i].equal?(closed)
                @connections[i] = fresh
                replaced = true
                # A `break` out of a `while` is a plain loop exit (rule 44
                # concerns blocks).
                break
              end
              i += 1
            end
            broken = !replaced
          end
        end
        if shut
          fresh.close
          raise Error, "pool closed"
        end
        # Not reachable: every connection handed out comes from @connections.
        # If it ever happens the invariant is broken, so say so (closing
        # `fresh` first, nothing leaks) instead of quietly growing the list.
        # The flag, not a raise under the lock (rule 44).
        if broken
          fresh.close
          raise Error, "pool invariant broken: reopened a connection the pool does not own"
        end
        fresh
      end
    end
  end
end
