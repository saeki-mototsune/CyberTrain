module Admin
  # A namespaced job: polynomially longer waits, 20 attempts, no
  # concurrency limit. Its `retry_on StandardError` comes before the
  # `discard_on ArgumentError`, so an ArgumentError is retried: the first
  # declared policy wins (rescue arms are tried in order).
  class ReportJob < Cybertrain::Job::Base
    retry_on StandardError, wait: :polynomially_longer, attempts: 20
    discard_on ArgumentError

    def perform(args)
      raise ArgumentError, "bad report #{Cybertrain::Cast.str(args["name"])}" if Cybertrain::Cast.str(args["fail"]) == "argument"

      nil
    end
  end
end
