require "cybertrain/job"
require "cybertrain/scheduler"
require "cybertrain/error_reporter"

module Cybertrain
  module Roles
    # `./<app> worker`: the scheduler (lease-gated: several workers may
    # share the database) and the job threads, until SIGTERM or SIGINT (or
    # Roles.request_stop), then their shutdown: the job threads finish
    # their jobs, for at most Config#job_drain_timeout seconds. No port, no
    # HTTP. The Application has booted before #run_worker is called.
    #
    #   starts   Scheduler, Job
    #   waits    Roles.wait_stop (TERM, INT)
    #   stops    Job, Scheduler; waits up to 2 s for the queued error
    #            reports; the TERM and INT handlers given back
    # @api private
    class WorkerRunner
      # @param config [Config] the booted Application's
      def initialize(config)
        @config = config
      end

      # @return [Integer] the exit status
      def run_worker
        config = @config
        # What the server gives Spinel for the same config (NOTES rule 22),
        # the development limit of one included: a job callback renders
        # partials and components through the same cache: false engine.
        ENV["SPINEL_WORKERS"] = Application.spinel_workers_for(config).to_s
        threads = config.job_threads
        tasks = Scheduler::TASKS.size
        jobs = Job.handlers? ? "#{threads} job thread#{threads == 1 ? "" : "s"}" : "no job handler"
        Roles.print_banner(config, "worker: #{jobs}, #{tasks} scheduled task#{tasks == 1 ? "" : "s"}")
        busy = Runtime.enter_role("worker")
        return Roles.refuse(busy) unless busy.empty?

        # INT as TERM: a worker run in a terminal and stopped with Ctrl-C
        # drains its jobs too, rather than dying with its rows left
        # `running` until job_heartbeat_stale. Both handlers are given back
        # when the role ends (test/main_roles.rb sends the signals and
        # checks the handlers come back).
        previous_term = trap("TERM") { Roles.request_stop }
        previous_int = trap("INT") { Roles.request_stop }
        run_worker_threads(previous_term, previous_int)
      end

      private

      # The worker's lifetime. Stops what started and restores the TERM and
      # INT handlers the role replaced, also when a start or a stop raises
      # (D66): an in-process caller (a test) keeps its own handlers, and a
      # later Ctrl-C ends the process again instead of setting a flag
      # nobody waits for.
      # @param previous_term [Object] what trap("TERM") answered: the
      #   handler Proc, or a name such as "DEFAULT"
      # @param previous_int [Object] the same for INT
      # @return [Integer] 0
      def run_worker_threads(previous_term, previous_int)
        Scheduler.start!(@config)
        Job.start!(@config)
        Roles.wait_stop
        0
      ensure
        # Both stops are no-ops for what never started.
        Job.stop!
        Scheduler.stop!
        # The error reports still queued, up to 2 seconds (docs/design.md D88).
        Cybertrain.error.drain_reports(2.0)
        Runtime.leave_role
        trap("TERM", previous_term)
        trap("INT", previous_int)
      end
    end
  end
end
