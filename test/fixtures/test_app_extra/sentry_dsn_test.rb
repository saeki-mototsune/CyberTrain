require "test_helper"

# Copied to test/sentry_dsn_test.rb by script/test-command-e2e and run with
# CYBERTRAIN_SENTRY_DSN and CYBERTRAIN_LOG_FORMAT=json exported:
# `cybertrain test` ignores both (config/app.rb assigns neither), so no test
# sends a report to a real Sentry and captured log lines stay text.
class SentryDsnTest < ActiveSupport::TestCase
  test "an exported DSN and log format are ignored" do
    puts "sentry_dsn: #{Cybertrain.config.sentry_dsn.inspect}"
    puts "log_format: #{Cybertrain.config.log_format.inspect}"
    assert_equal "", Cybertrain.config.sentry_dsn
    assert_equal :text, Cybertrain.config.log_format
    refute Cybertrain::Logger.json_lines
  end
end
