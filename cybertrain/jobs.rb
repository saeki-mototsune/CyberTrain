# cybertrain/jobs: background jobs and scheduled tasks, an optional
# subsystem (require "cybertrain/jobs" in bin/NAME.rb, after or instead of
# require "cybertrain"; docs/superpowers/specs/
# 2026-11-13-optional-subsystems-design.md):
#
#   Job, job classes and their retries      cybertrain/job.rb
#   Scheduler, `every` and `cron`           cybertrain/scheduler.rb, cron.rb
#   the scheduler lease                     cybertrain/lease.rb
#   `./NAME worker`                         cybertrain/roles/worker.rb
#   the jobs page and `./NAME jobs ...`     cybertrain/jobs_page.rb, job/cli.rb
#
# It loads the core too. The core never names any of this: the server role,
# boot, `/up` and Main.run reach jobs through JobsFeature, which this file
# registers at its end (cybertrain/feature.rb). Requiring it twice, or after
# require "cybertrain", is a no-op.
require "cybertrain/core"
require "cybertrain/feature"
require "cybertrain/job"
require "cybertrain/lease"
require "cybertrain/cron"
require "cybertrain/scheduler"
require "cybertrain/jobs_page"
require "cybertrain/job/cli"
require "cybertrain/roles/worker"

module Cybertrain
  class Application
    # `./<app> worker` (Main.run): boots (the config checks, the database)
    # and runs Roles::WorkerRunner: a banner, the scheduler (lease-gated:
    # several workers may share the database) and the job threads, until
    # SIGTERM or SIGINT (or Application.request_stop_roles), then their
    # shutdown (the job threads finish their jobs, for at most
    # Config#job_drain_timeout seconds). No port, no HTTP. Config#worker is
    # set: in this role it is what the process is for. Defined here, on
    # the core's Application, by cybertrain/jobs.
    # @param argv [Array<String>] what follows `worker`; must be empty
    # @return [Integer] the exit status
    # @api public
    def run_worker(argv)
      unless argv.empty?
        puts "error: worker takes no arguments (got #{argv.join(" ")})"
        STDOUT.flush
        return 1
      end
      # Before anything shared changes: a second role in a process that
      # runs one must not clear its stop flag or re-apply the settings.
      busy = Runtime.role_problem
      return Roles.refuse(busy) unless busy.empty?

      # Before boot: a stop asked for while booting is kept.
      Roles.reset_stop
      @config.worker = true
      boot
      Roles::WorkerRunner.new(@config).run_worker
    end
  end

  module Main
    # `./<name> jobs ...`: Job::CLI.run with the database connected as for
    # a registered command (a pool of one; no server, scheduler or job
    # thread). Returns its exit status, or 1 when the database cannot be
    # opened. The rescue sits in this plain method (NOTES rules 32/45).
    def self.run_jobs(args)
      status = 0
      begin
        DB.connect(Cybertrain.config.database_path, size: 1)
        status = Job::CLI.run(args)
      rescue DB::Error => e
        puts "jobs failed: #{e.message}"
        status = 1
      ensure
        DB.disconnect
      end
      status
    end
  end

  # What jobs adds to the core, through Feature's hooks: the boot check of
  # cron tasks' job kinds, the scheduler and job threads of the server role
  # (started after its banner, asked to stop by its TERM trap, stopped when
  # it ends), the worker staleness of `/up`, the `worker` and `jobs`
  # commands with their help lines, and every feature's periodic hook run
  # as a scheduler task (the cache's prune).
  # @api private
  class JobsFeature < Feature
    def feature_name
      "jobs"
    end

    # A cron task's job: kind no Job.handle registered.
    def boot_problem(config)
      Scheduler.job_kinds_error
    end

    # The scheduler always (it decides itself whether to run: Config#worker,
    # tasks or handlers), the job threads when Config#worker.
    def start_feature(config)
      Scheduler.start!(config)
      Job.start!(config) if config.worker
      nil
    end

    # Both are no-ops for what never started.
    def stop_feature
      Job.stop!
      Scheduler.stop!
      nil
    end

    # Flags only: the job threads stop claiming while the requests drain.
    def request_stop_feature
      Job.request_stop
      nil
    end

    # Only a running Scheduler can be stale; before its first tick
    # (last_tick 0, the moment after start) it is not.
    def health_problem(now, worker_stale, feeds, feed_stale)
      return "" unless Scheduler.running?

      tick = Scheduler.last_tick
      tick > 0 && now - tick > worker_stale ? "worker stale" : ""
    end

    def run_feature_command(word, args, name, router, url_resolver, views)
      case word
      when "worker" then Main.role_app(name, router, url_resolver, views).run_worker(args)
      when "jobs" then Main.run_jobs(args)
      else -1
      end
    end

    def feature_usage(name, slot)
      case slot
      when "roles"
        "  ./#{name} worker            run jobs and scheduled tasks, without HTTP\n"
      when "commands"
        # The continuation lines up under "migrate" whatever the name.
        indent = "".ljust(name.size + 23)
        "  ./#{name} #{"jobs COMMAND".ljust(17)} list [STATE] | retry ID | retry --all | discard ID | delete ID\n" \
          "#{indent}prune [--before DAYS]\n"
      else ""
      end
    end

    def schedules_periodic?
      true
    end

    # One Scheduler.every task per feature with a periodic hook, under the
    # feature's task name, once.
    def schedule_periodic(index, task_name, interval)
      return nil if Scheduler.task_index(task_name) >= 0

      JobsFeature.every_periodic(index, task_name, interval)
    end

    # The task's block captures only the Integer index (a parameter of this
    # method) and calls Features.run_periodic, which calls the hook on the
    # Array element outside the block (NOTES rules 88 and 101).
    def self.every_periodic(index, task_name, interval)
      Scheduler.every(interval, task_name) { Features.run_periodic(index, Time.now.to_i) }
      nil
    end
  end
end

Cybertrain::Features.register_feature(Cybertrain::JobsFeature.new)
