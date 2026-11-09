require "json"
require "cybertrain/logger"
require "cybertrain/config"
require "cybertrain/job"
require "cybertrain/lease"
require "cybertrain/time_zone"
require "cybertrain/cron"
require "cybertrain/scheduler/timetable"

module Cybertrain
  # Cybertrain::Scheduler -- "run this every N seconds" or "at these
  # minutes" (a cron expression) for a served application, on one
  # background thread the framework starts.
  #
  #   # config/app.rb, or a file bin/<app>.rb requires before Main.run:
  #   Cybertrain::Scheduler.every(3600, "prune sessions") do
  #     Cybertrain::DB.with { |c| c.execute("DELETE FROM sessions WHERE updated_at < datetime('now', '-30 days')") }
  #   end
  #   Cybertrain::Scheduler.cron("0 9 * * 1-5", "morning report", tz: "Asia/Tokyo",
  #                              job: "morning_report", args: { "scope" => "all" })
  #
  # The timetable is kept in the database ({Scheduler::Timetable},
  # `cybertrain_schedules`): when each task last ran and runs next. A
  # restart or a new leader continues from it, so neither resets an
  # `every` interval nor runs every task at once.
  #
  # Application#serve starts the thread ({Scheduler.start!}) once the
  # database is connected, the port is bound and `SPINEL_WORKERS` is set
  # (spikes/NOTES.md rule 22), and only when the process serves: `./<app>
  # migrate`, `db ...` and {Main.command} commands never start it. Each run
  # is wrapped in a rescue that logs `[ERROR]`, so a failing task does not
  # end the loop. Jobs do not run here: {Job.start!} runs them on threads of
  # their own, so a long job never delays a task (a long task still delays
  # the other tasks: a task with real work to do should {Job.enqueue} it).
  # {Config#worker} (`CYBERTRAIN_WORKER=0`) turns the thread off in a
  # `server` process.
  #
  # Several processes may run the scheduler against one database (`./<app>
  # worker` twice, or a server and a worker): every tick takes or renews
  # the lease "scheduler" ({Lease.acquire}, {Config#scheduler_lease_ttl}
  # seconds), and only the process holding it runs the due tasks; the
  # others keep ticking and take over once the leader's lease expires.
  # Every tick of a process that runs jobs, leader or not, also calls
  # {Job.recover!}, at most once a minute (recovery is idempotent, so it
  # needs no lease).
  # @api public
  module Scheduler
    # One registered task: an `every` task (task_interval above 0, no
    # task_cron) or a `cron` task (task_cron set, task_interval 0), which
    # runs task_block or, with a task_job_kind, enqueues that job.
    # Distinctive accessor names and no #call (spikes/NOTES.md rules
    # 10/34/40).
    class Task
      attr_reader :task_name, :task_interval, :task_block, :task_zone, :task_catch_up, :task_job_kind, :task_job_args
      # The parsed expression of a `cron` task; nil for an `every` task.
      attr_reader :task_cron
      # Epoch seconds of the next run; 0 until the scheduler first sees it.
      attr_accessor :task_next_run
      # Epoch seconds of the last run; 0 for none known.
      attr_accessor :task_last_run

      def initialize(task_name, task_interval, task_block, task_zone, task_cron, task_catch_up, task_job_kind, task_job_args)
        @task_name = task_name
        @task_interval = task_interval
        @task_block = task_block
        @task_zone = task_zone
        @task_cron = task_cron
        @task_catch_up = task_catch_up
        @task_job_kind = task_job_kind
        @task_job_args = task_job_args
        @task_next_run = 0
        @task_last_run = 0
      end
    end

    # The registry: a constant, which Spinel roots for the collector (a
    # class variable it does not: NOTES rule 64), seeded and emptied (rule 9).
    TASKS = Array.new(0) { Task.new("", 0, nil, TimeZone::UTC, nil, false, "", "{}") }

    # Guards @last_tick, which the scheduler thread writes and a request
    # thread (a health check) reads.
    LOCK = Mutex.new

    @last_tick = 0
    @running = false
    # Counts start!s: a loop left from before a stop! and a new start!
    # sees a newer number and ends instead of running beside the new one.
    @generation = 0
    # Whether the last tick held the lease.
    @leader = false
    # Config#scheduler_lease_ttl, copied by start! (the default until then).
    @lease_ttl = 30
    # The `now` of the last tick that ran Job.recover!; 0 for none.
    @last_recovery = 0

    # The name of the lease the leader holds.
    LEASE_NAME = "scheduler"

    # The most often a tick runs Job.recover!, in seconds.
    RECOVERY_INTERVAL = 60

    # Registers a task that runs every `seconds` seconds while the server
    # runs: first `seconds` after the scheduler starts, then `seconds` after
    # the start of each run (a run that takes longer is followed at once by
    # the next). The block takes no arguments (Spinel has no instance_eval;
    # reach what it needs through constants and module methods). Register
    # before the server starts; a task added later is ignored until the
    # next start.
    #
    # Tasks run one after another on one thread. A SQLite call holds its OS
    # worker until it returns, so with `SPINEL_WORKERS=1` a task's long
    # query stalls every request for as long: keep tasks short and batch
    # big work (delete a thousand rows per run, not a million).
    #
    # With several processes, the one holding the scheduler lease runs the
    # tasks. The lease is renewed before each task, so one task must finish
    # within {Config#scheduler_lease_ttl} seconds, or another process may
    # take the lease and run tasks beside it. A restart or a new leader
    # continues from the persisted timetable: a run that came due while no
    # process ran happens once, at the first tick. A task the old leader
    # was running when it died runs again: write tasks that do no harm when
    # they run twice.
    # @example
    #   Cybertrain::Scheduler.every(60, "expire carts") { Cart.where_sql("updated_at < ?", [cutoff]).delete_all }
    # @param seconds [Integer] at least 1
    # @param name [String] for the log; unique
    # @return [nil]
    # @raise [ArgumentError] for seconds below 1, an empty name or one taken
    # @api public
    def self.every(seconds, name, &block)
      raise ArgumentError, "Scheduler.every #{name.inspect}: seconds must be at least 1" if seconds < 1
      raise ArgumentError, "Scheduler.every: the name is empty" if name.empty?
      raise ArgumentError, "Scheduler.every #{name.inspect}: already registered" if task_index(name) >= 0

      TASKS << Task.new(name, seconds, block, TimeZone::UTC, nil, false, "", "{}")
      nil
    end

    # Registers a task that runs at the minutes a five-field cron
    # expression matches in the zone `tz` ({Cron.parse} lists the syntax;
    # across a DST gap a skipped wall time does not run, across a fold a
    # fixed-hour task runs once). It takes a block, run on the scheduler
    # thread as an {Scheduler.every} task's is, or `job:`, a kind registered
    # with {Job.handle}: the task then only enqueues that job with `args`
    # as its JSON payload, which is what a task with real work should do.
    # The kind is checked when the scheduler starts ({Scheduler.start!}).
    #
    # A run missed while no process ran (a slot that passed during a
    # restart) is skipped, as cron and Solid Queue do; with `catch_up:
    # true` the task runs once at the first tick and then continues on its
    # schedule.
    # @example
    #   Cybertrain::Scheduler.cron("12 * * * *", "collect prices") { Prices.collect }
    #   Cybertrain::Scheduler.cron("0 9 * * 1-5", "morning report", tz: "Asia/Tokyo",
    #                              job: "morning_report", args: { "scope" => "all" })
    # @param expr [String] such as `"*/5 * * * *"`
    # @param name [String] for the log; unique
    # @param tz [String] an IANA zone name; {Config#scheduler_tz} by default
    # @param catch_up [Boolean] whether a missed run happens once at start
    # @param job [String] a job kind to enqueue instead of running a block;
    #   "" for a block task
    # @param args [Hash] the job's payload, as JSON
    # @return [nil]
    # @raise [ArgumentError] for an expression {Cron.parse} refuses, an
    #   unknown zone, an empty name or one taken, or a block and `job:`
    #   together or neither
    # @api public
    def self.cron(expr, name, tz: Cybertrain.config.scheduler_tz, catch_up: false, job: "", args: {}, &block)
      raise ArgumentError, "Scheduler.cron: the name is empty" if name.empty?
      raise ArgumentError, "Scheduler.cron #{name.inspect}: already registered" if task_index(name) >= 0

      if block.nil? && job.empty?
        message = "Scheduler.cron #{name.inspect}: give a block or job:, not neither"
        raise ArgumentError, message
      end
      if !block.nil? && !job.empty?
        message = "Scheduler.cron #{name.inspect}: give a block or job:, not both"
        raise ArgumentError, message
      end
      parsed = schedule_parse(expr, name)
      zone = TimeZone.find(tz)
      unless zone.found?
        message = "Scheduler.cron #{name.inspect}: tz #{tz.inspect} is not a known time zone"
        raise ArgumentError, message
      end
      payload = JSON.generate(args)
      TASKS << Task.new(name, 0, block, zone, parsed, catch_up, job, payload)
      nil
    end

    # Cron.parse with the task's name in front of its message (the rescue
    # in a plain method, NOTES rules 32/45; the message in a local, rule 58).
    def self.schedule_parse(expr, name)
      Cron.parse(expr)
    rescue ArgumentError => e
      message = "Scheduler.cron #{name.inspect}: #{e.message}"
      raise ArgumentError, message
    end

    # The error {Scheduler.start!} raises (and Application#boot reports)
    # when a `cron` task's `job:` names a kind no {Job.handle} registered:
    # the first such task, its kind and the registered kinds; "" when
    # every kind is registered.
    # @return [String]
    # @api public
    def self.job_kinds_error
      i = 0
      while i < TASKS.size
        task = TASKS[i]
        kind = task.task_job_kind
        if !kind.empty? && Job.handler_index(kind) < 0
          return "Scheduler.cron #{task.task_name.inspect}: job #{kind.inspect} is not a registered job kind (#{registered_kinds_text})"
        end
        i += 1
      end
      ""
    end

    # "registered: a, b" or "no job kind is registered".
    def self.registered_kinds_text
      return "no job kind is registered" if Job::HANDLERS.empty?

      out = +"registered: "
      j = 0
      while j < Job::HANDLERS.size
        out << ", " if j > 0
        out << Job::HANDLERS[j].handler_kind
        j += 1
      end
      out
    end

    # Deletes the timetable rows of task names no longer registered (a task
    # renamed or removed keeps its row until then). {Scheduler.start!}
    # calls it.
    # @return [Integer] how many rows were deleted
    # @raise [Cybertrain::DB::Error] when the database is not reachable
    # @api public
    def self.prune_schedules
      names = Array.new(0) { "" }
      i = 0
      while i < TASKS.size
        names << TASKS[i].task_name
        i += 1
      end
      Timetable.prune(names)
    end

    # The index of the task named name, -1 when none (NOTES rules 11/56).
    def self.task_index(name)
      i = 0
      while i < TASKS.size
        return i if TASKS[i].task_name == name
        i += 1
      end
      -1
    end

    # Starts the scheduler thread, unless {Config#worker} is off, nothing is
    # registered (no task and no {Job} handler, whose rows the ticks
    # recover), or it already runs. Before it starts it removes the
    # timetable rows of names no longer registered
    # ({Scheduler.prune_schedules}) and schedules every task from the
    # timetable ({Scheduler.schedule_all}). Application#serve calls it; the
    # database must be connected.
    # @param config [Config]
    # @return [Boolean] true when it started the thread
    # @raise [ArgumentError] when a `cron` task's `job:` is not a registered
    #   kind ({Scheduler.job_kinds_error}; Application#boot reports it first)
    # @api public
    def self.start!(config = Cybertrain.config)
      return false if @running

      kinds_error = job_kinds_error
      raise ArgumentError, kinds_error unless kinds_error.empty?

      unless config.worker
        Cybertrain.logger.info("Background worker off (CYBERTRAIN_WORKER=0): scheduled tasks and jobs run elsewhere")
        return false
      end

      return false if TASKS.empty? && !Job.handlers?

      prune_safely
      schedule_all(Time.now.to_i)
      @lease_ttl = config.scheduler_lease_ttl
      @running = true
      @generation += 1
      Cybertrain.logger.info("Scheduler started: #{task_summary}")
      spawn_loop(config.scheduler_interval, @generation)
      true
    end

    # Asks the thread to end; it does after its current tick (within
    # {Config#scheduler_interval} seconds). Tests and Application#serve's
    # shutdown call it.
    # @return [nil]
    # @api public
    def self.stop!
      was_running = @running
      @running = false
      # Hand the lease over at once rather than after its ttl. (A tick in
      # progress on the thread may still renew it; it then expires.)
      release_safely if was_running && @leader
      nil
    end

    # Whether this process held the scheduler lease at its last tick, and
    # so ran the due tasks. A process that is not the leader still ticks
    # ({Scheduler.last_tick}).
    # @return [Boolean]
    # @api public
    def self.leader?
      @leader
    end

    # Who this process is in the lease: {Job.process_label}.
    # @return [String]
    # @api public
    def self.holder
      Job.process_label
    end

    # @return [Boolean] true between {Scheduler.start!} and {Scheduler.stop!}
    # @api public
    def self.running?
      @running
    end

    # Epoch seconds of the scheduler's last tick, 0 before the first. A
    # health endpoint can compare it with `Time.now.to_i`: a value older
    # than a few {Config#scheduler_interval}s means the loop is stuck in a
    # task (or not running).
    # @return [Integer]
    # @api public
    def self.last_tick
      tick = 0
      LOCK.synchronize { tick = @last_tick }
      tick
    end

    # One tick: takes or renews the scheduler lease, and, holding it, runs
    # every task whose time has come (in registration order) and records
    # the run in the timetable; then, when {Job} threads run in this
    # process and a minute has passed since the last one, {Job.recover!};
    # and records `now` as {Scheduler.last_tick}. A task the scheduler sees
    # for the first time is only scheduled: an `every` task `seconds` after
    # `now`, a `cron` task at the expression's next match. After a run the
    # next one is computed from it: the run plus the interval, or the
    # expression's next match after the run in the task's zone. A `cron`
    # task whose next match cannot be computed (none within five years) is
    # logged as a failed task and skipped in this tick; the others run. A
    # tick that cannot reach the database logs the error, runs nothing and
    # counts as not leading; the next one tries again. The thread calls it
    # with the current time; tests call it with chosen times instead of
    # sleeping.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many tasks ran (including ones that raised)
    # @api public
    def self.run_due(now)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      leader = acquire_safely(now)
      @leader = leader
      ran = 0
      i = 0
      while i < TASKS.size
        task = TASKS[i]
        due = task.task_next_run
        if due == 0
          first = schedule_next(task, now)
          task.task_next_run = first if first > 0
        elsif due <= now
          if leader
            # Renewed before each task (the tick's own `now` plus the time
            # the tick has taken): a leader that lost the lease while a
            # task ran stops running tasks in this tick.
            elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to_i
            leader = acquire_safely(now + elapsed)
            @leader = leader
          end
          if leader
            # The next run is computed from this one (its last run), before
            # the task runs, so a raising task keeps its schedule.
            following = schedule_next(task, now)
            if following > 0
              task.task_last_run = now
              task.task_next_run = following
              run_task(task)
              record_safely(task, now)
              ran += 1
            end
          else
            # A process that does not lead keeps the timetable too, as if
            # the leader had run the task when it was due (a `cron` task) or
            # now (an `every` task), so that it does not run every overdue
            # task at once when it takes over.
            presumed = task.task_cron.nil? ? now : due
            following = schedule_next(task, presumed)
            if following > 0
              task.task_last_run = presumed
              task.task_next_run = following
            end
          end
        end
        i += 1
      end
      recover_jobs(now) if Job.running? && (@last_recovery == 0 || now - @last_recovery >= RECOVERY_INTERVAL)
      LOCK.synchronize { @last_tick = now }
      ran
    end

    # The run after one at `last`: last plus the interval of an `every`
    # task, Cron.next_after of a `cron` task. -1, logged as the task's
    # failure, when Cron.next_after finds none (the rescue in a plain
    # method, NOTES rules 32/45).
    def self.schedule_next(task, last)
      expr = task.task_cron
      return last + task.task_interval if expr.nil?

      Cron.next_after(expr, last, task.task_zone)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduled task #{task.task_name.inspect} failed: #{e.class.name}: #{e.message}")
      -1
    end

    # Timetable.write of the task's last and next run; the error logged
    # when the database cannot be reached.
    def self.record_safely(task, now)
      Timetable.write(task.task_name, task.task_last_run, task.task_next_run, now)
      nil
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduler timetable: #{e.class.name}: #{e.message}")
      nil
    end

    # Timetable.read_all, or no rows (the error logged) when the database
    # cannot be reached.
    def self.timetable_safely
      Timetable.read_all
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduler timetable: #{e.class.name}: #{e.message}")
      rows = { "" => [0, 0] }
      rows.delete("")
      rows
    end

    # prune_schedules for start!, the error logged.
    def self.prune_safely
      prune_schedules
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduler timetable: #{e.class.name}: #{e.message}")
      0
    end

    # Lease.acquire with its rescue in a plain method (NOTES rules 32/45):
    # false, and the error logged, when the database cannot be reached.
    def self.acquire_safely(now)
      Lease.acquire(LEASE_NAME, holder, now, ttl: @lease_ttl)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduler lease: #{e.class.name}: #{e.message}")
      false
    end

    def self.release_safely
      Lease.release(LEASE_NAME, holder)
      @leader = false
      nil
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduler lease release: #{e.class.name}: #{e.message}")
      nil
    end

    # Job.recover! for the tick, logged when it requeued something.
    def self.recover_jobs(now)
      @last_recovery = now
      requeued = Job.recover!(now)
      Cybertrain.logger.warn("Requeued #{requeued} job(s) whose process stopped sending heartbeats") if requeued > 0
      requeued
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Job recovery: #{e.class.name}: #{e.message}")
      0
    end

    # Runs one task -- calls its block, or enqueues its `job:` -- with its
    # rescue in a plain method that reads the Proc from the Task rather
    # than yielding (NOTES rules 32/45/69); naming JSON::NestingError first
    # (rule 61). False when it raised.
    def self.run_task(task)
      kind = task.task_job_kind
      if kind.empty?
        task.task_block.call
      else
        Job.enqueue(kind, task.task_job_args)
      end
      true
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduled task #{task.task_name.inspect} failed: #{e.class.name}: #{e.message}")
      false
    end

    # Schedules every task from the timetable, as start! does. An `every`
    # task continues from its last run (an overdue one runs at the first
    # tick); a `cron` task takes its next match after its last run, and
    # when that has passed, the next match after `now` -- or, with
    # `catch_up: true`, runs once at the first tick. A task with no row is
    # scheduled from `now` (an interval after it, or the next match) and
    # gets its row.
    # @param now [Integer] epoch seconds
    # @return [nil]
    # @api public
    def self.schedule_all(now)
      rows = timetable_safely
      i = 0
      while i < TASKS.size
        task = TASKS[i]
        name = task.task_name
        if rows.key?(name)
          pair = rows[name]
          schedule_from_row(task, pair[0], pair[1], now)
        else
          task.task_last_run = 0
          first = schedule_next(task, now)
          task.task_next_run = first > 0 ? first : 0
          record_safely(task, now) if first > 0
        end
        i += 1
      end
      nil
    end

    # One task's next run from its row: last (0 for none) and the stored
    # next run.
    def self.schedule_from_row(task, last, stored_next, now)
      task.task_last_run = last
      slot = last > 0 ? schedule_next(task, last) : stored_next
      if slot < 0
        task.task_next_run = 0
      elsif slot >= now || task.task_cron.nil?
        task.task_next_run = slot
      elsif task.task_catch_up
        task.task_next_run = now
      else
        following = schedule_next(task, now)
        task.task_next_run = following > 0 ? following : 0
      end
      nil
    end

    # "name every Ns, name (cron "expr" zone) next 2026-11-09T10:12Z, ..."
    # for the start line; "no scheduled tasks (job recovery only)" when
    # none is registered.
    # @return [String]
    # @api public
    def self.task_summary
      return "no scheduled tasks (job recovery only)" if TASKS.empty?

      out = +""
      i = 0
      while i < TASKS.size
        task = TASKS[i]
        out << ", " unless out.empty?
        out << task.task_name
        expr = task.task_cron
        if expr.nil?
          out << " every "
          out << task.task_interval.to_s
          out << "s"
        else
          out << " (cron \""
          out << expr.expression_text
          out << "\" "
          out << task.task_zone.zone_name
          out << ") next "
          out << summary_stamp(task.task_next_run)
        end
        i += 1
      end
      out
    end

    # "2026-11-09T10:12Z" of an epoch; "-" for 0 (not scheduled).
    def self.summary_stamp(epoch)
      return "-" if epoch == 0

      f = TimeZone.epoch_to_civil(epoch)
      "#{f[0]}-#{Cron.two_digits(f[1])}-#{Cron.two_digits(f[2])}T#{Cron.two_digits(f[3])}:#{Cron.two_digits(f[4])}Z"
    end

    # Through a method, as Application#spawn_restart_monitor does: the
    # closure captures the parameter.
    def self.spawn_loop(interval, generation)
      Thread.new { run_loop(interval, generation) }
    end

    def self.run_loop(interval, generation)
      while @running && @generation == generation
        run_due(Time.now.to_i)
        sleep interval
      end
      nil
    end
  end
end
