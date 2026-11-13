# Application settings; see Cybertrain::Config for every option.
# Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
# CYBERTRAIN_SECRET_KEY_BASE, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
# CYBERTRAIN_SESSION_PARTITIONED, CYBERTRAIN_ALLOWED_HOSTS) are read before this block runs.
Cybertrain.configure do |c|
  # c.port = 3000
  # c.workers = 1

  # Development accepts localhost, 127.0.0.1 and [::1]. Add an exact
  # forwarding hostname here or via CYBERTRAIN_ALLOWED_HOSTS (comma-separated).
  # c.allowed_hosts << "my-preview.example.com"

  # Production marks the session cookie Secure (HTTPS only). Turn it
  # off only if production is really served over plain http://.
  # c.session_secure = false
end
