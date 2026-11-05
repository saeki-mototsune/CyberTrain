require "json"
require "cybertrain/logger"
require "cybertrain/config"
require "cybertrain/job"
require "cybertrain/lease"

module Cybertrain
  # Cybertrain::Scheduler -- "run this every N seconds" for a served
  # application, on one background thread the framework starts.
  #
  #   # config/app.rb, or a file bin/<app>.rb requires before Main.run:
  #   Cybertrain::Scheduler.every(3600, "prune sessions") do
  #     Cybertrain::DB.with { |c| c.execute("DELETE FROM sessions WHERE updated_at < datetime('now', '-30 days')") }
  #   end
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
    # One registered task. Distinctive accessor names and no #call
    # (spikes/NOTES.md rules 10/34/40).
    class Task
      attr_reader :task_name, :task_interval, :task_block
      # Epoch seconds of the next run; 0 until the scheduler first sees it.
      attr_accessor :task_next_run

      def initialize(task_name, task_interval, task_block)
        @task_name = task_name
        @task_interval = task_interval
        @task_block = task_block
        @task_next_run = 0
      end
    end

    # The registry: a constant, which Spinel roots for the collector (a
    # class variable it does not: NOTES rule 64), seeded and emptied (rule 9).
    TASKS = Array.new(0) { Task.new("", 0, nil) }

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

      TASKS << Task.new(name, seconds, block)
      nil
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
    # recover), or it already runs. Application#serve calls it; the
    # database must be connected.
    # @param config [Config]
    # @return [Boolean] true when it started the thread
    # @api public
    def self.start!(config = Cybertrain.config)
      return false if @running
      unless config.worker
        Cybertrain.logger.info("Background worker off (CYBERTRAIN_WORKER=0): scheduled tasks and jobs run elsewhere")
        return false
      end

      return false if TASKS.empty? && !Job.handlers?

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
    # every task whose time has come (in registration order); then, when
    # {Job} threads run in this process and a minute has passed since the
    # last one, {Job.recover!}; and records `now` as {Scheduler.last_tick}.
    # A task the scheduler sees for the first time is only scheduled,
    # `seconds` after `now`. A tick that cannot reach the database logs the
    # error, runs nothing and counts as not leading; the next one tries
    # again. The thread calls it with the current time; tests call it with
    # chosen times instead of sleeping.
    # @param now [Integer] epoch seconds
    # @return [Integer] how many tasks ran (including ones that raised)
    # @api public
    def self.run_due(now)
      leader = acquire_safely(now)
      @leader = leader
      ran = 0
      i = 0
      while i < TASKS.size
        task = TASKS[i]
        due = task.task_next_run
        if due == 0
          task.task_next_run = now + task.task_interval
        elsif due <= now && leader
          task.task_next_run = now + task.task_interval
          run_task(task)
          ran += 1
        end
        i += 1
      end
      recover_jobs(now) if Job.running? && (@last_recovery == 0 || now - @last_recovery >= RECOVERY_INTERVAL)
      LOCK.synchronize { @last_tick = now }
      ran
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

    # Runs one task with its rescue in a plain method that reads the Proc
    # from the Task rather than yielding (NOTES rules 32/45/69); naming
    # JSON::NestingError first (rule 61). False when it raised.
    def self.run_task(task)
      task.task_block.call
      true
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      Cybertrain.logger.error("Scheduled task #{task.task_name.inspect} failed: #{e.class.name}: #{e.message}")
      false
    end

    # Sets every task's next run `interval` after now (start! does this so
    # a restart does not run everything at once).
    def self.schedule_all(now)
      i = 0
      while i < TASKS.size
        task = TASKS[i]
        task.task_next_run = now + task.task_interval
        i += 1
      end
      nil
    end

    # "name every Ns, ..." for the start line; "no scheduled tasks" when
    # none is registered.
    def self.task_summary
      return "no scheduled tasks" if TASKS.empty?

      out = +""
      i = 0
      while i < TASKS.size
        task = TASKS[i]
        out << ", " unless out.empty?
        out << task.task_name
        out << " every "
        out << task.task_interval.to_s
        out << "s"
        i += 1
      end
      out
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
