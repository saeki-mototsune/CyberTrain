module Cybertrain
  module Job
    # What happens to an attempt that failed, as arithmetic: how long to
    # wait, whether another attempt is allowed, when stale-heartbeat
    # recovery gives up, and how much of the error is kept. It reads no
    # database, no Config and no clock, and requires nothing: every input
    # is an argument, so test/job_boundaries.rb checks it on its own.
    # {Job::Executor} applies the answers and {Job::Store} writes them.
    module RetryPolicy
      # Seconds to wait before the retry after the 1st, 2nd, 3rd and every
      # later failed attempt (the default policy).
      BACKOFF = [60, 300, 900, 3600].freeze

      # last_error keeps at most this many characters of the message.
      MAX_ERROR_LENGTH = 1000

      # Seconds to wait after the attempts-th failed attempt (1-based)
      # under the default policy.
      def self.default_wait(attempts)
        i = attempts - 1
        i = 0 if i < 0
        i = BACKOFF.size - 1 if i >= BACKOFF.size
        BACKOFF[i]
      end

      # Seconds to wait under a `retry_on` policy: `wait_base`, or with
      # `polynomial` attempts ** 4 + 2 (3, 18, 83, ...), in Integer
      # multiplications.
      def self.policy_wait(attempts, wait_base, polynomial)
        polynomial ? attempts * attempts * attempts * attempts + 2 : wait_base
      end

      # True when the attempts-th attempt (the first is 1) was the last
      # one a limit of `attempts_limit` allows: the row becomes `failed`
      # rather than `queued` again.
      def self.exhausted?(attempts, attempts_limit)
        attempts >= attempts_limit
      end

      # The attempt count at which stale-heartbeat recovery fails a row
      # instead of queueing it again: the larger of the configured default
      # and the kind's own `max_attempts:` (0 for none).
      def self.recovery_limit(own, default)
        own > default ? own : default
      end

      # What last_error holds for an exception of class `class_name` with
      # `message`: "Class: message", bounded.
      def self.error_text(class_name, message)
        bounded("#{class_name}: #{message}")
      end

      # text cut to MAX_ERROR_LENGTH characters.
      def self.bounded(text)
        return text if text.size <= MAX_ERROR_LENGTH

        text[0, MAX_ERROR_LENGTH]
      end
    end
  end
end
