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
