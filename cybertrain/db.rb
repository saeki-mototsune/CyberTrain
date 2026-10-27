# Cybertrain::DB -- SQLite access: one process-wide connection pool.
#
#   Cybertrain::DB.connect("storage/development.sqlite3")
#   rows = Cybertrain::DB.with { |c| c.execute("SELECT * FROM posts WHERE id = ?", [1]) }
#   Cybertrain::DB.transaction(immediate: true) { |c| c.execute("UPDATE ...", [...]) }
require "cybertrain/db/error"
require "cybertrain/db/sqlite_ffi"
require "cybertrain/db/connection"
require "cybertrain/db/pool"

module Cybertrain
  # SQLite access: the process-wide connection pool and its transactions.
  module DB
    # A module-level ivar, not @@pool: see spikes/NOTES.md rule 18.
    @pool = nil
    # Counts connects, so that code which prepares a database once (Job's
    # table) can tell a new database from the one it prepared.
    @generation = 0

    def self.connect(path, size: 4)
      disconnect
      @generation += 1
      @pool = Pool.new(path, size)
    end

    # How many times {DB.connect} has run in this process.
    def self.generation
      @generation
    end

    def self.pool
      @pool
    end

    def self.connected?
      !@pool.nil?
    end

    # Returns the block's value. Forward the block with &block: re-yielding
    # from an inner block loses the value under Spinel.
    #
    # Use that value directly only when it is a builtin (the rows of
    # `c.execute`, an Integer from `c.changes`, a String, true/false). An
    # instance of an application class comes back untyped on Spinel
    # 2026.10.26.7019, and calling a method on it raises NoMethodError
    # (spikes/NOTES.md rule 77). Assign it to a local declared before the
    # block instead, as for DB.transaction:
    #
    #   result = LoginResult.new("none")
    #   Cybertrain::DB.with { |c| result = AUTH.login(c, name) }
    #   result
    #
    # Inside a `transaction` block on the same thread, the block gets the
    # transaction's connection rather than a second one from the pool, so
    # what it runs (a Model's save, a Relation's query) is part of that
    # transaction, and a one-connection pool (":memory:") does not wait on
    # itself forever.
    def self.with(&block)
      current = @pool
      raise Error, "not connected: call Cybertrain::DB.connect first" if current.nil?
      current.with(&block)
    end

    # Checks a connection out, opens a transaction on it (BEGIN, or BEGIN
    # IMMEDIATE), yields the connection, COMMITs when the block returns and
    # ROLLBACKs and re-raises when it raises; the connection goes back to the
    # pool either way. Callable wherever `with` is, including from a
    # controller action and from a method that also calls DB.with.
    #
    #   Cybertrain::DB.transaction(immediate: true) do |c|
    #     c.execute("UPDATE accounts SET balance = balance - ? WHERE id = ?", [amount, from_id])
    #     c.execute("UPDATE accounts SET balance = balance + ? WHERE id = ?", [amount, to_id])
    #   end
    #
    # Everything on this thread that goes through DB.with while the block
    # runs (Model#save, Relation queries) uses the transaction's connection
    # and so joins the transaction. A DB.transaction (or a `c.begin!` ...
    # `c.commit!` pair) nested in the block joins it as one more level, with
    # the depth count of Connection#transaction: only the outermost level
    # COMMITs, and a raise anywhere rolls the whole transaction back once it
    # reaches the outermost block. There are no savepoints. A nested level
    # raises Cybertrain::DB::Error when SQLite already rolled the transaction
    # back on its own (SQLITE_FULL / IOERR / BUSY rescued inside the block).
    # Not `c.transaction { }` on the block's `c`: like DB.with's, it is a
    # boxed value under Spinel, and a yielding method cannot be called on one
    # (spikes/NOTES.md rule 67).
    #
    # `immediate: true` takes SQLite's write lock at BEGIN: use it for a
    # transaction that reads and then writes, so that a concurrent writer
    # makes it wait at the start (SQLite's busy handler, about five seconds)
    # instead of failing with "database is locked" at its first write. It has
    # no effect on a nested call. A thread started inside the block is not
    # part of the transaction, and neither is a DB.with block that encloses
    # the call: called from inside `DB.with { |c| ... }`, DB.transaction checks
    # out a second connection (on a one-connection pool such as ":memory:"
    # it then waits forever, as a nested DB.with does), so open the
    # transaction first and do the work inside it.
    #
    # Returns nil, not the block's value (one generic return type does not
    # type-check under Spinel): assign what the block computes to a local
    # declared before it. Do not `break` or `return` out of the block (see
    # Connection#transaction).
    # @param immediate [Boolean] BEGIN IMMEDIATE instead of BEGIN
    # @yieldparam conn [Cybertrain::DB::Connection] the transaction's connection
    # @return [nil]
    # @raise [Cybertrain::DB::Error] when not connected, when BEGIN or COMMIT
    #   fails (the transaction is rolled back), or as above; and whatever the
    #   block raised, after the rollback
    # @api public
    def self.transaction(immediate: false, &block)
      run_transaction(immediate, block)
    end

    # DB.transaction's body, taking the block as a plain Proc, the shape of
    # Controller#process and #run_action. A method that takes `&block` and
    # calls it is inlined at every call site like a yielding one, and there
    # the rescue below hits NOTES rules 32/45 and the ensure fails in the C
    # ("returning 'sp_RbVal' but 'sp_int' was expected"); one level down,
    # as a plain parameter, it compiles. Not two levels down: a Proc passed
    # on once more (to a Pool or Connection method that calls it) reached
    # `block.call` without the class of the connection, and every method
    # called on the block's parameter raised NoMethodError (NOTES rule 69).
    # So the checkout, the transaction and the block call all live here.
    def self.run_transaction(immediate, block)
      current = @pool
      raise Error, "not connected: call Cybertrain::DB.connect first" if current.nil?
      i = current.held_index
      joined = i >= 0
      conn = joined ? current.connection_at(i) : current.checkout_transaction
      begin
        conn.begin!(immediate: immediate)
        begin
          block.call(conn)
        rescue JSON::NestingError, JSON::ParserError, StandardError => e
          conn.rollback!
          raise e
        end
        conn.commit!
      ensure
        current.checkin_transaction(conn) unless joined
      end
      nil
    end

    def self.disconnect
      current = @pool
      current.close_all unless current.nil?
      @pool = nil
    end
  end
end
