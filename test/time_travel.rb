require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/time_now"

# Spec section 2.4 with spike item 1's verdict (PASS): a test program that
# requires cybertrain/test/time_now has Time.now answer Cybertrain::Clock.now,
# so during a travel Time.now, and every framework or library call that reads
# it, follows the clock. A production binary never requires that file. The
# whole framework is required so the override is compiled beside every
# framework call site of Time.now (SQLite links through FFI: compiled only).

test "Time.now follows a travel when the override is loaded" do
  travel_to(Time.utc(2001, 9, 9)) { assert_equal 999_993_600, Time.now.to_i }
end

test "Time.now is real time outside a travel" do
  before = Process.clock_gettime(Process::CLOCK_REALTIME)
  now = Time.now.to_f
  after = Process.clock_gettime(Process::CLOCK_REALTIME)
  assert before - 0.001 <= now && now <= after + 0.001, "Time.now #{now} outside #{before}..#{after}"
end

test "a framework time read through Time.now follows the travel" do
  travel_to(Time.utc(2001, 9, 9, 1, 46, 40)) do
    assert_equal "2001-09-09 01:46:40.000000", Cybertrain::Model.now_string
  end
end

Cybertrain::Test.run!
