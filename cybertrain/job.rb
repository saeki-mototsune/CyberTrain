require "json"
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
  # The worker is a {Scheduler} task the framework adds when the server
  # starts (and {Config#worker} is on): every {Config#job_poll_interval}
  # seconds it claims the oldest due row, runs its handler and marks it
  # `done`; a handler that raises is retried after 1, 5, 15 and then 60
  # minutes, until {Config#job_max_attempts} attempts have failed, when the
  # row is left `failed` with the error in `last_error`.
  # @api public
  module Job
    # One registered handler. Distinctive accessor names and no #call
    # (spikes/NOTES.md rules 10/34/40), like Main::Command.
    class Handler
      attr_reader :handler_kind, :handler_block

      def initialize(handler_kind, handler_block)
        @handler_kind = handler_kind
        @handler_block = handler_block
      end
    end

    # The registry: a constant (class variables are not GC roots, NOTES
    # rule 64), seeded with its element type and emptied (rule 9).
    HANDLERS = Array.new(0) { Handler.new("", nil) }

    # Seconds to wait before the retry after the 1st, 2nd, 3rd and every
    # later failed attempt.
    BACKOFF = [60, 300, 900, 3600].freeze

    # last_error keeps at most this many characters of the message.
    MAX_ERROR_LENGTH = 1000

    # The most due jobs one poll works through before the worker yields to
    # the next tick: a SQLite call holds its OS worker until it returns, so
    # an unbounded drain could keep requests waiting.
    JOBS_PER_POLL = 20

    TABLE = "cybertrain_jobs"

    # Times are Integer epoch seconds (UTC), not DATETIME text: the worker
    # compares run_at with `now` in SQL and needs no parsing. The index
    # serves the worker's "oldest due queued row" query.
    TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_jobs (" \
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
                "kind TEXT NOT NULL, " \
                "payload TEXT NOT NULL DEFAULT '', " \
                "run_at INTEGER NOT NULL, " \
                "attempts INTEGER NOT NULL DEFAULT 0, " \
                "last_error TEXT NOT NULL DEFAULT '', " \
                "state TEXT NOT NULL DEFAULT 'queued', " \
                "created_at INTEGER NOT NULL, " \
                "updated_at INTEGER NOT NULL); " \
                "CREATE INDEX IF NOT EXISTS index_cybertrain_jobs_on_state_and_run_at " \
                "ON cybertrain_jobs (state, run_at);"

    # The DB.generation the table was last ensured for; -1 for never.
    @installed_generation = -1

    # Registers the code that runs jobs of `kind`. The block receives the
    # payload String given to {Job.enqueue} (encode structured data as JSON
    # yourself) and should return normally when the work is done; raising
    # marks the attempt failed and schedules a retry. Register every handler
    # in every process (bin/<app>.rb runs before Main.run in all of them):
    # {Job.enqueue} refuses a kind with no handler.
    #
    # A handler runs on the scheduler's thread, outside any request and
    # outside any transaction. Keep it short: a SQLite call holds the OS
    # worker, so with `SPINEL_WORKERS=1` a long one stalls every request
    # (batch big work over several jobs).
    # @example
    #   Cybertrain::Job.handle("notify") { |payload| Notifier.post(payload) }
    # @param kind [String] the name jobs are enqueued under
    # @yieldparam payload [String]
    # @return [nil]
    # @raise [ArgumentError] for an empty kind or one already registered
    # @api public
    def self.handle(kind, &block)
      raise ArgumentError, "Job.handle: the kind is empty" if kind.empty?
      raise ArgumentError, "Job.handle #{kind.inspect}: already registered" if handler_index(kind) >= 0

      HANDLERS << Handler.new(kind, block)
      nil
    end

    # True once some handler is registered (the scheduler starts the worker
    # task only then).
    # @return [Boolean]
    # @api public
    def self.handlers?
      !HANDLERS.empty?
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

    # Creates the table and its index if they are missing. The worker and
    # {Job.enqueue} call it once per connected database; call it yourself
    # only to create the table ahead of time.
    # @return [nil]
    # @api public
    def self.install!
      DB.with { |c| c.exec_script(TABLE_SQL) }
      # SQLite's DDL is transactional: a table created inside a
      # DB.transaction that later rolls back is gone again, so only a
      # CREATE outside one is remembered.
      pool = DB.pool
      @installed_generation = DB.generation if !pool.nil? && pool.held_index < 0
      nil
    end

    # install! unless it already ran since the last DB.connect.
    def self.ensure_installed
      install! unless @installed_generation == DB.generation
      nil
    end

    # Puts rows a previous process left `running` (it died mid-job) back in
    # the queue; the scheduler calls it when it starts the worker. Only one
    # process may run the worker per database ({Config#worker}), so at that
    # point no other process can be running them. Their attempt was already
    # counted when it was claimed.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many rows were requeued
    # @api public
    def self.recover!(now)
      ensure_installed
      count = 0
      DB.with do |c|
        c.execute("UPDATE cybertrain_jobs SET state = 'queued', updated_at = ? WHERE state = 'running'", [now])
        count = c.changes
      end
      count
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
      id = -1
      kind = ""
      payload = ""
      attempts = 0
      # The claim is its own short BEGIN IMMEDIATE transaction: the SELECT
      # and the UPDATE run under the write lock, and the `state = 'queued'`
      # guard with the changes check refuses a row another claimer took.
      # The handler runs after the COMMIT, holding no lock.
      DB.transaction(immediate: true) do |c|
        rows = c.execute("SELECT id, kind, payload, attempts FROM cybertrain_jobs " \
                         "WHERE state = 'queued' AND run_at <= ? ORDER BY run_at, id LIMIT 1", [now])
        unless rows.empty?
          row = rows[0]
          found = Cast.int(row["id"])
          c.execute("UPDATE cybertrain_jobs SET state = 'running', attempts = attempts + 1, updated_at = ? " \
                    "WHERE id = ? AND state = 'queued'", [now, found])
          if c.changes == 1
            id = found
            kind = Cast.str(row["kind"])
            payload = Cast.str(row["payload"])
            attempts = Cast.int(row["attempts"]) + 1
          end
        end
      end
      return false if id < 0

      finish(id, kind, payload, attempts, now)
      true
    end

    # Works through due jobs, at most `limit` of them; the worker task's
    # body. Returns how many it claimed.
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

    # Runs a claimed job's handler and writes the outcome back.
    def self.finish(id, kind, payload, attempts, now)
      logger = Cybertrain.logger
      index = handler_index(kind)
      if index < 0
        message = "no handler registered for kind #{kind.inspect}"
        record(id, "failed", now, message, now)
        logger.error("job #{id} (#{kind}) failed: #{message}")
        return nil
      end
      error = run_handler(HANDLERS[index], payload)
      if error.empty?
        record(id, "done", now, "", now)
        logger.info("job #{id} (#{kind}) done")
        return nil
      end
      max = Cybertrain.config.job_max_attempts
      if attempts >= max
        record(id, "failed", now, error, now)
        logger.error("job #{id} (#{kind}) failed after #{attempts} attempts: #{error}")
      else
        wait = backoff(attempts)
        record(id, "queued", now + wait, error, now)
        logger.error("job #{id} (#{kind}) attempt #{attempts} of #{max} failed: #{error}; retrying in #{wait} s")
      end
      nil
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

    def self.record(id, state, run_at, error, now)
      binds = Cast.binds(state, run_at, error, now, id)
      DB.with do |c|
        c.execute("UPDATE cybertrain_jobs SET state = ?, run_at = ?, last_error = ?, updated_at = ? WHERE id = ?", binds)
      end
      nil
    end
  end
end
