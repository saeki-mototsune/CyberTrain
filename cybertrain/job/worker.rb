# Required by cybertrain/job.rb, after Store and Executor.
module Cybertrain
  module Job
    # The thread pool of a process that runs jobs: Config#job_threads job
    # threads that each call {Job::Executor.work_one} in a loop, and one
    # heartbeat thread. It owns starting, the stop flag, the drain and the
    # count of live loops, and nothing about a row: it holds no SQL (the
    # start's recovery and the heartbeat go through {Job.recover!},
    # {Job.backfill_keys} and {Job.heartbeat!}, which {Job::Store} writes)
    # and it does not look at a job's outcome. The public entry points and
    # their documentation are the `Job.*` methods of cybertrain/job.rb,
    # which delegate here.
    module Worker
      # Guards @live_loops and @stop_seen_at, which every job thread
      # changes and stop! reads, and the step of @generation, which decides
      # whose stop a thread may note.
      POOL_LOCK = Mutex.new

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
      # Monotonic seconds when a thread of the current generation first saw
      # the stop; 0.0 until then. Written by the threads, not the trap (no
      # clock call in a signal handler), and only by threads of the pool
      # stop! will drain: a thread left from before a restart saw another
      # pool's stop (note_stop_seen).
      @stop_seen_at = 0.0

      # {Job.start!}.
      def self.start!(config)
        return false if @started
        unless Job.handlers?
          Cybertrain.logger.info("No job handler registered; job threads not started")
          return false
        end

        Job.install!
        @heartbeat_stale = config.job_heartbeat_stale
        now = Time.now.to_i
        requeued = Job.recover!(now, config.job_heartbeat_stale)
        Cybertrain.logger.warn("Requeued #{requeued} job(s) whose process stopped sending heartbeats") if requeued > 0
        keyed = Job.backfill_keys(now)
        Cybertrain.logger.info("Keyed #{keyed} queued job(s) enqueued before their kind's concurrency key") if keyed > 0
        # spikes/NOTES.md rule 22: before the first Thread.new.
        ENV["SPINEL_WORKERS"] = "1" unless ENV["SPINEL_WORKERS"]
        @poll_interval = config.job_poll_interval
        @heartbeat_interval = config.job_heartbeat_interval
        @drain_timeout = config.job_drain_timeout
        generation = begin_generation
        @started = true
        @running = true
        count = config.job_threads
        Cybertrain.logger.info("Job threads started: #{count} (#{Job.process_label})")
        i = 0
        while i < count
          loop_started
          spawn_job_thread(i, generation)
          i += 1
        end
        spawn_heartbeat(generation)
        true
      end

      # {Job.stop!}.
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
      def self.request_stop
        @running = false
        nil
      end

      # @return [Boolean] true between {Job.start!} and {Job.stop!} (or
      #   {Job.request_stop})
      def self.running?
        @running
      end

      # When a job thread first saw the stop (monotonic seconds), 0.0 before.
      def self.stop_seen_at
        at = 0.0
        POOL_LOCK.synchronize { at = @stop_seen_at }
        at
      end

      # Notes when a thread of `generation` saw the stop, the first time
      # only, and only while that generation is the current one. After a
      # stop! that timed out and a start!, a thread of the pool before (a
      # job that outlived the drain, a heartbeat late to wake) ends here
      # too: its stop is not the new pool's, and its stamp would make the
      # next stop! count the drain from a time long past.
      def self.note_stop_seen(generation)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        POOL_LOCK.synchronize do
          @stop_seen_at = now if generation == @generation && @stop_seen_at == 0.0
        end
        nil
      end

      # start!'s step to the next generation: the number and the cleared
      # stop time change together under the lock note_stop_seen takes, so
      # no thread of the generation before can stamp between the two.
      # Returns the new generation.
      def self.begin_generation
        generation = 0
        POOL_LOCK.synchronize do
          @generation += 1
          @stop_seen_at = 0.0
          generation = @generation
        end
        generation
      end

      # How many job threads have not ended yet (a thread finishing its job
      # after stop! counts until it has).
      def self.live_loops
        n = 0
        POOL_LOCK.synchronize { n = @live_loops }
        n
      end

      def self.loop_started
        POOL_LOCK.synchronize { @live_loops += 1 }
        nil
      end

      def self.loop_ended
        POOL_LOCK.synchronize { @live_loops -= 1 }
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
      # (claim_safely rescues every Exception, so nothing a job raises ends
      # the thread; loop_ended is in an `ensure` all the same, so the
      # live-loop count stays right whatever happens, and no stop! waits the
      # whole job_drain_timeout for a thread that is gone.)
      def self.run_job_loop(index, generation)
        while pool_live?(generation)
          idle_wait(@poll_interval, generation) unless claim_safely(Time.now.to_i, index, generation)
        end
        note_stop_seen(generation)
        nil
      ensure
        loop_ended
      end

      # work_one with its rescue in a plain method (NOTES rules 32/45): a
      # database error (locked past the busy timeout, a disk error) is logged
      # and the thread waits a poll interval instead of dying. False then.
      #
      # Anything else that reaches here (an Exception subclass that
      # run_handler does not survive, raised by a job) is logged too, so a
      # job thread never ends while the pool is live: the row is left
      # `running` for heartbeat recovery, which fails it at recovery_limit.
      #
      # The generation goes with the claim as its ticket: a claim that
      # waited for the write lock is asked again under it ({Job.claim_open?}),
      # so a stop requested during the wait is seen before a row is taken.
      def self.claim_safely(now, index, generation)
        Executor.work_one_under(now, generation)
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        Cybertrain.logger.error("Job thread #{index}: #{e.class.name}: #{e.message}")
        false
      rescue Exception => e
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
        note_stop_seen(generation)
        nil
      end

      def self.beat_safely(now)
        Job.heartbeat!(now)
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        Cybertrain.logger.error("Job heartbeat: #{e.class.name}: #{e.message}")
        0
      end

      # The stale default of recover!.
      def self.heartbeat_stale
        @heartbeat_stale > 0 ? @heartbeat_stale : Cybertrain.config.job_heartbeat_stale
      end
    end
  end
end
