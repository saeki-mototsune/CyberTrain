# Application settings; see Cybertrain::Config for every option.
# Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
# CYBERTRAIN_SECRET_KEY_BASE, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
# CYBERTRAIN_SESSION_PARTITIONED) are read before this block runs.
Cybertrain.configure do |c|
  # c.port = 3000
  # c.workers = 1

  # Keep request logs out of the test programs' output (their stdout is
  # compared with test/*.rb.expected).
  c.log_level = :none if c.test?
end

# Every day at 04:00 (CYBERTRAIN_SCHEDULER_TZ, UTC by default), on the
# scheduler thread of the process that runs jobs: every comment leaves a
# `done` NotifyCommentJob row in cybertrain_jobs, so the rows done more than
# 7 days ago are deleted. Failed and discarded rows stay for the jobs page
# (`./blog jobs prune` removes those).
Cybertrain::Scheduler.cron("0 4 * * *", "prune done jobs") do
  Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)
  nil
end
