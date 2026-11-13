require "json"
require "cybertrain/cast"
require "cybertrain/config"
require "cybertrain/db"
require "cybertrain/params"
require "cybertrain/feature"

module Cybertrain
  # Cybertrain::Cache -- a cache store in the application's own SQLite
  # database: "keep this answer for a while, so the next request does not
  # ask the slow API again".
  #
  #   require "cybertrain/cache"   # bin/<app>.rb, or a file it requires
  #
  #   text = Cybertrain::Cache.fetch("defillama/tvl", expires_in: 21_600, race_condition_ttl: 30) do
  #     client.get("https://api.llama.fi/tvl").body
  #   end
  #   data = Cybertrain::Cache.fetch_hash("prices/eth", expires_in: 60) { { "usd" => price } }
  #   Cybertrain::Cache.write("import-lock", "1", expires_in: 300, unless_exist: true) # true when written
  #
  # Values are Strings ({Cache.fetch_hash}, {Cache.fetch_array} and
  # {Cache.fetch_int} store JSON or Integer text and parse it back). Times
  # are epoch seconds from {Cache.now}. `expires_in: 0`, the default,
  # never expires; a row with `expires_at` E is live up to and including
  # second E and expired from E + 1 on.
  #
  # The rows live in `cybertrain_cache`, which the framework creates itself
  # (`CREATE TABLE IF NOT EXISTS`, on first use) and leaves out of
  # `db/schema.rb`, like `cybertrain_jobs`. Every write takes the
  # application's SQLite writer lock, which requests writing their own
  # rows wait for: cache what the jobs produce rather than in request
  # paths that write often. Nothing is kept in memory: every read is a
  # SELECT, which SQLite answers from its page cache. The expired rows are
  # deleted every {Config#cache_prune_interval} seconds ({Cache.prune}):
  # with `require "cybertrain/jobs"`, by the scheduled task
  # `"cybertrain cache prune"` (requiring both registers it); without
  # jobs, by the writes ({Cache.write}, {Cache.increment}): the first of
  # the process and the first once that interval has passed, at most
  # 1000 rows per write ({Cache.prune_if_due}).
  # @api public
  module Cache
    TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_cache (" \
                "key TEXT PRIMARY KEY, " \
                "value TEXT NOT NULL, " \
                "expires_at INTEGER, " \
                "updated_at INTEGER NOT NULL);"

    # The name of the scheduled task that prunes the table.
    PRUNE_TASK = "cybertrain cache prune"

    # Cache.prune deletes at most this many rows per statement, so the
    # writer lock is released between batches.
    PRUNE_BATCH = 1000

    # A live row: one with no expiry, or whose expiry is now or later.
    LIVE_SQL = "SELECT value FROM cybertrain_cache WHERE key = ? AND (expires_at IS NULL OR expires_at >= ?)"

    # An expires_at of 0 is stored as NULL (never expires).
    WRITE_SQL = "INSERT INTO cybertrain_cache (key, value, expires_at, updated_at) " \
                "VALUES (?, ?, NULLIF(?, 0), ?) " \
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value, " \
                "expires_at = excluded.expires_at, updated_at = excluded.updated_at"

    # write(unless_exist: true): an existing row is replaced only once it
    # has expired (the DO UPDATE's WHERE is false for a live row, so no row
    # changes).
    ADD_SQL = "#{WRITE_SQL} WHERE cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ?"

    # race_condition_ttl: an expired row is given `n` more seconds; of the
    # callers that see it expired, the one whose UPDATE changed it
    # recomputes.
    EXTEND_SQL = "UPDATE cybertrain_cache SET expires_at = ? WHERE key = ? " \
                 "AND expires_at IS NOT NULL AND expires_at < ?"

    # ?1 key, ?2 by, ?3 expires_at (0: none given), ?4 now. A missing row
    # starts at `by`, an expired one too (and loses its old expiry); a live
    # one adds `by` to its value read as an Integer (text that is not a
    # number counts as 0). A given expiry replaces the row's.
    INCREMENT_SQL = "INSERT INTO cybertrain_cache (key, value, expires_at, updated_at) " \
                    "VALUES (?1, ?2, NULLIF(?3, 0), ?4) " \
                    "ON CONFLICT(key) DO UPDATE SET " \
                    "value = CASE WHEN cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ?4 " \
                    "THEN ?2 ELSE CAST(cybertrain_cache.value AS INTEGER) + ?2 END, " \
                    "expires_at = CASE WHEN cybertrain_cache.expires_at IS NOT NULL AND cybertrain_cache.expires_at < ?4 " \
                    "THEN NULLIF(?3, 0) " \
                    "WHEN cybertrain_cache.expires_at IS NULL AND ?3 > 0 THEN ?3 " \
                    "ELSE cybertrain_cache.expires_at END, " \
                    "updated_at = ?4 " \
                    "RETURNING CAST(value AS INTEGER) AS n"

    PRUNE_SQL = "DELETE FROM cybertrain_cache WHERE rowid IN (SELECT rowid FROM cybertrain_cache " \
                "WHERE expires_at IS NOT NULL AND expires_at < ? LIMIT #{PRUNE_BATCH})"

    # The DB.generation the table was last ensured for; -1 for never (as
    # Job's and Lease's).
    @installed_generation = -1

    # Without jobs: the Cache.now of the last prune a write ran that
    # deleted less than a full batch; -1 before it (a typed initial value:
    # NOTES rule 7), which makes the first write prune.
    @last_self_prune = -1

    # The clock Cache.now reads: the system's until a test injects one.
    # Made in a method (NOTES rule 82).
    def self.system_clock
      -> { Time.now.to_i }
    end

    @clock = system_clock

    # Creates the table if it is missing. Every other method calls it once
    # per connected database; call it yourself only to create the table
    # ahead of time.
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

    # The current time as the cache sees it: the injected clock's
    # ({Cache.clock=}), `Time.now.to_i` by default.
    # @return [Integer] epoch seconds
    # @api public
    def self.now
      @clock.call
    end

    # Replaces the clock {Cache.now} reads, so a test can move time
    # instead of sleeping; `-> { Time.now.to_i }` restores the system's.
    # @example
    #   CLOCK = [1000]
    #   Cybertrain::Cache.clock = -> { CLOCK[0] }
    # @param clock [Proc] takes no arguments, answers epoch seconds
    # @return [Proc]
    # @api public
    def self.clock=(clock)
      @clock = clock
    end

    # The value stored under `key`, or the block's value, which is then
    # stored. A live row is answered without running the block. On a miss
    # (no row, or an expired one) the block runs and its value, a String
    # (anything else is stored as its `to_s`), is written with
    # `expires_in`.
    #
    # With `race_condition_ttl: n`, a caller that finds the row expired
    # first extends it by `n` seconds; only the caller whose extension
    # changed the row runs the block, and the others answer the stale
    # value meanwhile (Rails' semantics). When that block raises, nothing
    # is written and the exception propagates: the stale value is served
    # until the extension runs out. Without it, every caller of an expired
    # key runs the block. A missing row is always computed.
    # @param key [String]
    # @param expires_in [Integer] seconds the value stays live; 0 (the
    #   default) never expires (Rails' `nil`: an Integer keyword takes 0)
    # @param race_condition_ttl [Integer] seconds to serve an expired value
    #   while one caller recomputes it; 0 for none
    # @yield on a miss
    # @yieldreturn [String] the value to store
    # @return [String]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.fetch(key, expires_in: 0, race_condition_ttl: 0)
      hit = fetch_hit(key, race_condition_ttl)
      return hit.to_s unless hit.nil?

      # The block's value in a local first: an argument expression may be
      # evaluated once per branch of the inlined cast, running the block
      # twice.
      computed = yield
      value = Cast.str(computed)
      write(key, value, expires_in: expires_in)
      value
    end

    # {Cache.fetch} for a Hash, stored as JSON and parsed back with
    # {Cast.json_hash}: a corrupt cell (not a JSON object) reads as `{}`
    # until it expires and the block runs again.
    # @param key [String]
    # @param expires_in [Integer] as {Cache.fetch}'s; 0 never expires
    # @param race_condition_ttl [Integer] as {Cache.fetch}'s
    # @yield on a miss
    # @yieldreturn [Hash] the value to store
    # @return [Hash{String => Object}]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.fetch_hash(key, expires_in: 0, race_condition_ttl: 0)
      hit = fetch_hit(key, race_condition_ttl)
      return Cast.json_hash(hit.to_s) unless hit.nil?

      computed = yield
      text = JSON.generate(computed)
      write(key, text, expires_in: expires_in)
      Cast.json_hash(text)
    end

    # {Cache.fetch} for an Array, stored as JSON and parsed back with
    # {Cast.array}: a corrupt cell (not a JSON array) reads as `[]` until
    # it expires and the block runs again.
    # @param key [String]
    # @param expires_in [Integer] as {Cache.fetch}'s; 0 never expires
    # @param race_condition_ttl [Integer] as {Cache.fetch}'s
    # @yield on a miss
    # @yieldreturn [Array] the value to store
    # @return [Array<Object>]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.fetch_array(key, expires_in: 0, race_condition_ttl: 0)
      hit = fetch_hit(key, race_condition_ttl)
      return Cast.array(Cast.parse_json(hit.to_s)) unless hit.nil?

      computed = yield
      text = JSON.generate(computed)
      write(key, text, expires_in: expires_in)
      Cast.array(Cast.parse_json(text))
    end

    # {Cache.fetch} for an Integer, stored as its decimal text: a corrupt
    # cell (not an integer, or one too long to be one) reads as 0 until it
    # expires and the block runs again.
    # @param key [String]
    # @param expires_in [Integer] as {Cache.fetch}'s; 0 never expires
    # @param race_condition_ttl [Integer] as {Cache.fetch}'s
    # @yield on a miss
    # @yieldreturn [Integer] the value to store
    # @return [Integer]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.fetch_int(key, expires_in: 0, race_condition_ttl: 0)
      hit = fetch_hit(key, race_condition_ttl)
      return Params.parse_int(hit.to_s, 0) unless hit.nil?

      computed = yield
      value = Cast.int(computed)
      write(key, value.to_s, expires_in: expires_in)
      value
    end

    # What a fetch answers without running its block: the live value; or,
    # with race_ttl, the stale value another caller is recomputing. nil
    # when this caller computes: no row, or an expired one it extended
    # (or no race_ttl).
    def self.fetch_hit(key, race_ttl)
      now = Cache.now
      live = live_value(key, now)
      return live unless live.nil?
      return nil if race_ttl <= 0
      return nil if extend_stale(key, now, race_ttl)

      live_value(key, now)
    end

    # The live row's value, nil when there is none.
    def self.live_value(key, now)
      ensure_installed
      rows = DB.with { |c| c.execute(LIVE_SQL, Cast.binds(key, now)) }
      return nil if rows.empty?

      Cast.str(rows[0]["value"])
    end

    # Extends the expired row `key` to now + race_ttl; true when this call
    # changed it.
    def self.extend_stale(key, now, race_ttl)
      binds = Cast.binds(now + race_ttl, key, now)
      changed = 0
      DB.with do |c|
        c.execute(EXTEND_SQL, binds)
        changed = c.changes
      end
      changed == 1
    end

    # The live value stored under `key`; nil when there is none or it has
    # expired.
    # @param key [String]
    # @return [String, nil]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.read(key)
      live_value(key, Cache.now)
    end

    # Stores `value` under `key`, replacing any row. With `unless_exist:
    # true` a live row is left alone and the answer is false (an expired
    # one is replaced): a lock for `expires_in` seconds that one process
    # gets.
    # @param key [String]
    # @param value [String]
    # @param expires_in [Integer] seconds the value stays live; 0 (the
    #   default) never expires (Rails' `nil`: an Integer keyword takes 0)
    # @param unless_exist [Boolean] keep a live row instead of replacing it
    # @return [Boolean] true when written; false only when `unless_exist`
    #   found a live row
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.write(key, value, expires_in: 0, unless_exist: false)
      ensure_installed
      now = Cache.now
      prune_if_due(now)
      expires_at = expires_in > 0 ? now + expires_in : 0
      sql = unless_exist ? ADD_SQL : WRITE_SQL
      binds = Cast.binds(key, value, expires_at, now)
      binds << now if unless_exist
      changed = 0
      DB.with do |c|
        c.execute(sql, binds)
        changed = c.changes
      end
      changed > 0
    end

    # Removes the row of `key`, live or expired.
    # @param key [String]
    # @return [Boolean] true when there was a row
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.delete(key)
      ensure_installed
      changed = 0
      DB.with do |c|
        c.execute("DELETE FROM cybertrain_cache WHERE key = ?", [key])
        changed = c.changes
      end
      changed > 0
    end

    # Whether a live row is stored under `key`.
    # @param key [String]
    # @return [Boolean]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.exist?(key)
      !live_value(key, Cache.now).nil?
    end

    # Adds `by` to the Integer stored under `key` in one statement, and
    # answers the sum. A missing or expired row starts at `by`; a value
    # that is not a number counts as 0. `expires_in` sets the expiry of a
    # new or expired row, and of a live row that has none; a live row that
    # has one keeps it, so the counter's window is fixed from its first
    # increment (as Rails' stores do) and does not slide with every call.
    # @example A counter for the current minute
    #   Cybertrain::Cache.increment("hits/#{ip}", expires_in: 60)
    # @param key [String]
    # @param by [Integer] may be negative
    # @param expires_in [Integer] seconds the value stays live from the
    #   counter's start; 0 (the default) leaves the expiry as it is (a new
    #   row never expires)
    # @return [Integer] the new value
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.increment(key, by: 1, expires_in: 0)
      ensure_installed
      now = Cache.now
      prune_if_due(now)
      expires_at = expires_in > 0 ? now + expires_in : 0
      rows = DB.with { |c| c.execute(INCREMENT_SQL, Cast.binds(key, by, expires_at, now)) }
      return 0 if rows.empty?

      Cast.int(rows[0]["n"])
    end

    # Removes every row.
    # @return [nil]
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.clear
      ensure_installed
      DB.with { |c| c.execute("DELETE FROM cybertrain_cache") }
      nil
    end

    # Deletes the rows expired at `now` (an `expires_at` before it), at
    # most 1000 per statement so the writer lock is released between
    # batches. The scheduled task `"cybertrain cache prune"` calls it with
    # {Cache.now}.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many rows were deleted
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.prune(now)
      ensure_installed
      total = 0
      batch = PRUNE_BATCH
      while batch == PRUNE_BATCH
        batch = prune_batch(now)
        total += batch
      end
      total
    end

    # One statement of {Cache.prune}: deletes at most PRUNE_BATCH of the
    # rows expired at `now`.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many rows were deleted
    # @api private
    def self.prune_batch(now)
      deleted = 0
      DB.with do |c|
        c.execute(PRUNE_SQL, [now])
        deleted = c.changes
      end
      deleted
    end

    # Without jobs (no loaded feature runs periodic work:
    # Features.periodic_scheduler?), the prune the scheduled task would
    # run, one batch at a time: the writing caller deletes at most
    # PRUNE_BATCH expired rows when a prune is due, so a large backlog
    # drains over several writes rather than in one request. A prune is due
    # on the first write of the process (a console, a one-shot command or
    # the dev loop's re-exec prunes too), once {Config#cache_prune_interval}
    # seconds have passed since the last one, when the clock went
    # backwards, and after a full batch (more rows may be waiting: the
    # clock is not advanced, so the next write continues). With jobs it
    # does nothing: the scheduler prunes, or, with CYBERTRAIN_WORKER=0, the
    # process that runs it does. Two writers may both prune at the edge;
    # the second deletes what the first left.
    #
    # A DB::Error of the prune is logged and the caller's write goes on
    # (the next due write retries, an interval later). Inside a caller's
    # transaction the prune commits or rolls back with it: a rolled-back
    # prune is retried by the next due write, which is acceptable.
    # @param now [Integer] epoch seconds ({Cache.now})
    # @return [nil]
    # @api private
    def self.prune_if_due(now)
      return nil if Features.periodic_scheduler?

      last = @last_self_prune
      return nil if last >= 0 && now >= last && now - last < prune_interval

      begin
        deleted = prune_batch(now)
        @last_self_prune = now if deleted < PRUNE_BATCH
      rescue DB::Error => e
        @last_self_prune = now
        Cybertrain.logger.warn("cache: pruning the expired rows failed, the write goes on: #{e.message}")
      end
      nil
    end

    # Seconds between two prunes: {Config#cache_prune_interval}, at least
    # 1 (boot refuses less: {Config#scheduler_error}). It does not create
    # {Cybertrain.config}: `require "cybertrain"` reads it while
    # registering the task, and a config made then would keep the
    # environment of that moment (`development`), before a test sets
    # `CYBERTRAIN_ENV` or an embedded build's gen/views.rb defaults it to
    # production. Until the config exists, the interval comes from the
    # variable as {Config#cache_prune_interval} would read it.
    # @return [Integer]
    # @api private
    def self.prune_interval
      interval = 0
      if Cybertrain.config_loaded?
        interval = Cybertrain.config.cache_prune_interval
      else
        interval = Config.default_cache_prune_interval
      end
      interval = 1 if interval < 1
      interval
    end

    # Registers the scheduled task `"cybertrain cache prune"`, every
    # {Cache.prune_interval} seconds, when cybertrain/jobs is loaded and no
    # task of that name is registered already
    # (Features.schedule_all_periodic: JobsFeature takes on CacheFeature's
    # periodic hook). Requiring this file and cybertrain/jobs, in either order,
    # registers it; calling it again adds nothing.
    # @return [nil]
    # @api public
    def self.register_prune_task
      Features.schedule_all_periodic
      nil
    end
  end

  # The cache's feature (cybertrain/feature.rb): its prune as a periodic
  # hook, which the jobs feature runs on the scheduler.
  # @api private
  class CacheFeature < Feature
    def feature_name
      "cache"
    end

    def feature_rank
      40
    end

    def periodic_name
      Cache::PRUNE_TASK
    end

    def periodic_interval
      Cache.prune_interval
    end

    # The cache's own clock, not the scheduler's `now`: a test that
    # injects one (Cache.clock=) moves the prune with it, as the task
    # always did.
    def periodic(now)
      Cache.prune(Cache.now)
      nil
    end
  end
end

Cybertrain::Features.register_feature(Cybertrain::CacheFeature.new)
