require "cybertrain/http/query"
require "cybertrain/http/client_error"
require "cybertrain/test"

# ClientError decides on the class NAME. Class#name is namespaced under CRuby
# ("Cybertrain::Query::TooMany") and bare under Spinel ("TooMany", NOTES rule
# 46), so a test that raises an app-side "Billing::Invalid" would print 500
# on one runtime and 400 on the other. The decision is therefore tested on
# name strings from both runtimes, which is identical on both.

test "a namespaced name must match in full" do
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::Query::TooMany")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::Query::TooDeep")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::Query::LimitExceeded")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::Query::Invalid")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::Query::Malformed")
end

test "an app or library exception that shares a bare name is the app's fault (500)" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("Billing::Invalid")
  assert_equal 500, Cybertrain::ClientError.status_for_name("RateLimiter::TooMany")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Other::Query::Malformed")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Cybertrain::TooMany")
end

test "a name with no namespace (Spinel) matches the bare names" do
  assert_equal 400, Cybertrain::ClientError.status_for_name("TooMany")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Malformed")
  assert_equal 500, Cybertrain::ClientError.status_for_name("ArgumentError")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Rejected")
end

test "an anonymous class (name nil under CRuby) is a 500, not a crash" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("")
end

test "the bare list is the full list without its namespace" do
  bare = []
  Cybertrain::ClientError::CLIENT_FAULTS.each { |n| bare << Cybertrain::ClientError.bare_name(n) }
  assert_equal bare, Cybertrain::ClientError::BARE_CLIENT_FAULTS
  assert_equal "TooMany", Cybertrain::ClientError.bare_name("Cybertrain::Query::TooMany")
  assert_equal "TooMany", Cybertrain::ClientError.bare_name("TooMany")
end

test "status of the framework's own exceptions" do
  assert_equal 400, Cybertrain::ClientError.status(Cybertrain::Query::TooMany.new("x"))
  assert_equal 400, Cybertrain::ClientError.status(Cybertrain::Query::Malformed.new("x"))
  assert_equal 500, Cybertrain::ClientError.status(ArgumentError.new("x"))
end

Cybertrain::Test.run!
