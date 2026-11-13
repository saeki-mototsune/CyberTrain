# Config's checks and its file operations are separate steps (docs/design.md
# D65): Config#validation_error reads the settings and nothing else (no
# file, no directory, no database connection), in the order boot reports
# problems, and Config#resolve_secret! is the one method that writes.
#
# cybertrain/db links SQLite through FFI, so this runs compiled only
# (spikes/NOTES.md rule 23).
require "cybertrain"
require "cybertrain/db"
require "cybertrain/test"

SCRATCH = "tmp/config_validation_test"

def scratch_remove(path)
  if File.directory?(path)
    Dir.children(path).each { |child| scratch_remove("#{path}/#{child}") }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
  nil
end

scratch_remove(SCRATCH)
at_exit { scratch_remove(SCRATCH) }

# A config whose every path points into a directory that does not exist.
def scratch_config
  c = Cybertrain::Config.new
  c.env = "test"
  c.secret_key_base = ""
  c.secret_key_path = "#{SCRATCH}/secrets/secret_key"
  c.database_path = "#{SCRATCH}/db/test.sqlite3"
  c.upload_root = "#{SCRATCH}/uploads"
  c.views_root = "#{SCRATCH}/views"
  c.public_root = "#{SCRATCH}/public"
  c
end

test "a default config is valid" do
  assert_equal "", Cybertrain::Config.new.validation_error
end

test "validation creates no file or directory and connects no database" do
  c = scratch_config
  assert_equal "", c.validation_error
  c.max_page = 0
  assert_equal "max_page must be an Integer of at least 1 (got 0)", c.validation_error
  refute File.exist?(SCRATCH)
  refute Cybertrain::DB.connected?
  assert_equal "", c.secret_key_base
end

test "the first problem in boot's order is the one reported" do
  c = Cybertrain::Config.new
  c.encryption_key = "short"
  assert_equal "CYBERTRAIN_ENCRYPTION_KEY must be 64 hex characters; make one with `cybertrain secret --hex`", c.validation_error
  c.permissions_policy = "a\nb"
  assert_equal "permissions_policy must not contain CR or LF", c.validation_error
  c.stream_poll_ms = 9
  assert_equal "stream_poll_ms must be at least 10 (got 9)", c.validation_error
  c.feed_restart_limit = 0
  assert_equal "feed_restart_limit must be at least 1 (got 0)", c.validation_error
  c.health_path = "up"
  assert_equal "health_path must start with \"/\" (or be \"\" to turn the health check off), got \"up\"", c.validation_error
  c.trusted_proxies = ["not-an-address"]
  assert_includes c.validation_error, "trusted_proxies entry \"not-an-address\""
  c.max_page = 0
  assert_equal "max_page must be an Integer of at least 1 (got 0)", c.validation_error
  c.job_threads = 0
  assert_equal "job_threads must be at least 1 (got 0)", c.validation_error
  c.time_zone = "Mars/Base"
  assert_equal "time_zone \"Mars/Base\" is not a known time zone", c.validation_error
  c.max_multipart_parts = 4097
  assert_equal "max_multipart_parts must be an Integer from 1 to 4096 (got 4097)", c.validation_error
  c.max_body_bytes = 0
  assert_equal "max_body_bytes must be an Integer of at least 1 (got 0)", c.validation_error
  c.csrf_exempt_prefixes = ["/api"]
  assert_includes c.validation_error, "csrf_exempt_prefixes entry \"/api\""
  c.session_same_site = "lax"
  assert_includes c.validation_error, "session_same_site must be Lax, Strict or None"
end

# One accepted and one refused value at each area's edge, all through the
# aggregate (the areas' own methods have their cases in test/application.rb,
# test/health.rb, test/stream_endpoint.rb and test/boot_encryption.rb).
test "the web limits at their boundaries" do
  c = Cybertrain::Config.new
  c.max_body_bytes = 1
  c.max_upload_bytes = 1
  c.max_multipart_parts = 4096
  c.max_page = 1
  c.csrf_exempt_prefixes = ["/a/"]
  assert_equal "", c.validation_error
  c.max_upload_bytes = 2
  assert_equal "max_upload_bytes (2) must not exceed max_body_bytes (1)", c.validation_error
  c.max_upload_bytes = 1
  c.csrf_exempt_prefixes = ["/"]
  assert_includes c.validation_error, "must start and end with \"/\" and not be \"/\" alone"
