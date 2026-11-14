# Required by cybertrain/job.rb, after the registry, RetryPolicy and Store.
require "cybertrain/error_reporter"

module Cybertrain
  module Job
    # One attempt of one job, on the calling thread: claim a due row
    # ({Job::Store.claim}), run its handler, decide the outcome
    # ({Job::RetryPolicy}) and have it written ({Job::Store.write_outcome}),
    # trying the write again when the database raises. It holds no SQL and
    # starts no thread: a job thread of {Job::Worker} calls work_one in a
    # loop, and a test or a {Main.command} calls it directly. What it keeps
    # is the list of claims in flight here (row id and attempt number),
    # which the heartbeat reads.
    # The public entry points and their documentation are the `Job.*`
    # methods of cybertrain/job.rb, which delegate here.
    module Executor
      # Guards IN_FLIGHT, which every job thread changes and the heartbeat
      # thread reads.
      FLIGHT_LOCK = Mutex.new

      # The jobs this process has claimed and not yet finished writing the
      # outcome of: the only rows its heartbeat keeps alive. Two arrays of
      # one length, the row's id and the attempt number of the claim at the
      # same index: the pair is the claim (as (label, attempts) fences the
      # outcome), so an attempt that outlived its claim does not heartbeat
      # the row's next one (D78). Constants (NOTES rule 64), seeded and
      # emptied (rule 9).
      IN_FLIGHT = Array.new(0) { 0 }
      IN_FLIGHT_ATTEMPTS = Array.new(0) { 0 }

      # The ticket of a claim made outside a pool ({Job.work_one} from a
      # test or a {Main.command}): {Job.claim_open?} never refuses it.
      NO_TICKET = -1

      # How many times an outcome write is tried before the row is left to
      # staleness recovery, and the pause before each retry (times the try).
      OUTCOME_TRIES = 3
      OUTCOME_RETRY_PAUSE = 0.05

      # A copy of IN_FLIGHT.
      def self.in_flight_ids
        out = Array.new(0) { 0 }
        FLIGHT_LOCK.synchronize { IN_FLIGHT.each { |id| out << id } }
        out
      end

      # The claims in flight, read under one lock: the id and then the
      # attempt number of each, one after the other.
      def self.in_flight_claims
        out = Array.new(0) { 0 }
        FLIGHT_LOCK.synchronize do
          i = 0
          while i < IN_FLIGHT.size
            out << IN_FLIGHT[i]
            out << IN_FLIGHT_ATTEMPTS[i]
            i += 1
          end
        end
        out
      end

      def self.in_flight_add(id, attempts)
        FLIGHT_LOCK.synchronize do
          IN_FLIGHT << id
          IN_FLIGHT_ATTEMPTS << attempts
        end
        nil
      end

      # Removes the entry of the claim (id, attempts). The same row can be
      # in flight twice, under two attempt numbers, when it was recovered
      # and claimed again here while its first run went on.
      def self.in_flight_remove(id, attempts)
        FLIGHT_LOCK.synchronize do
          at = -1
          i = 0
          while at < 0 && i < IN_FLIGHT.size
            at = i if IN_FLIGHT[i] == id && IN_FLIGHT_ATTEMPTS[i] == attempts
            i += 1
          end
          if at >= 0
            IN_FLIGHT.delete_at(at)
            IN_FLIGHT_ATTEMPTS.delete_at(at)
          end
        end
        nil
      end

      # {Job.work_one}: claims the oldest job due at `now`, runs it and has
      # its outcome written. True when a job was claimed.
      def self.work_one(now)
        work_one_under(now, NO_TICKET)
      end

      # work_one for a caller whose claim can be withdrawn while it waits
      # for the write lock: `ticket` is what {Job.claim_open?} is asked
      # about under that lock (a job thread passes its pool's generation).
      def self.work_one_under(now, ticket)
        run = Store.claim(now, Job.process_label, ticket)
        return false if run.run_id < 0

        finish_in_flight(run)
        true
      end

      # {Job.work_one_after_id}: claims the queued job with the lowest id
      # above `floor` (of `kind` unless ""; a retry only once due at
      # `now`), runs it at `now` and has its outcome written. Its id, -1 when
      # none was claimed.
      def self.work_one_after_id(floor, kind, now)
        run = Store.claim_after(floor, kind, now, Job.process_label, NO_TICKET)
        return -1 if run.run_id < 0

        finish_in_flight(run)
        run.run_id
      end

      # finish between in_flight_add and in_flight_remove, in a plain method
      # with an `ensure` (NOTES rules 32/45): the claim leaves IN_FLIGHT whatever
      # the handler raised. run_handler rescues StandardError and the
      # NotImplementedError / SystemStackError / ScriptError arm; anything
      # else reaches Worker.claim_safely, which logs it, and without this the
      # row would be heartbeated for the life of the process and never
      # recovered.
      # The job's log Scope ({job_scope}) is this thread's while it runs and
      # its outcome is written; the one found before is back in the `ensure`
      # (rule 103's save-yield-ensure, no rescue), so a job thread starts
      # the next job from its own Scope, never with this job's tags.
      def self.finish_in_flight(run)
        saved = Logger.current_scope
        in_flight_add(run.run_id, run.run_attempts)
        Logger.swap_scope(job_scope(run))
        finish(run)
      ensure
        Logger.swap_scope(saved)
        in_flight_remove(run.run_id, run.run_attempts)
      end

      # The log Scope of one attempt (spec section 12.3): the tag
      # `"<kind> <id>"`, then the id of the request that enqueued it when
      # it was enqueued in one and {Config#log_tags} includes :request_id;
      # `where` is the kind; the context holds `job.id`, `job.attempt` and
      # `job.max_attempts`.
      #
      # `job.max_attempts` in an error report (plan D10) means, by how the
      # attempt failed:
      # - the default policy (the exception reached {run_handler}): the
      #   Scope's value here, {Config#job_max_attempts}, whatever the kind's
      #   `max_attempts:` or `retry_on` policies (so an application's own
      #   `Cybertrain.error.report` inside a job also carries this value);
      # - a `retry_on` ({retry_later}): the policy's `attempts:`, which that
      #   report puts in place of this one;
      # - a `discard_on` ({discard}): the attempt it ended at, the last one,
      #   since no other will run (not the kind's limit).
      # The request id is the Scope's request id whether or not it is
      # shown, so a job this one enqueues records it too.
      # @param run [Run]
      # @return [Logger::Scope]
      # @api private
      def self.job_scope(run)
        id = run.run_id
        attempts = run.run_attempts
        request_id = run.run_request_id
        kind = "#{run.run_kind}"
        verb = ""
        path = ""
        tags = Array.new(0) { "" }
        tags << "#{kind} #{id}"
        id_tag = -1
        if !request_id.empty? && Cybertrain.config.log_tags.include?(:request_id)
          tags << request_id
          id_tag = 1
        end
        max = Cybertrain.config.job_max_attempts.to_s
        context = { "job.id" => id.to_s, "job.attempt" => attempts.to_s, "job.max_attempts" => max }
        Logger::Scope.new(request_id, verb, path, kind, tags, id_tag, context)
      end

      # {Job.work_due}.
      def self.work_due(now, limit)
        count = 0
        while count < limit
          break unless work_one(now)
          count += 1
        end
        count
      end

      # Runs a claimed job's handler and writes the outcome back, fenced by
      # the claim (its label and attempt number): when the row was
      # recovered and claimed again while the handler ran (its heartbeat went
      # stale), the outcome is discarded and the row is left to its new
      # claimer. Delivery is therefore at least once: write handlers so that
      # running twice is harmless. Nothing is written for a Run whose block
      # wrote its own outcome ({Job.retry_later}, {Job.discard}).
      def self.finish(run)
        logger = Cybertrain.logger
        id = run.run_id
        kind = run.run_kind
        attempts = run.run_attempts
        now = run.run_now
        label = run.run_claimed_by
        index = Job.handler_index(kind)
        if index < 0
          message = "no handler registered for kind #{kind.inspect}"
          return nil unless outcome_written?(id, kind, record_outcome(id, "failed", now, message, now, label, attempts))

          logger.error("job #{id} (#{kind}) failed: #{message}")
          return nil
        end
        error = run_handler(HANDLERS[index], run)
        if run.run_outcome_written?
          logger.error("job #{id} (#{kind}) raised after its outcome was written: #{error}") unless error.empty?
          return nil
        end
        if error.empty?
          return nil unless outcome_written?(id, kind, record_outcome(id, "done", now, "", now, label, attempts))

          logger.info("job #{id} (#{kind}) done")
          return nil
        end
        max = Cybertrain.config.job_max_attempts
        if RetryPolicy.exhausted?(attempts, max)
          return nil unless outcome_written?(id, kind, record_outcome(id, "failed", now, error, now, label, attempts))

          logger.error("job #{id} (#{kind}) failed after #{attempts} attempts: #{error}")
        else
          wait = RetryPolicy.default_wait(attempts)
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
      # The exceptions outside StandardError that a job's own code raises
      # (`raise NotImplementedError` in a helper not yet written, a recursion
      # too deep, a `require` that fails) take the default policy as a
      # StandardError does, instead of ending the job thread.
      # Each run starts at the default locale, as a controller action does:
      # a job thread is long-lived, so a locale one job set (`I18n.locale =
      # user.locale`) would otherwise stay for the next job on the thread.
      # Either arm reports the failed attempt (spec section 13.2, plan D10):
      # `where` the kind, the context the job Scope's.
      def self.run_handler(handler, run)
        I18n.locale = nil
        handler.handler_run_block.call(run)
        ""
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        Cybertrain.error.report_unhandled(e, run.run_kind, ErrorReporter::NO_CONTEXT)
        RetryPolicy.error_text(e.class.name, e.message)
      rescue NotImplementedError, SystemStackError, ScriptError => e
        Cybertrain.error.report_unhandled(e, run.run_kind, ErrorReporter::NO_CONTEXT)
        RetryPolicy.error_text(e.class.name, e.message)
      end

      # {Job.retry_later}: the outcome of a failed attempt under a
      # `retry_on` policy, written once and marked written on the Run. The
      # attempt is reported first, `job.max_attempts` the policy's.
      def self.retry_later(run, error, wait_base, polynomial, attempts_limit)
        limit = { "job.max_attempts" => attempts_limit.to_s }
        Cybertrain.error.report_unhandled(error, run.run_kind, limit)
        attempts = run.run_attempts
        wait = RetryPolicy.policy_wait(attempts, wait_base, polynomial)
        message = RetryPolicy.error_text(error.class.name, error.message)
        now = run.run_now
        id = run.run_id
        kind = run.run_kind
        run.run_outcome_written!
        unless RetryPolicy.exhausted?(attempts, attempts_limit)
          code = record_outcome(id, "queued", now + wait, message, now, run.run_claimed_by, attempts)
          return OUTCOME_STALE unless outcome_written?(id, kind, code)

          Cybertrain.logger.error("job #{id} (#{kind}) attempt #{attempts} of #{attempts_limit} failed: #{message}; retrying in #{wait} s")
          return OUTCOME_REQUEUED
        end
        code = record_outcome(id, "failed", now, message, now, run.run_claimed_by, attempts)
        return OUTCOME_STALE unless outcome_written?(id, kind, code)

        Cybertrain.logger.error("job #{id} (#{kind}) failed after #{attempts} attempts: #{message}")
        OUTCOME_FAILED
      end

      # {Job.discard}: the row becomes `discarded`, written once and marked
      # written on the Run. Reported first. The report's `job.max_attempts`
      # is the attempt it ended at, equal to its `job.attempt`: the last
      # attempt, since no other will run; it is not the kind's limit (the
      # three meanings: {job_scope}).
      def self.discard(run, error)
        limit = { "job.max_attempts" => run.run_attempts.to_s }
        Cybertrain.error.report_unhandled(error, run.run_kind, limit)
        message = RetryPolicy.error_text(error.class.name, error.message)
        now = run.run_now
        id = run.run_id
        kind = run.run_kind
        run.run_outcome_written!
        code = record_outcome(id, "discarded", now, message, now, run.run_claimed_by, run.run_attempts)
        return OUTCOME_STALE unless outcome_written?(id, kind, code)

        Cybertrain.logger.error("job #{id} (#{kind}) discarded: #{message}")
        OUTCOME_FAILED
      end

      # Has the outcome of the claim (`label`, `attempts`) written, trying
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
        Store.write_outcome(id, state, run_at, error, now, label, attempts)
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        Cybertrain.logger.error("job #{id}: outcome write #{try} of #{OUTCOME_TRIES} failed: #{e.class.name}: #{e.message}")
        -1
      end
    end
  end
end
