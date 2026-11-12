# The end-to-end application of `cybertrain test` (script/test-command-e2e).
Cybertrain.configure do |c|
  c.time_zone = "Asia/Tokyo"
  # The request log would print between the test lines (with timings).
  c.log_level = :none if c.test?
  # An application that names its database from its own variable: with
  # TEST_APP_DATABASE pointing at the development file, `cybertrain test`
  # must refuse (exit 2) and leave it alone (plan decision 19).
  c.database_path = ENV["TEST_APP_DATABASE"].to_s unless ENV["TEST_APP_DATABASE"].to_s.empty?
end
