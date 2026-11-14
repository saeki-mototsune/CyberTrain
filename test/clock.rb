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
# (Time.current), never Time.now, Time.new without arguments, Date.today,
# DateTime.now or the realtime clock itself; the five clock seams it
# replaced are gone, from the framework, its tests and the blog.
# cybertrain/cli/ and the rest of cybertrain/generator/ run at build time
# on the developer's clock, except cli/authentication.rb, whose text is
# application code; its one exception is 0.4's ApplicationController block,
# which the upgrade must match as 0.4 wrote it. clock.rb and
# test/time_now.rb are the clock itself. logger.rb reads the realtime
# clock in one place, Logger.timestamp, when the Clock has pushed no
# travelled instant (plan D2: the HTTP layer cannot name the Clock); the
# test counts that one read. Comment lines are not counted.
# Run from the repository root: from anywhere else the globs find nothing
# and the test fails instead of passing on no files.
LEGACY_START = "LEGACY_APPLICATION_CONTROLLER_BLOCKS = ["
LEGACY_END = "      ]"
IDENTIFIER_BYTES = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

def clock_scanned?(path)
  return true if path == "cybertrain/cli/authentication.rb"
  return false if path.start_with?("cybertrain/cli/")
  return false if path.start_with?("cybertrain/generator/") && !path.end_with?("_emitter.rb")

  path != "cybertrain/test/time_now.rb" && path != "cybertrain/clock.rb" && path != "cybertrain/logger.rb"
end

# Whether `line` reads the time some other way than through the Clock.
def reads_time_directly?(line)
  return true if line.include?("Time.now") || line.include?("Time::now")
  return true if line.include?("Date.today") || line.include?("DateTime.now")
  return true if line.include?("CLOCK_REALTIME")

  at = line.index("Time.new")
  while !at.nil?
    after = line[at + 8, 1].to_s
    # Time.new( takes a date; Time.new alone is the current time.
    return true if after.empty?
    return true unless after == "(" || IDENTIFIER_BYTES.include?(after)

    at = line.index("Time.new", at + 8)
  end
  false
end

# The clock-reading lines of one file, as "path:line", skipping comments
# and, in cli/authentication.rb, 0.4's legacy block.
def clock_hits(path)
  out = []
  number = 0
  legacy = false
  File.read(path).each_line do |line|
    number += 1
    legacy = true if line.include?(LEGACY_START)
    if legacy
      legacy = false if line.rstrip == LEGACY_END
      next
    end
    out << "#{path}:#{number}" if !line.lstrip.start_with?("#") && reads_time_directly?(line)
  end
  out
end

# The files a removed seam may not appear in: the framework, the tests and
# the examples, but not the frozen 0.4 application and its upgrade diff
# (preflight ruling R5), not this file (which names the seams), and not
# build output.
def seam_scanned?(path)
  return false if path.start_with?("test/fixtures/auth_04_app")
  return false if path == "test/clock.rb"

  !path.include?("/build/") && !path.include?("/tmp/")
end

test "the log line's time follows each write of the clock (plan D2)" do
  Cybertrain::Clock.travel_to(Time.utc(2026, 11, 11, 12, 0, 5))
  assert_equal "2026-11-11T12:00:05.000Z", Cybertrain::Logger.timestamp
  Cybertrain::Clock.travel_during(Time.utc(2030, 1, 1)) do
    assert_equal "2030-01-01T00:00:00.000Z", Cybertrain::Logger.timestamp
  end
  assert_equal "2026-11-11T12:00:05.000Z", Cybertrain::Logger.timestamp
  Cybertrain::Clock.travel_back
  Cybertrain::Clock.travel_during(Time.utc(2030, 1, 1)) { nil }
  refute Cybertrain::Logger.timestamp.start_with?("2026-11-11T12:00:05"), Cybertrain::Logger.timestamp
  refute Cybertrain::Logger.timestamp.start_with?("2030-01-01T00:00:00"), Cybertrain::Logger.timestamp
end

test "no runtime or emitted code reads Time.now, and no removed seam is left" do
  framework = Dir.glob("cybertrain/**/*.rb").sort
  assert framework.size > 100, "run from the repository root: found #{framework.size} framework files"
  hits = []
  framework.each { |path| hits.concat(clock_hits(path)) if clock_scanned?(path) }
  assert_equal [], hits
  # logger.rb's one read, pinned by its text and its place: Logger.timestamp
  # reads the real time only when the Clock pushed no instant (-1).
  logger_hits = clock_hits("cybertrain/logger.rb")
  assert_equal 1, logger_hits.size
  logger_lines = File.read("cybertrain/logger.rb").lines.map(&:strip)
  at = logger_hits[0].to_s.split(":").last.to_i - 1
  assert_equal "us = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond) if us == -1", logger_lines[at]
  assert_equal ["def self.timestamp", "us = @clock_micros"], logger_lines[at - 2, 2]
  # The legacy block is skipped, not absent: 0.4's text still reads Time.now.
  assert File.read("cybertrain/cli/authentication.rb").include?("created_at.to_i + lifetime <= Time.now.to_i")

  seams = ["def self.clock=", "Cache.clock", "system_clock", "current_time=", "current_time =", "fixed_now",
           "status_now", "supervisor_clock"]
  files = framework + Dir.glob("test/**/*.rb").sort + Dir.glob("examples/**/*.rb").sort
  seam_files = []
  files.each do |path|
    next unless seam_scanned?(path)

    text = File.read(path)
    seam_files << path if seams.any? { |w| text.include?(w) }
  end
  assert_equal [], seam_files
end

test "the scan's patterns catch each way of reading the time" do
  assert reads_time_directly?("x = Time.now.to_i")
  assert reads_time_directly?("x = Time.new\n")
  assert reads_time_directly?("x = Time.new.utc")
  assert reads_time_directly?("x = Time.new")
  assert reads_time_directly?("d = Date.today")
  assert reads_time_directly?("d = DateTime.now")
  assert reads_time_directly?("us = Process.clock_gettime(Process::CLOCK_REALTIME)")
  refute reads_time_directly?("t = Time.new(2026, 1, 1)")
  refute reads_time_directly?("t = Time.current")
  refute reads_time_directly?("t = Process.clock_gettime(Process::CLOCK_MONOTONIC)")
end

Cybertrain::Test.run!
