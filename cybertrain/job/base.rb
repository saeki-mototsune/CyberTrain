module Cybertrain
  module Job
    # The superclass of an application's job classes (app/jobs/*.rb):
    #
    #   class WelcomeJob < Cybertrain::Job::Base
    #     retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5
    #     discard_on ArgumentError
    #     limits_concurrency to: 1, key: "user_id"
    #
    #     def perform(args)
    #       user = User.find(Cybertrain::Cast.int(args["user_id"]))
    #       Cybertrain::Mailer.deliver(to: user.email, subject: "Welcome", body: "Hello!\n")
    #     end
    #   end
    #
    #   WelcomeJob.perform_later("user_id" => user.id)
    #
    # `spin run gen` reads the class as text and writes its other half into
    # gen/jobs.rb: `job_kind`, `perform_later`, `perform_at`, `perform_in`,
    # `perform_now` and `run_job`, with the policies as literal `rescue`
    # arms, and the {Job.register} call. The macros here do nothing at run
    # time; they exist so that the class body loads. Write each on one line
    # with literal values (an Integer or `:polynomially_longer` for `wait:`,
    # an Integer for `attempts:` and `to:`, a String for `key:`), and name
    # only exception classes the program defines before the job: core
    # classes, the framework's own (the mailer's, the HTTP client's, the
    # socket layer's), or a class under app/models, in
    # app/jobs/application_job.rb, or above the macro in the job's file.
    # @api public
    class Base
      # Declares a retry policy, read by `spin run gen`: when `perform`
      # raises the class (or a subclass), the job is queued again after
      # `wait:` seconds (default 3; `:polynomially_longer` waits
      # `attempts ** 4 + 2`), until `attempts:` attempts (default 5, the
      # first included) have failed; then the row is `failed` and
      # {#retries_exhausted} runs. Several lines may be given: the first
      # whose class matches wins.
      # @example
      #   retry_on Cybertrain::HttpClient::TimeoutError, wait: :polynomially_longer, attempts: 10
      # @param args [Array] the exception class and the `wait:` / `attempts:` options
      # @return [nil]
      # @api public
      def self.retry_on(*args)
        nil
      end

      # Declares that an exception of the class (or a subclass) ends the
      # job at once, `discarded`, with no retry and no {#retries_exhausted}.
      # @example
      #   discard_on ArgumentError
      # @param args [Array] the exception class
      # @return [nil]
      # @api public
      def self.discard_on(*args)
        nil
      end

      # Declares a concurrency limit, read by `spin run gen`: at most `to:`
      # jobs of the class running at once across every process, counted per
      # value of the args field `key:` when given ({Job.register}).
      # @example
      #   limits_concurrency to: 1, key: "user_id"
      # @param opts [Hash] `to:` (Integer, default 1) and `key:` (String)
      # @return [nil]
      # @api public
      def self.limits_concurrency(**opts)
        nil
      end

      # The job's work. `args` is the Hash given to `perform_later`, read
      # back from JSON: narrow its values with {Cast.int}, {Cast.str},
      # {Cast.hash}, {Cast.array}.
      # @param args [Hash{String => Object}]
      # @return [Object] ignored
      # @raise [NotImplementedError] unless the job class defines it
      # @api public
      def perform(args)
        message = "#{self.class.name}#perform is not defined"
        raise NotImplementedError, message
      end

      # Runs once when a `retry_on` policy has used its last attempt and the
      # row became `failed` (never for an attempt whose row was taken over
      # by another worker, nor for `discard_on`). The default does nothing.
      # @param error [StandardError] the exception of the last attempt
      # @return [nil]
      # @api public
      def retries_exhausted(error)
        nil
      end
    end
  end
end