end

test "the background settings at their boundaries" do
  c = Cybertrain::Config.new
  c.scheduler_interval = 1
  c.scheduler_lease_ttl = 2
  c.job_heartbeat_interval = 1
  c.job_heartbeat_stale = 2
  c.job_drain_timeout = 1
  c.feed_status_interval = 1
  c.feed_restart_limit = 1
  c.feed_restart_window = 1
  c.health_feed_stale = 2
  assert_equal "", c.validation_error
  c.scheduler_lease_ttl = 1
  assert_equal "scheduler_lease_ttl (1) must be at least twice scheduler_interval (1)", c.validation_error
  c.scheduler_lease_ttl = 2
  c.job_heartbeat_stale = 1
  assert_equal "job_heartbeat_stale (1) must be more than job_heartbeat_interval (1)", c.validation_error
  c.job_heartbeat_stale = 2
  c.scheduler_tz = "Mars/Olympus"
  assert_equal "scheduler_tz \"Mars/Olympus\" is not a known time zone", c.validation_error
end

test "the health check and the stream endpoint at their boundaries" do
  c = Cybertrain::Config.new
  c.health_path = ""
  c.stream_path = ""
  c.stream_poll_ms = 10
  c.stream_max_message = 125
  assert_equal "", c.validation_error
  c.health_path = "/same"
  c.stream_path = "/same"
  assert_equal "stream_path must differ from health_path (both are \"/same\")", c.validation_error
  c.stream_path = "/stream"
  c.stream_max_message = 124
  assert_equal "stream_max_message must be at least 125 (got 124)", c.validation_error
  c.stream_max_message = 125
  c.health_feeds = true
  c.health_feed_stale = c.feed_status_interval
  assert_includes c.validation_error, "must be more than feed_status_interval"
end

test "the encryption keys: unset is fine until a model declares encrypts" do
  c = Cybertrain::Config.new
  c.encryption_key = ""
  assert_equal "", c.validation_error
  was = Cybertrain::Config.encryption_required
  Cybertrain::Config.encryption_required = true
  assert_includes c.validation_error, "CYBERTRAIN_ENCRYPTION_KEY is not set"
  c.encryption_key = "ab" * 32
  assert_equal "", c.validation_error
  c.encryption_keys_previous = ["zz" * 32]
  assert_equal "CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS entry 1 must be 64 hex characters", c.validation_error
  Cybertrain::Config.encryption_required = was
end

test "resolve_secret! is the step that writes: the key file, once, for its owner only" do
  c = scratch_config
  refute File.exist?(c.secret_key_path)
  secret = c.resolve_secret!
  assert_equal 64, secret.length
  assert File.file?(c.secret_key_path)
  assert_equal 0o600, File.stat(c.secret_key_path).mode & 0o777
  assert_equal 0o700, File.stat(File.dirname(c.secret_key_path)).mode & 0o777
  assert_equal secret, File.read(c.secret_key_path).strip

  again = scratch_config
  assert_equal secret, again.resolve_secret!

  File.write(again.secret_key_path, "too short\n")
  replaced = scratch_config.resolve_secret!
  assert_equal 64, replaced.length
  refute replaced == secret
end

test "a set secret is returned as it is, and production refuses to invent one" do
  c = scratch_config
  c.secret_key_path = "#{SCRATCH}/never/secret_key"
  c.secret_key_base = "given"
  assert_equal "given", c.resolve_secret!
  c.secret_key_base = ""
  c.env = "production"
  assert_raises("RuntimeError") { c.resolve_secret! }
  refute File.exist?("#{SCRATCH}/never")
end

Cybertrain::Test.run!
