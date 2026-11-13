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

# Code that reads Time.now itself (an application's or a library's, as in a
# Rails application) rather than Time.current; the framework reads the
# clock directly (test/clock.rb's scan).
def stamped_now = Cybertrain::Cast.sql_datetime(Time.now)

test "code that reads Time.now follows the travel" do
  travel_to(Time.utc(2001, 9, 9, 1, 46, 40)) do
    assert_equal "2001-09-09 01:46:40.000000", stamped_now
  end
end

test "Time.now answers local time, as the builtin does" do
  # The builtin's local offset at the same instants, read without the
  # override (Time.at and Time.new are not overridden).
  now = Time.now
  refute now.utc?
  assert_equal Time.at(now.to_i).utc_offset, now.utc_offset
  travel_to(Time.utc(2001, 9, 9)) do
    travelled = Time.now
    refute travelled.utc?
    assert_equal Time.at(999_993_600).utc_offset, travelled.utc_offset
    assert_equal 999_993_600, travelled.to_i
  end
end

Cybertrain::Test.run!
