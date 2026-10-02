require "cybertrain/http/query"
require "cybertrain/http/client_error"
require "cybertrain/test"

# ClientError decides on the class NAME. Class#name is namespaced under CRuby
# ("Cybertrain::QueryTooMany") and bare under Spinel ("QueryTooMany", NOTES
# rule 46), so a test that raises an app-side "Billing::Invalid" would print
# 500 on one runtime and 400 on the other. The decision is therefore tested on
# name strings from both runtimes, which is identical on both.

test "a namespaced name must match in full" do
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryTooMany")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryTooDeep")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryLimitExceeded")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryInvalid")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryMalformed")
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::Params::ParameterMissing")
end

test "an app or library exception that shares a bare name is the app's fault (500)" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("Billing::Invalid")
  assert_equal 500, Cybertrain::ClientError.status_for_name("RateLimiter::TooMany")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Other::QueryMalformed")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Other::ParameterMissing")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Cybertrain::TooMany")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Cybertrain::Query::TooMany")
end

test "a name with no namespace (Spinel) matches the framework's unique bare names" do
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryTooMany")
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryTooDeep")
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryLimitExceeded")
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryInvalid")
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryMalformed")
  assert_equal 400, Cybertrain::ClientError.status_for_name("ParameterMissing")
  assert_equal 500, Cybertrain::ClientError.status_for_name("ArgumentError")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Rejected")
end

test "a bare name an app also uses (Billing::Invalid under Spinel) is not a client fault" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("Invalid")
  assert_equal 500, Cybertrain::ClientError.status_for_name("TooMany")
  assert_equal 500, Cybertrain::ClientError.status_for_name("Malformed")
  assert_equal 500, Cybertrain::ClientError.status_for_name("LimitExceeded")
end

test "an anonymous class (name nil under CRuby) is a 500, not a crash" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("")
end

test "bare_name is the part after the last namespace separator" do
  assert_equal "QueryTooMany", Cybertrain::ClientError.bare_name("Cybertrain::QueryTooMany")
  assert_equal "ParameterMissing", Cybertrain::ClientError.bare_name("Cybertrain::Params::ParameterMissing")
  assert_equal "QueryTooMany", Cybertrain::ClientError.bare_name("QueryTooMany")
end

test "every bare client-fault name is unique within the list" do
  # status_for_name matches bare names under Spinel: two entries sharing one
  # would make a third class's name ambiguous there.
  seen = []
  Cybertrain::ClientError::CLIENT_FAULTS.each do |n|
    bare = Cybertrain::ClientError.bare_name(n)
    refute seen.include?(bare), "#{bare} listed twice"
    seen << bare
  end
  assert_equal Cybertrain::ClientError::CLIENT_FAULTS.length, seen.length
end

test "status of the framework's own exceptions" do
  assert_equal 400, Cybertrain::ClientError.status(Cybertrain::QueryTooMany.new("x"))
  assert_equal 400, Cybertrain::ClientError.status(Cybertrain::QueryMalformed.new("x"))
  assert_equal 400, Cybertrain::ClientError.status(Cybertrain::Params::ParameterMissing.new("x"))
  assert_equal 500, Cybertrain::ClientError.status(ArgumentError.new("x"))
end

Cybertrain::Test.run!
