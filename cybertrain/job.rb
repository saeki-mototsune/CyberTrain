require "json"
require "socket"
require "securerandom"
require "cybertrain/logger"
require "cybertrain/cast"
require "cybertrain/config"
require "cybertrain/db"
require "cybertrain/i18n"
# The parts Job delegates to (each opens Cybertrain::Job and reads the
# registry below only from inside its methods).
require "cybertrain/job/retry_policy"
require "cybertrain/job/store"
require "cybertrain/job/executor"
require "cybertrain/job/worker"

module Cybertrain
  # Cybertrain::Job -- a small database-backed job queue: "do this later,
  # and retry it if it fails". Rows live in the application's own SQLite
  # database, in the `cybertrain_jobs` table, which the framework creates
  # itself (`CREATE TABLE IF NOT EXISTS`, on the first enqueue or when the
  # worker starts) and leaves out of `db/schema.rb`.
  #
  # An application writes job classes in app/jobs ({Job::Base}: `perform`,
  # `retry_on`, `discard_on`, `limits_concurrency`); `spin run gen` writes
  # their `perform_later` and the {Job.register} call into gen/jobs.rb. A
  # block registered under a String kind is the short form:
  #
  #   # bin/<app>.rb (or a file it requires), before Cybertrain::Main.run:
  #   Cybertrain::Job.handle("welcome_mail") do |payload|
  #     data = JSON.parse(payload)
  #     Mailer.deliver_welcome(data["email"].to_s)
  #   end
  #
  #   # in an action, after saving the user:
  #   Cybertrain::Job.enqueue("welcome_mail", JSON.generate({ "email" => user.email }))
  #   WelcomeJob.perform_later("user_id" => user.id)   # a job class
  #
  # A row is `queued`, `running`, `done`, `failed` or `discarded`. A kind
  # registered with a `concurrency_key:` stores {Job.concurrency_key_for}
  # in the row's `concurrency_key` column, and its limit counts per key.
  # The framework registers one kind itself, "cybertrain mail"
  # (Mailer.deliver_later, cybertrain/mailer/later.rb), so every
  # application that requires "cybertrain" has a handler.
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
  # so several worker processes can share one database. A block given to
  # {Job.register} may write its own outcome instead ({Job.retry_later},
  # or {Job.discard}, which leaves the row `discarded`).
  #
  # This module is the queue's public surface and its registry of handlers
  # ({Job.handle}, {Job.register}, `HANDLERS`). The work behind the other
  # methods is in four parts they delegate to (docs/design.md D68):
  # Job::Store holds every SQL statement, Job::RetryPolicy the arithmetic
  # of waits and limits, Job::Executor one claimed attempt from handler to
  # outcome, and Job::Worker the threads.
  # @api public
  module Job
    # One registered handler. Distinctive accessor names and no #call
    # (spikes/NOTES.md rules 10/34/40), like Main::Command.
    class Handler
      # handler_run_block: the Proc that runs a job, given its {Job::Run}
      # ({Job.handle}'s payload block is wrapped in one).
      # handler_concurrency: the most jobs of this kind that may be
      # `running` at once across every process sharing the database; 0 for
      # no limit. handler_concurrency_key: the args key a concurrency limit
      # is counted per; "" for the whole kind. handler_max_attempts: the
      # most attempts any of the kind's retry policies allows; 0 for
      # {Config#job_max_attempts} ({Job.recovery_limit}).
      attr_reader :handler_kind, :handler_run_block, :handler_concurrency,
                  :handler_concurrency_key, :handler_max_attempts

      def initialize(handler_kind, handler_run_block, handler_concurrency, handler_concurrency_key, handler_max_attempts)
        @handler_kind = handler_kind
        @handler_run_block = handler_run_block
        @handler_concurrency = handler_concurrency
        @handler_concurrency_key = handler_concurrency_key
        @handler_max_attempts = handler_max_attempts
      end
    end

    # One claimed attempt of a job, as the block given to {Job.register}
    # receives it: the row's id, kind and payload, the attempt number (1
    # for the first; the claim counted it), and the claim's label, which
    # with the attempt number fences the outcome write. A policy hands it
    # to {Job.retry_later} or {Job.discard}, which write the outcome and
    # mark it written, so the worker writes nothing more for it.
    # @api public
    class Run
      # @return [Integer] the job's id
      # @api public
      attr_reader :run_id
      # @return [String] the kind the job was enqueued under
      # @api public
      attr_reader :run_kind
      # @return [String] the payload given to {Job.enqueue}, as it is
      # @api public
      attr_reader :run_payload
      # @return [Integer] this attempt's number, 1 for the first
      # @api public
      attr_reader :run_attempts
      # @return [String] the claiming process's {Job.process_label}
      # @api public
      attr_reader :run_claimed_by
      # @return [Integer] the epoch seconds the attempt was claimed at (the
      #   `now` of {Job.work_one}); its outcome writes are timed from it
      # @api public
      attr_reader :run_now

      # @param run_id [Integer]
      # @param run_kind [String]
      # @param run_payload [String]
      # @param run_attempts [Integer]
      # @param run_claimed_by [String]
      # @param run_now [Integer] epoch seconds
      # @api public
      def initialize(run_id, run_kind, run_payload, run_attempts, run_claimed_by, run_now)
        @run_id = run_id
        @run_kind = run_kind
        @run_payload = run_payload
        @run_attempts = run_attempts
        @run_claimed_by = run_claimed_by
        @run_now = run_now
        @run_args = Cast.empty_hash
        @run_args_parsed = false
        @run_written = false
      end

      # The payload parsed as a JSON object, computed once. A payload that
      # is not a JSON object (plain text, an Array, invalid JSON, "") gives
      # an empty Hash; it never raises.
      # @return [Hash{String => Object}]
      # @api public
      def run_args
        unless @run_args_parsed
          @run_args = Cast.json_hash(@run_payload)
          @run_args_parsed = true
        end
        @run_args
      end

      # @return [Boolean] true once {Job.retry_later} or {Job.discard}
      #   wrote, or tried to write, this attempt's outcome
      # @api public
      def run_outcome_written?
        @run_written
      end

      # Marks the outcome written: the worker then writes nothing for this
      # attempt when the block returns or raises.
      # @return [nil]
      # @api public
      def run_outcome_written!
        @run_written = true
        nil
      end
    end

    # The registry: a constant (class variables are not GC roots, NOTES
    # rule 64), seeded with its element type and emptied (rule 9).
    HANDLERS = Array.new(0) { Handler.new("", nil, 0, "", 0) }

    # What {Job.retry_later} and {Job.discard} answer: the row was queued
    # again.
    # @api public
    OUTCOME_REQUEUED = :requeued
    # The row became `failed` (or, for {Job.discard}, `discarded`).
    # @api public
    OUTCOME_FAILED = :failed
    # Nothing was written: another claim owns the row, or the write failed
    # every try.
    # @api public
    OUTCOME_STALE = :stale

    # Seconds to wait before the retry after the 1st, 2nd, 3rd and every
    # later failed attempt.
    BACKOFF = RetryPolicy::BACKOFF

    # last_error keeps at most this many characters of the message.
    MAX_ERROR_LENGTH = RetryPolicy::MAX_ERROR_LENGTH

    # How many times an outcome write is tried before the row is left to
    # staleness recovery.
    OUTCOME_TRIES = Executor::OUTCOME_TRIES

    # Job.work_due's default bound: a SQLite call holds its OS worker until
    # it returns, so an unbounded drain could keep requests waiting.
    JOBS_PER_POLL = 20

    # Job.process_label, computed on first use; "" until then.
    @process_label = ""

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
    #
    # It is {Job.register} with a block that passes {Run#run_payload}, and
    # the default max_attempts.
    # @param kind [String] the name jobs are enqueued under
    # @param concurrency [Integer] the most running at once; 0 for no limit
    # @yieldparam payload [String]
    # @return [nil]
    # @raise [ArgumentError] for an empty kind, one already registered, or a
    #   negative concurrency
    # @api public
    def self.handle(kind, concurrency: 0, &block)
      check_registration("Job.handle", kind, concurrency, 0)
      HANDLERS << Handler.new(kind, proc { |run| block.call(run.run_payload) }, concurrency, "", 0)
      nil
    end

    # Registers the code that runs jobs of `kind`, as {Job.handle} does,
    # with a block that receives the attempt as a {Job::Run}: its parsed
    # args, its attempt number, and what {Job.retry_later} and
    # {Job.discard} need to write its outcome themselves (the code
    # generated for `app/jobs` classes uses it). A block that returns
    # without writing an outcome ends the job `done`; one that raises
    # without writing one follows the default retry policy.
    # @example
    #   Cybertrain::Job.register("ReportJob", max_attempts: 10) { |run| ReportJob.run_job(run) }
    # @param kind [String] the name jobs are enqueued under
    # @param concurrency [Integer] the most running at once; 0 for no limit
    # @param concurrency_key [String] the args key the limit is counted
    #   per; "" for the whole kind
    # @param max_attempts [Integer] the most attempts any of the kind's
    #   policies allows; 0 for {Config#job_max_attempts}. Stale-heartbeat
    #   recovery fails a row only once it reached {Job.recovery_limit}.
    # @yieldparam run [Job::Run]
    # @return [nil]
    # @raise [ArgumentError] for an empty kind, one already registered, or a
    #   negative concurrency or max_attempts
    # @api public
    def self.register(kind, concurrency: 0, concurrency_key: "", max_attempts: 0, &block)
      check_registration("Job.register", kind, concurrency, max_attempts)
      HANDLERS << Handler.new(kind, block, concurrency, concurrency_key, max_attempts)
      nil
    end

    # Raises the ArgumentError of an invalid registration (`name` is the
    # method the message names), each message in a local first (NOTES
    # rule 58).
    def self.check_registration(name, kind, concurrency, max_attempts)
      if kind.empty?
        message = "#{name}: the kind is empty"
        raise ArgumentError, message
      end
      if handler_index(kind) >= 0
        message = "#{name} #{kind.inspect}: already registered"
        raise ArgumentError, message
      end
      if concurrency < 0
        message = "#{name} #{kind.inspect}: concurrency must be 0 (no limit) or more (got #{concurrency})"
        raise ArgumentError, message
      end
      if max_attempts < 0
        message = "#{name} #{kind.inspect}: max_attempts must be 0 (the default) or more (got #{max_attempts})"
        raise ArgumentError, message
      end
      nil
    end

    # Who this process is in `claimed_by`: "<hostname>:<pid>:<epoch of the
    # first call>:<6 random hex digits>", computed once, so neither two
    # processes on one host nor a container restarted within the same
    # second with the same pid share a label. The epoch is real time
    # ({Clock.real_now}): an identity, not an instant a test travels.
    # @return [String]
    # @api public
    def self.process_label
      label = @process_label
      if label.empty?
        label = "#{Socket.gethostname}:#{Process.pid}:#{Clock.real_now.to_i}:#{SecureRandom.hex(3)}"
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
    # creates the table if needed, queues again the rows whose heartbeat
    # is stale ({Job.recover!}), and then keys the queued rows enqueued
    # before their kind had a concurrency key ({Job.backfill_keys}). The
    # database must be connected.
    # Application#serve calls it (when {Config#worker} is on) after
    # Scheduler.start!, and so does `./<app> worker`; the caller decides
    # whether this process runs jobs.
    # @param config [Config]
    # @return [Boolean] true when it started the threads
    # @api public
    def self.start!(config = Cybertrain.config)
      Worker.start!(config)
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
      Worker.stop!
    end

    # Tells the job threads to claim nothing more, and nothing else: safe
    # in a signal handler (Application#serve's TERM trap calls it next to
    # the server's request_stop, so the jobs drain during the requests'
    # drain). {Job.stop!} still has to be called to wait for them.
    # @return [nil]
    # @api public
    def self.request_stop
      Worker.request_stop
    end

    # @return [Boolean] true between {Job.start!} and {Job.stop!} (or
    #   {Job.request_stop})
    # @api public
    def self.running?
      Worker.running?
    end

    # How many job threads have not ended yet (a thread finishing its job
    # after stop! counts until it has).
    # @api private
    def self.live_loops
      Worker.live_loops
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
    # A kind registered with a `concurrency_key:` stores the payload's
    # {Job.concurrency_key_for} with the row; its limit then counts per key.
    # @example run in ten minutes
    #   Cybertrain::Job.enqueue("reminder", order.id.to_s, run_at: Time.current + 600)
    # @param kind [String] a kind registered with {Job.handle}
    # @param payload [String] handed to the handler as it is
    # @param run_at [Time] the earliest time to run it (now by default)
    # @return [Integer] the job's id
    # @raise [ArgumentError] when no handler is registered for kind, or the
    #   kind has a concurrency key and the payload cannot be keyed: the
    #   field is missing, its value is an empty String or null, or the
    #   payload is not a JSON object
    # @raise [Cybertrain::DB::Error] when the database is not connected or
    #   the insert fails
    # @api public
    def self.enqueue(kind, payload, run_at: Time.current)
      raise ArgumentError, "Job.enqueue: no handler registered for #{kind.inspect}" if handler_index(kind) < 0

      key = concurrency_key_for(kind, payload)
      name = job_key_name(kind)
      if key.empty? && !name.empty?
        message = "Job.enqueue #{kind.inspect}: the payload has no #{name.inspect} field for limits_concurrency"
        raise ArgumentError, message
      end
      Store.insert(kind, payload, run_at.to_i, key)
    end

    # The concurrency key a job of `kind` with `payload` is counted under:
    # the payload parsed as a JSON object, the field the kind's
    # `concurrency_key:` names ({Job.register}), as a String (`true` is
    # "true", `7` is "7"). "" when the kind has no key (or no handler),
    # when the payload is not a JSON object, and when the field is missing
    # or null. {Job.enqueue}, {Job.backfill_keys} and {Job.recover!} all
    # derive the key here, so they cannot disagree.
    # @param kind [String]
    # @param payload [String]
    # @return [String]
    # @api public
    def self.concurrency_key_for(kind, payload)
      name = job_key_name(kind)
      return "" if name.empty?

      Cast.str(Cast.json_hash(payload)[name])
    end

    # The args field kind's handler counts its limit per; "" for none.
    def self.job_key_name(kind)
      index = handler_index(kind)
      return "" if index < 0

      HANDLERS[index].handler_concurrency_key
    end

    # The registered kinds with a concurrency key.
    def self.keyed_kinds
      out = Array.new(0) { "" }
      HANDLERS.each { |h| out << h.handler_kind unless h.handler_concurrency_key.empty? }
      out
    end

    # Keys the `queued` rows of each keyed kind that still carry "" (rows
    # enqueued before the kind had a key, or before the column existed),
    # with {Job.concurrency_key_for}, a batch of 1000 rows at a
    # time, each UPDATE only while the row is still unkeyed. A row the
    # derivation leaves "" (no such field, or not a JSON object) stays in
    # the "" bucket, which has the kind's limit of its own, and is listed
    # once at warn with its id. {Job.start!} calls it after {Job.recover!};
    # a second call finds nothing to key.
    # @param now [Integer] epoch seconds (the start's clock; the rows'
    #   updated_at is left as it is, as the spec's UPDATE writes only the key)
    # @return [Integer] how many rows were keyed
    # @api public
    def self.backfill_keys(now)
      Store.backfill_keys(now)
    end

    # Creates the table and its indexes if they are missing, and adds the
    # columns a table made by an earlier release lacks (`claimed_by`,
    # `heartbeat_at`; a row such a release left `running` keeps a NULL
    # heartbeat, which {Job.recover!} requeues at once; `concurrency_key`,
    # "" until {Job.backfill_keys} or {Job.recover!} keys the row). The
    # job threads and {Job.enqueue} call it once per connected database;
    # call it yourself only to create the table ahead of time.
    # @return [nil]
    # @api public
    def self.install!
      Store.install!
    end

    # install! unless it already ran since the last DB.connect.
    def self.ensure_installed
      Store.ensure_installed
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
    # last (its kind's {Job.recovery_limit}) is left `failed` instead
    # (`Job::Store.fail_exhausted`): a payload that kills its process is not
    # requeued for ever. A row of a kind with a concurrency key is
    # requeued with its {Job.concurrency_key_for} written in the same
    # UPDATE, so no claim sees it queued under the wrong key (a row left
    # by a release before the key, still running when the new workers
    # started, is keyed here).
    # @param now [Integer] epoch seconds
    # @param stale [Integer] seconds without a heartbeat that make a row
    #   abandoned (by default the {Config#job_heartbeat_stale} of the
    #   Config {Job.start!} was given, or of Cybertrain.config before it)
    # @return [Integer] how many rows were requeued
    # @api public
    def self.recover!(now, stale = Job.heartbeat_stale)
      Store.requeue_stale(now, stale)
    end

    # The attempt count at which stale-heartbeat recovery ({Job.recover!})
    # fails a row of `kind` instead of queueing it again: the larger of
    # {Config#job_max_attempts} and the kind's `max_attempts:`
    # ({Job.register}), so a policy that allows more attempts is honoured
    # and one that allows fewer does not fail a row the default policy may
    # still retry. A kind no longer registered gets the config value.
    # @param kind [String]
    # @return [Integer]
    # @api public
    def self.recovery_limit(kind)
      default = Cybertrain.config.job_max_attempts
      index = handler_index(kind)
      return default if index < 0

      RetryPolicy.recovery_limit(HANDLERS[index].handler_max_attempts, default)
    end

    # The stale default of recover!.
    def self.heartbeat_stale
      Worker.heartbeat_stale
    end

    # Marks the jobs this process is running now as alive at `now` (the
    # heartbeat thread does it every {Config#job_heartbeat_interval}
    # seconds), so no other process's {Job.recover!} takes them. Only rows
    # in flight here: a row whose outcome could not be written (the
    # database stayed locked) is no longer in flight, so its heartbeat stops
    # and staleness recovery runs it again, rather than it staying
    # `running` (and holding a concurrency slot) for as long as the
    # process lives. And only the attempts in flight here: a row recovered
    # and claimed again by this process is kept alive by its new attempt,
    # not by an older one that is still running (the heartbeat is fenced
    # by the attempt number, as the outcome is). Judgement call: the spec's
    # statement was `WHERE state = 'running' AND claimed_by = ?`; this adds
    # the (id, attempts) of each claim in flight.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many rows it touched
    # @api public
    def self.heartbeat!(now)
      Store.touch_heartbeats(now, process_label, Executor.in_flight_claims)
    end

    # Whether the claim made under `ticket` is still wanted: {Job::Store.claim}
    # asks once it holds the write lock, before it takes a row. A claim
    # outside a pool (ticket {Job::Executor::NO_TICKET}) always is; a job
    # thread's is while its pool is the live one and no stop was requested.
    def self.claim_open?(ticket)
      ticket < 0 || Worker.pool_live?(ticket)
    end

    # A copy of the ids of the jobs in flight in this process.
    def self.in_flight_ids
      Executor.in_flight_ids
    end

    # How many jobs of `kind` are `running` now, in every process sharing
    # the database.
    # @param kind [String]
    # @return [Integer]
    # @api public
    def self.running_count(kind)
      Store.running_count(kind)
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

    # Claims and runs the oldest due job, if there is one, and records the
    # outcome: `done`; `queued` again with `run_at` pushed back by {BACKOFF}
    # after a failure; `failed` once {Config#job_max_attempts} attempts have
    # failed, or at once when no handler is registered for its kind. The
    # worker calls it; tests call it with a fixed `now` instead of waiting.
    # @param now [Integer] epoch seconds: jobs with run_at <= now are due
    # @return [Boolean] true when a job was claimed
    # @api public
    def self.work_one(now)
      Executor.work_one(now)
    end

    # Claims and runs the queued job with the lowest id above `floor` and
    # records the outcome as {.work_one} does: what `perform_enqueued_jobs
    # { }` and `assert_emails { }` call to run the jobs queued during their
    # block (ids above the largest one before it), and the jobs those
    # queue, on the test's thread, in enqueue order. A job not yet
    # attempted runs whatever its run_at; a retry (a failed attempt
    # rescheduled) only once its run_at has come. The attempt is timed at
    # the clock's now ({Clock.now}: `travel_to` moves it, and can bring a
    # retry due).
    # @example
    #   floor = id_before_the_block
    #   nil while Cybertrain::Job.work_one_after(floor)
    # @param floor [Integer] only rows whose id is greater
    # @param kind [String] only rows of this kind; "" for any
    # @return [Boolean] true when a job was claimed
    # @api public
    def self.work_one_after(floor, kind = "")
      work_one_after_id(floor, kind) >= 0
    end

    # {.work_one_after}, answering the id of the job it ran, -1 when none
    # (the test helpers read that row's outcome).
    # @param floor [Integer]
    # @param kind [String]
    # @return [Integer]
    # @api private
    def self.work_one_after_id(floor, kind = "")
      Executor.work_one_after_id(floor, kind, Clock.now.to_i)
    end

    # Works through due jobs, at most `limit` of them, one after another on
    # the calling thread (a {Main.command} that drains the queue, or a
    # test). Returns how many it claimed.
    # @param now [Integer] epoch seconds
    # @param limit [Integer]
    # @return [Integer]
    # @api public
    def self.work_due(now, limit = JOBS_PER_POLL)
      Executor.work_due(now, limit)
    end

    # How many rows are in `state` ("queued", "running", "done", "failed"
    # or "discarded"), e.g. for a health or admin page.
    # @param state [String]
    # @return [Integer]
    # @api public
    def self.state_count(state)
      Store.state_count(state)
    end

    # Deletes `done` rows last updated before `before` (epoch seconds), for
    # a scheduled task that keeps the table small. `failed` and `discarded`
    # rows are kept for a person to look at ({Job.prune_finished} removes
    # them).
    # @param before [Integer] epoch seconds
    # @return [Integer] how many rows were deleted
    # @api public
    def self.prune_done(before)
      Store.prune_done(before)
    end

    # Deletes `failed` and `discarded` rows whose outcome was written
    # before `before` (epoch seconds), once a person no longer needs them.
    # @param before [Integer] epoch seconds
    # @return [Integer] how many rows were deleted
    # @api public
    def self.prune_finished(before)
      Store.prune_finished(before)
    end

    # Seconds to wait after the attempts-th failed attempt (1-based).
    # @param attempts [Integer]
    # @return [Integer]
    def self.backoff(attempts)
      RetryPolicy.default_wait(attempts)
    end

    # Writes the outcome of a failed attempt for a retry policy (the code
    # generated for `retry_on`): `queued` again with `run_at` moved by the
    # wait while `run.run_attempts < attempts_limit`, else `failed`;
    # `last_error` is the error's class and message either way. The wait
    # is `wait_base` seconds, or with `polynomial` `attempts ** 4 + 2`
    # (3, 18, 83, ...). The write is fenced by the claim, as the worker's
    # own: when another worker reclaimed the row, nothing is written
    # (logged at warn) and the answer is OUTCOME_STALE, as it is when the
    # write failed every try (the row is left to heartbeat recovery). The
    # Run is marked written in every case, so the worker writes nothing
    # more for it. Answering OUTCOME_FAILED only once the row really
    # became `failed` lets the caller run an exhaustion hook safely.
    # @param run [Job::Run] the attempt
    # @param error [StandardError] what it raised
    # @param wait_base [Integer] seconds before the retry
    # @param polynomial [Boolean] wait `attempts ** 4 + 2` seconds instead
    # @param attempts_limit [Integer] the most attempts, the first included
    # @return [Symbol] OUTCOME_REQUEUED, OUTCOME_FAILED or OUTCOME_STALE
    # @api public
    def self.retry_later(run, error, wait_base, polynomial, attempts_limit)
      Executor.retry_later(run, error, wait_base, polynomial, attempts_limit)
    end

    # Writes the outcome of an attempt a discard policy stopped (the code
    # generated for `discard_on`): the row becomes `discarded`, with the
    # error's class and message in `last_error`, and is never retried.
    # Fenced and marked written as {Job.retry_later} is. It answers
    # OUTCOME_FAILED when the row became `discarded` (it is terminal, as a
    # failed row is) and OUTCOME_STALE when nothing was written.
    # @param run [Job::Run] the attempt
    # @param error [StandardError] what it raised
    # @return [Symbol] OUTCOME_FAILED or OUTCOME_STALE
    # @api public
    def self.discard(run, error)
      Executor.discard(run, error)
    end

    # Makes the next `count` outcome writes raise, for tests of a database
    # that stays locked.
    # @param count [Integer]
    # @return [nil]
    # @api private
    def self.fail_outcome_writes(count)
      Store.fail_outcome_writes(count)
    end
  end
end

# Job::Base, the superclass of the app/jobs classes.
require "cybertrain/job/base"
