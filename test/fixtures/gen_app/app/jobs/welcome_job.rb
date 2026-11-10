# What WelcomeJob did, for test/gen_jobs_compiles.rb (a constant: NOTES
# rule 64).
WELCOME_LOG = Array.new(0) { "" }

# The spec's example job (section 2.1). args["mode"] makes it fail for the
# compiled test: "timeout" raises the mailer's TimeoutError (retried every
# 60 s, 5 attempts), "bad" an ArgumentError (discarded), "steal" plays a
# worker whose row was reclaimed while it ran, then times out.
class WelcomeJob < Cybertrain::Job::Base
  retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5
  discard_on ArgumentError
  limits_concurrency to: 1, key: "user_id"

  def perform(args)
    mode = Cybertrain::Cast.str(args["mode"])
    WELCOME_LOG << "perform #{Cybertrain::Cast.int(args["user_id"])} #{mode}"
    if mode == "steal"
      Cybertrain::DB.with do |c|
        c.execute("UPDATE cybertrain_jobs SET claimed_by = 'thief:1:1:abcdef' WHERE kind = 'WelcomeJob' AND state = 'running'")
      end
    end
    raise Cybertrain::Mailer::TimeoutError, "smtp timed out" if mode == "timeout" || mode == "steal"
    raise ArgumentError, "no such user" if mode == "bad"

    nil
  end

  def retries_exhausted(error)
    WELCOME_LOG << "exhausted #{error.message}"
    nil
  end
end
