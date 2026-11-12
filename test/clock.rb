require "cybertrain/test"

# Cybertrain::Clock (spec section 2.2), Time.current, Date.current and the
# test helpers travel_to, travel, freeze_time and travel_back (section 2.1).
# Plain Ruby, no FFI: the snapshot comes from CRuby or the compiled binary
# alike. Time.now itself is overridden only where cybertrain/test/time_now
# is required (test/time_travel.rb).

test "Clock.now is real time until travel_to, then frozen without sub-seconds" do
  gap = (Cybertrain::Clock.now.to_f - Process.clock_gettime(Process::CLOCK_REALTIME)).abs
  assert gap < 0.01
  Cybertrain::Clock.travel_to(Time.utc(2026, 11, 11, 12, 0, 0.75))
  assert_equal Time.utc(2026, 11, 11, 12, 0, 0), Time.current
  assert_equal 0, Time.current.usec
  assert Cybertrain::Clock.travelling?
  Cybertrain::Clock.travel_back
  refute Cybertrain::Clock.travelling?
end

test "travel and freeze_time with and without blocks" do
  travel_to Time.utc(2026, 1, 1) do
    travel 90 do
      assert_equal Time.utc(2026, 1, 1, 0, 1, 30), Time.current
    end
    assert_equal Time.utc(2026, 1, 1), Time.current
    freeze_time
    assert_equal Time.utc(2026, 1, 1), Time.current
  end
  refute Cybertrain::Clock.travelling?
end

test "nested travel_to restores the outer instant after a raise" do
  travel_to Time.utc(2026, 1, 1) do
    assert_raises("RuntimeError") { travel_to(Time.utc(2030, 1, 1)) { raise "inner" } }
    assert_equal Time.utc(2026, 1, 1), Time.current
  end
end

test "a travel without a block lasts to the end of its test" do
  travel_to Time.utc(2026, 1, 1)
  assert_equal Time.utc(2026, 1, 1), Time.current
end

test "the clock is real again in the next test" do
  refute Cybertrain::Clock.travelling?
end

test "Date.current follows the clock" do
  travel_to(Time.utc(2026, 2, 28, 23, 59, 59)) { assert_equal Date.new(2026, 2, 28), Date.current }
end

Cybertrain::Test.run!
