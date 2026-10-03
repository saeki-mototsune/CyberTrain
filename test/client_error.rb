require "cybertrain/http/query"
require "cybertrain/http/client_error"
require "cybertrain/test"

# ClientError decides on the class NAME. Class#name is namespaced under CRuby
# ("Cybertrain::QueryTooMany") and bare under Spinel ("QueryTooMany", NOTES
# rule 46), so a test that raises an app-side "Billing::Invalid" would print
# 500 on one runtime and 400 on the other. The decision is therefore tested on
# name strings from both runtimes, which is identical on both.

test "a namespaced name must match in full" do
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryTooMany", true)
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryTooDeep", true)
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryLimitExceeded", true)
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryInvalid", true)
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryMalformed", true)
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::Params::ParameterMissing", true)
end

test "an app or library exception that shares a bare name is the app's fault (500)" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("Billing::Invalid", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("RateLimiter::TooMany", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Other::QueryMalformed", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Other::ParameterMissing", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Cybertrain::TooMany", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Cybertrain::Query::TooMany", true)
end

test "a name with no namespace (Spinel) matches the framework's unique bare names" do
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryTooMany", false)
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryTooDeep", false)
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryLimitExceeded", false)
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryInvalid", false)
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryMalformed", false)
  assert_equal 400, Cybertrain::ClientError.status_for_name("ParameterMissing", false)
  assert_equal 500, Cybertrain::ClientError.status_for_name("ArgumentError", false)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Rejected", false)
end

test "a bare name an app also uses (Billing::Invalid under Spinel) is not a client fault" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("Invalid", false)
  assert_equal 500, Cybertrain::ClientError.status_for_name("TooMany", false)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Malformed", false)
  assert_equal 500, Cybertrain::ClientError.status_for_name("LimitExceeded", false)
end

test "an anonymous class (name nil under CRuby) is a 500, not a crash" do
  assert_equal 500, Cybertrain::ClientError.status_for_name("", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("", false)
end

test "a bare framework name is the app's own top-level class where names are namespaced" do
  # An app's `class QueryTooMany < StandardError` under CRuby has no "::",
  # and every framework fault there has one: the bare name is a 500.
  assert_equal 500, Cybertrain::ClientError.status_for_name("QueryTooMany", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("ParameterMissing", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Invalid", true)
  assert_equal 400, Cybertrain::ClientError.status_for_name("QueryTooMany", false)
  assert_equal 400, Cybertrain::ClientError.status_for_name("Cybertrain::QueryTooMany", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Billing::Invalid", true)
  assert_equal 500, Cybertrain::ClientError.status_for_name("Invalid", false)
end

test "the bare-name list is derived from CLIENT_FAULTS, entry for entry" do
  faults = Cybertrain::ClientError::CLIENT_FAULTS
  bare = Cybertrain::ClientError::CLIENT_FAULT_BARE_NAMES
  assert_equal faults.length, bare.length
  i = 0
  while i < faults.length
    assert_equal Cybertrain::ClientError.bare_name(faults[i]), bare[i]
    i += 1
  end
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
