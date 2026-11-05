require "json"
require "socket"
require "securerandom"
require "cybertrain/logger"
require "cybertrain/cast"
require "cybertrain/config"
require "cybertrain/db"

module Cybertrain
  # Cybertrain::Job -- a small database-backed job queue: "do this later,
  # and retry it if it fails". Rows live in the application's own SQLite
  # database, in the `cybertrain_jobs` table, which the framework creates
  # itself (`CREATE TABLE IF NOT EXISTS`, on the first enqueue or when the
  # worker starts) and leaves out of `db/schema.rb`.
  #
  #   # bin/<app>.rb (or a file it requires), before Cybertrain::Main.run:
  #   Cybertrain::Job.handle("welcome_mail") do |payload|
  #     data = JSON.parse(payload)
  #     Mailer.deliver_welcome(data["email"].to_s)
  #   end
  #
  #   # in an action, after saving the user:
  #   Cybertrain::Job.enqueue("welcome_mail", JSON.generate({ "email" => user.email }))
  #
  # A process that runs jobs (`./<app> server` unless {Config#worker} is
  # off, and `./<app> worker`) starts {Config#job_threads} job threads
  # ({Job.start!}). Each claims the oldest due row, runs its handler and
  # marks it `done`, then looks again, waiting {Config#job_poll_interval}
  # seconds when nothing is due; a handler that raises is retried after 1,
  # 5, 15 and then 60 minutes, until {Config#job_max_attempts} attempts have
  # failed, when the row is left `failed` with the error in `last_error`.
  # A heartbeat thread marks the process's running rows alive every
  # {Config#job_heartbeat_interval} seconds, and {Job.recover!} queues again
  # the rows of a process that stopped beating ({Config#job_heartbeat_stale}),
  # so several worker processes can share one database.
  # @api public
  module Job
    # One registered handler. Distinctive accessor names and no #call
    # (spikes/NOTES.md rules 10/34/40), like Main::Command.
    class Handler
      # handler_concurrency: the most jobs of this kind that may be
      # `running` at once across every process sharing the database; 0 for
      # no limit.
      attr_reader :handler_kind, :handler_block, :handler_concurrency

      def initialize(handler_kind, handler_block, handler_concurrency)
        @handler_kind = handler_kind
        @handler_block = handler_block
        @handler_concurrency = handler_concurrency
      end
    end

    # The registry: a constant (class variables are not GC roots, NOTES
    # rule 64), seeded with its element type and emptied (rule 9).
    HANDLERS = Array.new(0) { Handler.new("", nil, 0) }

    # Seconds to wait before the retry after the 1st, 2nd, 3rd and every
    # later failed attempt.
    BACKOFF = [60, 300, 900, 3600].freeze

    # last_error keeps at most this many characters of the message.
    MAX_ERROR_LENGTH = 1000

    # Job.work_due's default bound: a SQLite call holds its OS worker until
    # it returns, so an unbounded drain could keep requests waiting.
    JOBS_PER_POLL = 20

    TABLE = "cybertrain_jobs"

    # Times are Integer epoch seconds (UTC), not DATETIME text: the worker
    # compares run_at with `now` in SQL and needs no parsing. The index
    # serves the worker's "oldest due queued row" query.
    # claimed_by is the claiming process's {Job.process_label} and
    # heartbeat_at the last time that process said the job still runs
    # ({Job.heartbeat!}); both are NULL until the first claim. A table made
    # before they existed gets them from install! (ALTER_COLUMNS).
    TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_jobs (" \
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
                "kind TEXT NOT NULL, " \
                "payload TEXT NOT NULL DEFAULT '', " \
                "run_at INTEGER NOT NULL, " \
                "attempts INTEGER NOT NULL DEFAULT 0, " \
                "last_error TEXT NOT NULL DEFAULT '', " \
                "state TEXT NOT NULL DEFAULT 'queued', " \
                "created_at INTEGER NOT NULL, " \
                "updated_at INTEGER NOT NULL, " \
                "claimed_by TEXT, " \
                "heartbeat_at INTEGER); " \
                "CREATE INDEX IF NOT EXISTS index_cybertrain_jobs_on_state_and_run_at " \
                "ON cybertrain_jobs (state, run_at);"

    # The columns added after the table's first release, each with the
    # ALTER TABLE that adds it to an older table.
    ALTER_COLUMNS = [
      ["claimed_by", "ALTER TABLE cybertrain_jobs ADD COLUMN claimed_by TEXT"],
      ["heartbeat_at", "ALTER TABLE cybertrain_jobs ADD COLUMN heartbeat_at INTEGER"]
    ].freeze

    # The DB.generation the table was last ensured for; -1 for never.
    @installed_generation = -1

    # Job.process_label, computed on first use; "" until then.
    @process_label = ""

    # Guards @live_loops and IN_FLIGHT, which every job thread changes and
    # stop! and the heartbeat thread read.
    LOCK = Mutex.new

    # The ids of the jobs this process has claimed and not yet finished
    # writing the outcome of: the only rows its heartbeat keeps alive. A
    # constant (NOTES rule 64), seeded and emptied (rule 9).
    IN_FLIGHT = Array.new(0) { 0 }

    # How many times an outcome write is tried before the row is left to
    # staleness recovery, and the pause before each retry (times the try).
    OUTCOME_TRIES = 3
    OUTCOME_RETRY_PAUSE = 0.05

    # How long an idle wait sleeps between looks at the stop flag.
    WAIT_SLICE = 0.1

    # The thread pool's state (module ivars, not class variables: NOTES
    # rules 18/64). @generation counts start!s: a loop left from before a
    # stop! sees a newer number and ends instead of running beside the new
    # pool. The intervals are copied from the Config start! was given.
    # @running is "claim more jobs" (request_stop clears it, from a trap);
    # @started is "the pool exists" (until stop! has drained it).
    @running = false
    @started = false
    @generation = 0
    @live_loops = 0
    @poll_interval = 1
    @heartbeat_interval = 30
    @drain_timeout = 10
    # Config#job_heartbeat_stale of the last start!; 0 before one (recover!
    # then reads Cybertrain.config).
    @heartbeat_stale = 0
    # Monotonic seconds when a job thread first saw the stop; 0.0 until
    # then. Written by the threads, not the trap (no clock call in a
    # signal handler).
    @stop_seen_at = 0.0
    # Test hook: how many outcome writes still fail on purpose.
    @failing_outcome_writes = 0

    # Registers the code that runs jobs of `kind`. The block receives the
    # payload String given to {Job.enqueue} (encode structured data as JSON
    # yourself) and should return normally when the work is done; raising
    # marks the attempt failed and schedules a retry. Register every handler
    # in every process (bin/<app>.rb runs before Main.run in all of them):
    # {Job.enqueue} refuses a kind with no handler.
    #
    # A handler runs on one of the job threads ({Job.start!}), outside any
    # request and outside any transaction. A SQLite call holds the OS
    # worker, so with `SPINEL_WORKERS=1` a long query stalls every request
    # (batch big work over several jobs).
    #
    # `concurrency: n` caps how many jobs of this kind run at once, counted
    # over every process sharing the database (a paid API that must not be
    # called twice at a time: `concurrency: 1`); 0, the default, is no cap.
    # The count is of `running` rows, so a job of a process that died keeps
    # its slot until it is recovered ({Config#job_heartbeat_stale} plus up
    # to a minute: 5 to 6 minutes by default).
    #
    # Delivery is at least once: a job whose process stopped beating (it
    # died, or was stopped mid-job) runs again elsewhere, so write handlers
    # that do no harm when they run twice.
    # @example
    #   Cybertrain::Job.handle("notify") { |payload| Notifier.post(payload) }
    #   Cybertrain::Job.handle("quote", concurrency: 1) { |payload| PaidApi.fetch(payload) }
    # @param kind [String] the name jobs are enqueued under
    # @param concurrency [Integer] the most running at once; 0 for no limit
    # @yieldparam payload [String]
    # @return [nil]
    # @raise [ArgumentError] for an empty kind, one already registered, or a
    #   negative concurrency
    # @api public
    def self.handle(kind, concurrency: 0, &block)
      raise ArgumentError, "Job.handle: the kind is empty" if kind.empty?
      raise ArgumentError, "Job.handle #{kind.inspect}: already registered" if handler_index(kind) >= 0
      if concurrency < 0
        raise ArgumentError, "Job.handle #{kind.inspect}: concurrency must be 0 (no limit) or more (got #{concurrency})"
      end

      HANDLERS << Handler.new(kind, block, concurrency)
      nil
    end

    # Who this process is in `claimed_by`: "<hostname>:<pid>:<epoch of the
    # first call>:<6 random hex digits>", computed once, so neither two
    # processes on one host nor a container restarted within the same
    # second with the same pid share a label.
    # @return [String]
    # @api public
    def self.process_label
      label = @process_label
      if label.empty?
        label = "#{Socket.gethostname}:#{Process.pid}:#{Time.now.to_i}:#{SecureRandom.hex(3)}"
        @process_label = label
      end
      label
    end

    # Replaces {Job.process_label} (tests that play two processes in one;
    # "" computes the real one again on next use). Returns the label it
    # replaced.
    # @param label [String]
    # @return [String]
    # @api private
    def self.override_process_label(label)
      old = @process_label
      @process_label = label
      old
    end

    # True once some handler is registered ({Job.start!} starts the job
    # threads only then).
    # @return [Boolean]
    # @api public
    def self.handlers?
      !HANDLERS.empty?
    end

    # Starts {Config#job_threads} job threads and the heartbeat thread,
    # unless no handler is registered or they already run. It first
    # creates the table if needed and queues again the rows whose heartbeat
    # is stale ({Job.recover!}). The database must be connected.
    # Application#serve calls it (when {Config#worker} is on) after
    # Scheduler.start!, and so does `./<app> worker`; the caller decides
    # whether this process runs jobs.
    # @param config [Config]
    # @return [Boolean] true when it started the threads
    # @api public
    def self.start!(config = Cybertrain.config)
      return false if @started
      unless handlers?
        Cybertrain.logger.info("No job handler registered; job threads not started")
        return false
      end

      install!
      @heartbeat_stale = config.job_heartbeat_stale
      now = Time.now.to_i
      requeued = recover!(now, config.job_heartbeat_stale)
      Cybertrain.logger.warn("Requeued #{requeued} job(s) whose process stopped sending heartbeats") if requeued > 0
      # spikes/NOTES.md rule 22: before the first Thread.new.
      ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
      @poll_interval = config.job_poll_interval
      @heartbeat_interval = config.job_heartbeat_interval
      @drain_timeout = config.job_drain_timeout
      @stop_seen_at = 0.0
      @started = true
      @running = true
      @generation += 1
      generation = @generation
      count = config.job_threads
      Cybertrain.logger.info("Job threads started: #{count} (#{process_label})")
      i = 0
      while i < count
        loop_started
        spawn_job_thread(i, generation)
        i += 1
      end
      spawn_heartbeat(generation)
      true
    end

    # Asks the job threads to end and waits, at most
    # {Config#job_drain_timeout} seconds from when they first saw the stop
    # (a {Job.request_stop} earlier, during the server's drain, counts), for
    # those running a job to finish it. A job still running then keeps its
    # row `running`; its heartbeat has stopped, so another process's
    # {Job.recover!} queues it again once it is stale. Does nothing when
    # the threads do not run.
    # @return [nil]
    # @api public
    def self.stop!
      return nil unless @started

      @running = false
      seen = stop_seen_at
      started_at = seen > 0.0 ? seen : Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ends_at = started_at + @drain_timeout
      while live_loops > 0 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends_at
        sleep 0.05
      end
      @started = false
      left = live_loops
      Cybertrain.logger.warn("#{left} job(s) still running at shutdown; left to heartbeat recovery") if left > 0
      nil
    end

    # Tells the job threads to claim nothing more, and nothing else: safe
    # in a signal handler (Application#serve's TERM trap calls it next to
    # the server's request_stop, so the jobs drain during the requests'
    # drain). {Job.stop!} still has to be called to wait for them.
    # @return [nil]
    # @api public
    def self.request_stop
      @running = false
      nil
    end

    # @return [Boolean] true between {Job.start!} and {Job.stop!} (or
    #   {Job.request_stop})
    # @api public
    def self.running?
      @running
    end

    # When a job thread first saw the stop (monotonic seconds), 0.0 before.
    def self.stop_seen_at
      at = 0.0
      LOCK.synchronize { at = @stop_seen_at }
      at
    end

    def self.note_stop_seen
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      LOCK.synchronize { @stop_seen_at = now if @stop_seen_at == 0.0 }
      nil
    end

    # How many job threads have not ended yet (a thread finishing its job
    # after stop! counts until it has).
    # @api private
    def self.live_loops
      n = 0
      LOCK.synchronize { n = @live_loops }
      n
    end

    def self.loop_started
      LOCK.synchronize { @live_loops += 1 }
      nil
    end

    def self.loop_ended
      LOCK.synchronize { @live_loops -= 1 }
      nil
    end

    def self.pool_live?(generation)
      @running && @generation == generation
    end

    # Through a method whose parameters the closure captures (NOTES rule
    # 21), as Scheduler.spawn_loop.
    def self.spawn_job_thread(index, generation)
      Thread.new { run_job_loop(index, generation) }
    end

    # One job thread: claim and run a due job, or wait a poll interval,
    # until stop!. A job that is running when stop! comes is finished first.
    def self.run_job_loop(index, generation)
      while pool_live?(generation)
        idle_wait(@poll_interval, generation) unless claim_safely(Time.now.to_i, index)
      end
      note_stop_seen
      loop_ended
      nil
    end

    # work_one with its rescue in a plain method (NOTES rules 32/45): a
    # database error (locked past the busy timeout, a disk error) is logged
    # and the thread waits a poll interval instead of dying. False then.
    def self.claim_safely(now, index)
      work_one(now)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Job thread #{index}: #{e.class.name}: #{e.message}")
      false
    end

    # Sleeps `seconds` in WAIT_SLICE steps, returning early once the pool
    # is stopped.
    def self.idle_wait(seconds, generation)
      ends_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      while pool_live?(generation) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends_at
        sleep WAIT_SLICE
      end
      nil
    end

    def self.spawn_heartbeat(generation)
      Thread.new { run_heartbeat(generation) }
    end

    # The heartbeat thread: heartbeat! every job_heartbeat_interval seconds
    # until stop!.
    def self.run_heartbeat(generation)
      while pool_live?(generation)
        idle_wait(@heartbeat_interval, generation)
        beat_safely(Time.now.to_i) if pool_live?(generation)
      end
      # The heartbeat thread is never busy with a job, so it is the one
      # that notices a request_stop within WAIT_SLICE.
      note_stop_seen
      nil
    end

    def self.beat_safely(now)
      heartbeat!(now)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Job heartbeat: #{e.class.name}: #{e.message}")
      0
    end

    # The index of kind's handler in HANDLERS, -1 when none (an Integer
    # rather than a nullable Handler: NOTES rules 11/56).
    def self.handler_index(kind)
      i = 0
      while i < HANDLERS.size
        return i if HANDLERS[i].handler_kind == kind
        i += 1
      end
      -1
    end

    # Adds a job: a `queued` row that the worker runs at or after `run_at`.
    # Callable from an action, a {Main.command} block or a handler, in any
    # process connected to the database, whether or not it runs the worker.
    # Inside a {DB.transaction} block the row is part of the transaction, so
    # a job is only enqueued if the work that asked for it commits.
    # @example run in ten minutes
    #   Cybertrain::Job.enqueue("reminder", order.id.to_s, run_at: Time.now + 600)
    # @param kind [String] a kind registered with {Job.handle}
    # @param payload [String] handed to the handler as it is
    # @param run_at [Time] the earliest time to run it (now by default)
    # @return [Integer] the job's id
    # @raise [ArgumentError] when no handler is registered for kind
    # @raise [Cybertrain::DB::Error] when the database is not connected or
    #   the insert fails
    # @api public
    def self.enqueue(kind, payload, run_at: Time.now)
      raise ArgumentError, "Job.enqueue: no handler registered for #{kind.inspect}" if handler_index(kind) < 0

      ensure_installed
      now = Time.now.to_i
      binds = Cast.binds(kind, payload, run_at.to_i, now, now)
      id = 0
      DB.with do |c|
        c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?)", binds)
        id = c.last_insert_id
      end
      id
    end

    # Creates the table and its index if they are missing, and adds the
    # columns a table made by an earlier release lacks (`claimed_by`,
    # `heartbeat_at`; a row such a release left `running` keeps a NULL
    # heartbeat, which {Job.recover!} requeues at once). The
    # job threads and {Job.enqueue} call it once per connected database;
    # call it yourself only to create the table ahead of time.
    # @return [nil]
    # @api public
    def self.install!
      DB.with { |c| c.exec_script(TABLE_SQL) }
      add_missing_columns
      # SQLite's DDL is transactional: a table created inside a
      # DB.transaction that later rolls back is gone again, so only a
      # CREATE outside one is remembered.
      pool = DB.pool
      @installed_generation = DB.generation if !pool.nil? && pool.held_index < 0
      nil
    end

    # The ALTER TABLEs of the ALTER_COLUMNS `PRAGMA table_info` does not
    # list. Two processes upgrading at once could both see a column missing:
    # outside a transaction the read and the ALTERs run under the write lock
    # (BEGIN IMMEDIATE), and a "duplicate column name" from a process that
    # still won the race (inside a caller's transaction, or an older
    # release's ALTER) is taken as "already there" and the check runs again.
    def self.add_missing_columns
      add_columns_once
    rescue Cybertrain::DB::Error => e
      raise e unless e.message.include?("duplicate column")

      add_columns_once
    end

    def self.add_columns_once
      pool = DB.pool
      if !pool.nil? && pool.held_index < 0
        DB.transaction(immediate: true) { |c| alter_missing(c) }
      else
        DB.with { |c| alter_missing(c) }
      end
      nil
    end

    def self.alter_missing(conn)
      rows = conn.execute("PRAGMA table_info('cybertrain_jobs')")
      present = Array.new(0) { "" }
      rows.each { |r| present << Cast.str(r["name"]) }
      ALTER_COLUMNS.each do |pair|
        conn.execute(pair[1]) unless present.include?(pair[0])
      end
      nil
    end

    # install! unless it already ran since the last DB.connect.
    def self.ensure_installed
      install! unless @installed_generation == DB.generation
      nil
    end

    # Puts `running` rows whose process stopped saying they run back in the
    # queue: those whose `heartbeat_at` is older than `now - stale` (the
    # process died mid-job, or was stopped before the job finished), and
    # those with no heartbeat at all (left `running` by a release before
    # heartbeats, when install! added the column: every claim since writes
    # one, so NULL is never a live job). A row
    # whose process still sends heartbeats ({Job.heartbeat!}) is never
    # touched, so every process that runs jobs may call it; the scheduler
    # does at start and once a minute. The attempt was already counted
    # when the row was claimed, so a row whose stopped attempt was its
    # last ({Config#job_max_attempts}) is left `failed` instead
    # ({Job.fail_exhausted}): a payload that kills its process is not
    # requeued for ever.
    # @param now [Integer] epoch seconds
    # @param stale [Integer] seconds without a heartbeat that make a row
    #   abandoned (by default the {Config#job_heartbeat_stale} of the
    #   Config {Job.start!} was given, or of Cybertrain.config before it)
    # @return [Integer] how many rows were requeued
    # @api public
    def self.recover!(now, stale = Job.heartbeat_stale)
      ensure_installed
      fail_exhausted(now, stale)
      binds = Cast.binds(now, now - stale)
      count = 0
      DB.with do |c|
        c.execute("UPDATE cybertrain_jobs SET state = 'queued', updated_at = ? WHERE state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)", binds)
        count = c.changes
      end
      count
    end

    # The part of recover! for rows whose stopped attempt was their last
    # ({Config#job_max_attempts}; the claim counted it): they become
    # `failed` with last_error "process stopped (heartbeat stale) during
    # attempt N of MAX", logged as a handler's last failure is, rather than
    # queued again, so a payload that kills its process is not retried for
    # ever. Each row is updated only while it is still stale and running
    # (another process may have recovered it in between).
    def self.fail_exhausted(now, stale)
      max = Cybertrain.config.job_max_attempts
      cutoff = now - stale
      ids = Array.new(0) { 0 }
      kinds = Array.new(0) { "" }
      messages = Array.new(0) { "" }
      DB.with do |c|
        rows = c.execute("SELECT id, kind, attempts FROM cybertrain_jobs WHERE state = 'running' " \
                         "AND (heartbeat_at IS NULL OR heartbeat_at < ?) AND attempts >= ? ORDER BY id",
                         Cast.binds(cutoff, max))
        rows.each do |row|
          id = Cast.int(row["id"])
          message = "process stopped (heartbeat stale) during attempt #{Cast.int(row["attempts"])} of #{max}"
          c.execute("UPDATE cybertrain_jobs SET state = 'failed', last_error = ?, updated_at = ? WHERE id = ? " \
                    "AND state = 'running' AND (heartbeat_at IS NULL OR heartbeat_at < ?)",
                    Cast.binds(message, now, id, cutoff))
          next unless c.changes > 0

          ids << id
          kinds << Cast.str(row["kind"])
          messages << message
        end
      end
      i = 0
      while i < ids.size
        Cybertrain.logger.error("job #{ids[i]} (#{kinds[i]}) failed: #{messages[i]}")
        i += 1
      end
      nil
    end

    # The stale default of recover!.
    def self.heartbeat_stale
      @heartbeat_stale > 0 ? @heartbeat_stale : Cybertrain.config.job_heartbeat_stale
    end

    # Marks the jobs this process is running now as alive at `now` (the
    # heartbeat thread does it every {Config#job_heartbeat_interval}
    # seconds), so no other process's {Job.recover!} takes them. Only rows
    # in flight here: a row whose outcome could not be written (the
    # database stayed locked) is no longer in flight, so its heartbeat stops
    # and staleness recovery runs it again, rather than it staying
    # `running` (and holding a concurrency slot) for as long as the
    # process lives. Judgement call: the spec's statement was `WHERE state
    # = 'running' AND claimed_by = ?`; this adds `AND id IN (...)`.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many rows it touched
    # @api public
    def self.heartbeat!(now)
      ensure_installed
      ids = in_flight_ids
      return 0 if ids.empty?

      binds = Cast.binds(now, process_label)
      sql = +"UPDATE cybertrain_jobs SET heartbeat_at = ? WHERE state = 'running' AND claimed_by = ? AND id IN ("
      i = 0
      while i < ids.size
        sql << ", " if i > 0
        sql << "?"
        binds << ids[i]
        i += 1
      end
      sql << ")"
      count = 0
      DB.with do |c|
        c.execute(sql, binds)
        count = c.changes
      end
      count
    end

    # A copy of IN_FLIGHT.
    def self.in_flight_ids
      out = Array.new(0) { 0 }
      LOCK.synchronize { IN_FLIGHT.each { |id| out << id } }
      out
    end

    def self.in_flight_add(id)
      LOCK.synchronize { IN_FLIGHT << id }
      nil
    end

    # Removes one entry for id (the same row can be in flight twice when it
    # was recovered and claimed again here while its first run went on).
    def self.in_flight_remove(id)
      LOCK.synchronize do
        at = IN_FLIGHT.index(id)
        IN_FLIGHT.delete_at(at) unless at.nil?
      end
      nil
    end

    # How many jobs of `kind` are `running` now, in every process sharing
    # the database.
    # @param kind [String]
    # @return [Integer]
    # @api public
    def self.running_count(kind)
      ensure_installed
      rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state = 'running' AND kind = ?", [kind]) }
      Cast.int(rows[0]["n"])
    end

    # True when some handler has a concurrency limit (only then does the
    # claim count the running rows).
    def self.limits?
      i = 0
      while i < HANDLERS.size
        return true if HANDLERS[i].handler_concurrency > 0
        i += 1
      end
      false
    end

    # The kinds whose running rows have reached their handler's limit, read
    # on the claim's connection inside its transaction.
    def self.kinds_at_limit(conn)
      full = Array.new(0) { "" }
      rows = conn.execute("SELECT kind, COUNT(*) AS n FROM cybertrain_jobs WHERE state = 'running' GROUP BY kind")
      rows.each do |r|
        kind = Cast.str(r["kind"])
        index = handler_index(kind)
        next if index < 0

        limit = HANDLERS[index].handler_concurrency
        full << kind if limit > 0 && Cast.int(r["n"]) >= limit
      end
      full
    end

    # The claim's SELECT, leaving out the `excluded` kinds (one bound `?`
    # each, after run_at's).
    def self.claim_sql(excluded)
      sql = +"SELECT id, kind, payload, attempts FROM cybertrain_jobs WHERE state = 'queued' AND run_at <= ?"
      unless excluded.empty?
        sql << " AND kind NOT IN ("
        i = 0
        while i < excluded.size
          sql << ", " if i > 0
          sql << "?"
          i += 1
        end
        sql << ")"
      end
      sql << " ORDER BY run_at, id LIMIT 1"
      sql
    end

    # Claims and runs the oldest due job, if there is one, and records the
    # outcome: `done`; `queued` again with `run_at` pushed back by {BACKOFF}
    # after a failure; `failed` once {Config#job_max_attempts} attempts have
    # failed, or at once when no handler is registered for its kind. The
    # worker calls it; tests call it with a fixed `now` instead of waiting.
    # @param now [Integer] epoch seconds: jobs with run_at <= now are due
    # @return [Boolean] true when a job was claimed
    # @api public
    def self.work_one(now)
      ensure_installed
      # A read outside any transaction first: an idle thread then takes no
      # write lock (three BEGIN IMMEDIATEs a second per process otherwise,
      # each able to hold an OS worker in the busy handler while another
      # process writes).
      return false unless due_exists?(now)

      id = -1
      kind = ""
      payload = ""
      attempts = 0
      # The claim is its own short BEGIN IMMEDIATE transaction: the SELECT
      # and the UPDATE run under the write lock, and the `state = 'queued'`
      # guard with the changes check refuses a row another claimer took.
      # The handler runs after the COMMIT, holding no lock.
      # With a concurrency limit, the kinds at their limit are read under
      # the same lock and left out, so no two claimers (threads or
      # processes) can both take a kind's last free slot.
      label = process_label
      limited = limits?
      DB.transaction(immediate: true) do |c|
        excluded = limited ? kinds_at_limit(c) : Array.new(0) { "" }
        binds = Cast.binds(now)
        excluded.each { |k| binds << k }
        rows = c.execute(claim_sql(excluded), binds)
        unless rows.empty?
          row = rows[0]
          found = Cast.int(row["id"])
          claim = Cast.binds(label, now, now, found)
          # (attempts is counted here; the outcome write is fenced by it.)
          c.execute("UPDATE cybertrain_jobs SET state = 'running', attempts = attempts + 1, claimed_by = ?, " \
                    "heartbeat_at = ?, updated_at = ? WHERE id = ? AND state = 'queued'", claim)
          if c.changes == 1
            id = found
            kind = Cast.str(row["kind"])
            payload = Cast.str(row["payload"])
            attempts = Cast.int(row["attempts"]) + 1
          end
        end
      end
      return false if id < 0

      in_flight_add(id)
      finish(id, kind, payload, attempts, now, label)
      in_flight_remove(id)
      true
    end

    # Whether some queued row is due at `now` (a plain read).
    def self.due_exists?(now)
      rows = DB.with { |c| c.execute("SELECT 1 AS one FROM cybertrain_jobs WHERE state = 'queued' AND run_at <= ? LIMIT 1", [now]) }
      !rows.empty?
    end

    # Works through due jobs, at most `limit` of them, one after another on
    # the calling thread (a {Main.command} that drains the queue, or a
    # test). Returns how many it claimed.
    # @param now [Integer] epoch seconds
    # @param limit [Integer]
    # @return [Integer]
    # @api public
    def self.work_due(now, limit = JOBS_PER_POLL)
      count = 0
      while count < limit
        break unless work_one(now)
        count += 1
      end
      count
    end

    # How many rows are in `state` ("queued", "running", "done" or
    # "failed"), e.g. for a health or admin page.
    # @param state [String]
    # @return [Integer]
    # @api public
    def self.state_count(state)
      ensure_installed
      rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state = ?", [state]) }
      Cast.int(rows[0]["n"])
    end

    # Deletes `done` rows last updated before `before` (epoch seconds), for
    # a scheduled task that keeps the table small. `failed` rows are kept
    # for a person to look at.
    # @param before [Integer] epoch seconds
    # @return [Integer] how many rows were deleted
    # @api public
    def self.prune_done(before)
      ensure_installed
      count = 0
      DB.with do |c|
        c.execute("DELETE FROM cybertrain_jobs WHERE state = 'done' AND updated_at < ?", [before])
        count = c.changes
      end
      count
    end

    # Seconds to wait after the attempts-th failed attempt (1-based).
    # @param attempts [Integer]
    # @return [Integer]
    def self.backoff(attempts)
      i = attempts - 1
      i = 0 if i < 0
      i = BACKOFF.size - 1 if i >= BACKOFF.size
      BACKOFF[i]
    end

    # Runs a claimed job's handler and writes the outcome back, fenced by
    # the claim (`label` and the attempt number): when the row was
    # recovered and claimed again while the handler ran (its heartbeat went
    # stale), the outcome is discarded and the row is left to its new
    # claimer. Delivery is therefore at least once: write handlers so that
    # running twice is harmless.
    def self.finish(id, kind, payload, attempts, now, label)
      logger = Cybertrain.logger
      index = handler_index(kind)
      if index < 0
        message = "no handler registered for kind #{kind.inspect}"
        return nil unless outcome_written?(id, kind, record_outcome(id, "failed", now, message, now, label, attempts))

        logger.error("job #{id} (#{kind}) failed: #{message}")
        return nil
      end
      error = run_handler(HANDLERS[index], payload)
      if error.empty?
        return nil unless outcome_written?(id, kind, record_outcome(id, "done", now, "", now, label, attempts))

        logger.info("job #{id} (#{kind}) done")
        return nil
      end
      max = Cybertrain.config.job_max_attempts
      if attempts >= max
        return nil unless outcome_written?(id, kind, record_outcome(id, "failed", now, error, now, label, attempts))

        logger.error("job #{id} (#{kind}) failed after #{attempts} attempts: #{error}")
      else
        wait = backoff(attempts)
        return nil unless outcome_written?(id, kind, record_outcome(id, "queued", now + wait, error, now, label, attempts))

        logger.error("job #{id} (#{kind}) attempt #{attempts} of #{max} failed: #{error}; retrying in #{wait} s")
      end
      nil
    end

    # Logs what record_outcome's code means unless the outcome was written
    # (1): 0, the row was reclaimed; -1, the write failed every try.
    def self.outcome_written?(id, kind, code)
      return true if code == 1

      if code == 0
        Cybertrain.logger.warn("job #{id} (#{kind}) finished after it was reclaimed; outcome discarded")
      else
        Cybertrain.logger.error("job #{id} (#{kind}) finished but its outcome could not be written; " \
                                "left running for heartbeat recovery")
      end
      false
    end

    # The handler call with its rescue in a plain method that receives the
    # Proc as a parameter (NOTES rules 32/45/69); JSON::NestingError named
    # first (rule 61). "" when the handler returned, else the bounded error.
    def self.run_handler(handler, payload)
      handler.handler_block.call(payload)
      ""
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      bounded_error("#{e.class.name}: #{e.message}")
    end

    # text cut to MAX_ERROR_LENGTH characters.
    def self.bounded_error(text)
      return text if text.size <= MAX_ERROR_LENGTH

      text[0, MAX_ERROR_LENGTH]
    end

    # Writes the outcome of the claim (`label`, `attempts`), trying
    # OUTCOME_TRIES times when the database raises (busy past its busy
    # timeout, a disk error): 1 when written, 0 when the row is no longer
    # running under that claim (nothing written), -1 when every try failed
    # (logged). Never raises.
    def self.record_outcome(id, state, run_at, error, now, label, attempts)
      try = 1
      while try <= OUTCOME_TRIES
        code = write_outcome_safely(id, state, run_at, error, now, label, attempts, try)
        return code if code >= 0

        sleep OUTCOME_RETRY_PAUSE * try if try < OUTCOME_TRIES
        try += 1
      end
      -1
    end

    # One try, its rescue in a plain method (NOTES rules 32/45).
    def self.write_outcome_safely(id, state, run_at, error, now, label, attempts, try)
      if @failing_outcome_writes > 0
        @failing_outcome_writes -= 1
        raise Cybertrain::DB::Error, "outcome write failed on purpose (test hook)"
      end
      binds = Cast.binds(state, run_at, error, now, id, label, attempts)
      written = 0
      DB.with do |c|
        c.execute("UPDATE cybertrain_jobs SET state = ?, run_at = ?, last_error = ?, updated_at = ? " \
                  "WHERE id = ? AND state = 'running' AND claimed_by = ? AND attempts = ?", binds)
        written = c.changes == 1 ? 1 : 0
      end
      written
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("job #{id}: outcome write #{try} of #{OUTCOME_TRIES} failed: #{e.class.name}: #{e.message}")
      -1
    end

    # Makes the next `count` outcome writes raise, for tests of a database
    # that stays locked.
    # @param count [Integer]
    # @return [nil]
    # @api private
    def self.fail_outcome_writes(count)
      @failing_outcome_writes = count
      nil
    end
  end
end
