require "cybertrain/test"

# Cybertrain::Clock (spec section 2.2), Time.current, Date.current and the
# test helpers travel_to, travel, freeze_time and travel_back (section 2.1).
# Plain Ruby, no FFI: the snapshot comes from CRuby or the compiled binary
# alike. Time.now itself is overridden only where cybertrain/test/time_now
# is required (test/time_travel.rb).

test "Clock.now is real time until travel_to, then frozen without sub-seconds" do
  # Real: between two readings of CLOCK_REALTIME taken around it (a
  # millisecond's slack for the microsecond truncation), with no bound on
  # how long a loaded machine takes between them; a frozen clock fails.
  before = Process.clock_gettime(Process::CLOCK_REALTIME)
  now = Cybertrain::Clock.now.to_f
  after = Process.clock_gettime(Process::CLOCK_REALTIME)
  assert before - 0.001 <= now, "Clock.now #{now} before the reading taken first, #{before}"
  assert now <= after + 0.001, "Clock.now #{now} after the reading taken last, #{after}"
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
  travel_to(Time.utc(2026, 3, 1, 0, 0, 0)) { assert_equal Date.new(2026, 3, 1), Date.current }
end

test "travel_back inside a block lasts to the end of that block" do
  travel_to Time.utc(2026, 1, 1) do
    travel_to Time.utc(2030, 1, 1) do
      travel_back
      refute Cybertrain::Clock.travelling?
    end
    assert_equal Time.utc(2026, 1, 1), Time.current
    travel_back
    refute Cybertrain::Clock.travelling?
  end
  refute Cybertrain::Clock.travelling?
end

test "freeze_time with a block holds the clock and restores what it found" do
  freeze_time do
    assert Cybertrain::Clock.travelling?
    assert_equal 0, Time.current.usec
  end
  refute Cybertrain::Clock.travelling?
  travel_to Time.utc(2026, 1, 1, 8) do
    freeze_time do
      assert_equal Time.utc(2026, 1, 1, 8), Time.current
      travel 5
      assert_equal Time.utc(2026, 1, 1, 8, 0, 5), Time.current
    end
    assert_equal Time.utc(2026, 1, 1, 8), Time.current
  end
end

test "a raise out of a travel without a block leaves the next test on real time" do
  # Test.run! cannot report a failing case inside a passing program, so the
  # case raises and rescues itself: the travel outlives the raise, and the
  # runner's travel_back after the case is what clears it (next case).
  begin
    travel_to Time.utc(2026, 1, 1)
    raise "mid-travel"
  rescue RuntimeError => e
    assert_equal "mid-travel", e.message
  end
  assert_equal Time.utc(2026, 1, 1), Time.current
end

test "the clock is real after the case that raised mid-travel" do
  refute Cybertrain::Clock.travelling?
end

# Spec section 2.3: the framework's runtime, and the code its emitters
# write into an application, read the time through Cybertrain::Clock
# (Time.current), never Time.now; the five clock seams it replaced are
# gone. cybertrain/cli/ and the rest of cybertrain/generator/ run at build
# time on the developer's clock; test/time_now.rb is the override itself.
# Comment lines are not counted. Run from the repository root.
def clock_scanned?(path)
  return false if path.start_with?("cybertrain/cli/")
  return false if path.start_with?("cybertrain/generator/") && !path.end_with?("_emitter.rb")

  path != "cybertrain/test/time_now.rb"
end

test "no runtime or emitted code reads Time.now, and no removed seam is left" do
  hits = []
  seam_files = []
  seams = ["def self.clock=", "system_clock", "current_time=", "fixed_now", "status_now", "supervisor_clock"]
  Dir.glob("cybertrain/**/*.rb").sort.each do |path|
    text = File.read(path)
    seam_files << path if seams.any? { |w| text.include?(w) }
    next unless clock_scanned?(path)

    number = 0
    text.each_line do |line|
      number += 1
      hits << "#{path}:#{number}" if !line.lstrip.start_with?("#") && line.include?("Time.now")
    end
  end
  assert_equal [], hits
  assert_equal [], seam_files
end

Cybertrain::Test.run!
