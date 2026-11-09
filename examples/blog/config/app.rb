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
# scheduler thread of the process that runs jobs, the usual prune of a
# `sessions` table. The blog keeps its sessions in the cookie and has no
# such table, so the task checks for it first: an app with one (what
# `cybertrain generate authentication` writes) keeps the DELETE alone.
Cybertrain::Scheduler.cron("0 4 * * *", "prune sessions") do
  Cybertrain::DB.with do |c|
    tables = c.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'sessions'")
    c.execute("DELETE FROM sessions WHERE updated_at < datetime('now', '-30 days')") unless tables.empty?
    nil
  end
  nil
end
