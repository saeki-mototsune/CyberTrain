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

  # Content Security Policy, sent with every response. Scripts come from
  # this origin and the one jsDelivr path that holds Turbo (pinned in
  # config/importmap.rb), not the whole CDN;
  # styles and images from this origin (and data: images). The inline
  # import map and its `import "application"` carry this response's nonce
  # (javascript_importmap_tags), as does the csp-nonce meta tag
  # (csp_meta_tag) for scripts that add elements.
  c.content_security_policy do |p|
    p.default_src :self
    p.script_src :self, "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/"
    p.style_src :self
    p.img_src :self, :data
  end
  c.content_security_policy_nonce_directives = %w[script-src style-src]
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
