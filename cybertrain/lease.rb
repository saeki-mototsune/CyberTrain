require "cybertrain/cast"
require "cybertrain/db"

module Cybertrain
  # Cybertrain::Lease -- a named lock with an expiry, kept in the
  # application's database, so that of several processes sharing one
  # SQLite file exactly one does a thing at a time (the {Scheduler}'s
  # recurring tasks).
  #
  #   if Cybertrain::Lease.acquire("scheduler", holder, Time.current.to_i, ttl: 30)
  #     # this process holds "scheduler" for the next 30 s; acquire again
  #     # before then to keep it
  #   end
  #
  # The rows live in `cybertrain_leases`, which the framework creates itself
  # (`CREATE TABLE IF NOT EXISTS`, on first use) and leaves out of
  # `db/schema.rb`, like `cybertrain_jobs`.
  # @api public
  module Lease
    TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_leases (" \
                "name TEXT PRIMARY KEY, " \
                "holder TEXT NOT NULL, " \
                "expires_at INTEGER NOT NULL);"

    # One statement takes a free lease, renews our own, and takes over an
    # expired one; a lease another holder still has is left alone (the DO
    # UPDATE's WHERE is false, so no row changes).
    ACQUIRE_SQL = "INSERT INTO cybertrain_leases (name, holder, expires_at) VALUES (?, ?, ?) " \
                  "ON CONFLICT(name) DO UPDATE SET holder = excluded.holder, expires_at = excluded.expires_at " \
                  "WHERE cybertrain_leases.holder = excluded.holder OR cybertrain_leases.expires_at < ?"

    # The DB.generation the table was last ensured for; -1 for never (as
    # Job's).
    @installed_generation = -1

    # Creates the table if it is missing. {Lease.acquire} and
    # {Lease.release} call it once per connected database.
    # @return [nil]
    # @api public
    def self.install!
      DB.with { |c| c.exec_script(TABLE_SQL) }
      # A CREATE inside a transaction that rolls back is undone, so only one
      # outside a transaction is remembered (as Job.install! does).
      pool = DB.pool
      @installed_generation = DB.generation if !pool.nil? && pool.held_index < 0
      nil
    end

    # install! unless it already ran since the last DB.connect.
    def self.ensure_installed
      install! unless @installed_generation == DB.generation
      nil
    end

    # Takes or renews the lease `name` for `holder` until `now + ttl`: true
    # when the lease was free, already `holder`'s, or expired (its
    # expires_at before `now`); false while another holder has it.
    # @param name [String]
    # @param holder [String] who asks, unique per process
    # @param now [Integer] epoch seconds
    # @param ttl [Integer] seconds the lease lasts unless renewed
    # @return [Boolean]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.acquire(name, holder, now, ttl:)
      ensure_installed
      binds = Cast.binds(name, holder, now + ttl, now)
      won = false
      DB.with do |c|
        c.execute(ACQUIRE_SQL, binds)
        won = c.changes == 1
      end
      won
    end

    # Gives the lease up if `holder` has it (another holder's is left), so
    # another process can take it at once instead of after the ttl.
    # @param name [String]
    # @param holder [String]
    # @return [nil]
    # @api public
    def self.release(name, holder)
      ensure_installed
      binds = Cast.binds(name, holder)
      DB.with { |c| c.execute("DELETE FROM cybertrain_leases WHERE name = ? AND holder = ?", binds) }
      nil
    end

    # Who holds `name`, "" when no row exists (the lease may have expired:
    # compare {Lease.lease_expires_at} with the time). For a status page.
    # @param name [String]
    # @return [String]
    # @api public
    def self.lease_holder(name)
      ensure_installed
      rows = DB.with { |c| c.execute("SELECT holder FROM cybertrain_leases WHERE name = ?", [name]) }
      return "" if rows.empty?

      Cast.str(rows[0]["holder"])
    end

    # When `name`'s lease runs out, epoch seconds; 0 when no row exists.
    # @param name [String]
    # @return [Integer]
    # @api public
    def self.lease_expires_at(name)
      ensure_installed
      rows = DB.with { |c| c.execute("SELECT expires_at FROM cybertrain_leases WHERE name = ?", [name]) }
      return 0 if rows.empty?

      Cast.int(rows[0]["expires_at"])
    end
  end
end
