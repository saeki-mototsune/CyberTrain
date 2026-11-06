require "cybertrain/test"
require "cybertrain/cast"
require "cybertrain/time_ext"

# Time.iso8601, Time.rfc2822 and Time.strptime (cybertrain/time_ext.rb):
# class methods added to Time from Ruby source. Plain Ruby, no DB.

test "Time.iso8601 and rfc2822" do
  assert_equal Time.utc(2026, 10, 5, 9, 0, 0, 500000), Time.iso8601("2026-10-05T09:00:00.5Z")
  assert_equal Time.utc(2026, 11, 5, 9), Time.rfc2822("Thu, 05 Nov 2026 09:00:00 +0000")
  assert_includes assert_raises("ArgumentError") { Time.iso8601("yesterday") }, "invalid date"
end

test "Time.strptime directives" do
  assert_equal Time.utc(2026, 10, 5, 9, 7, 3), Time.strptime("05/10/2026 09:07:03", "%d/%m/%Y %H:%M:%S")
  assert_equal Time.utc(2026, 10, 5, 0, 0, 0, 250000), Time.strptime("2026-10-05 000.250", "%Y-%m-%d 000.%L")
  assert_equal Time.utc(2026, 10, 5, 0, 0, 0), Time.strptime("2026-10-05 09:00 +0900", "%Y-%m-%d %H:%M %z")
  assert_equal Time.utc(2026, 11, 5), Time.strptime("Nov 5 2026", "%b %d %Y")
  assert_equal 1759654800, Time.strptime("1759654800", "%s").to_i
  assert_equal Time.utc(2026, 1, 10), Time.strptime("2026 010", "%Y %j")
  assert_includes assert_raises("ArgumentError") { Time.strptime("x", "%q") }, "%q"
end

test "Time.strptime names, zones and malformed input" do
  assert_equal Time.utc(2026, 11, 5, 9, 30), Time.strptime("thursday, NOVEMBER 5 2026 09:30 GMT", "%A, %B %d %Y %H:%M %Z")
  assert_equal Time.utc(2026, 11, 5, 9, 30), Time.strptime("Thu 5 nov 2026 10:30 +01:00", "%a %d %b %Y %H:%M %z")
  assert_equal Time.utc(2026, 11, 5, 9), Time.strptime("2026-11-05 09Z100%", "%Y-%m-%d %H%Z100%%")
  assert_equal Time.utc(1969, 12, 31, 23, 59, 59), Time.strptime("-1", "%s")
  assert_includes assert_raises("ArgumentError") { Time.strptime("2026-13-05", "%Y-%m-%d") }, "invalid date"
  assert_includes assert_raises("ArgumentError") { Time.strptime("2026-1", "%Y-%m-%d") }, "invalid date"
  assert_includes assert_raises("ArgumentError") { Time.strptime("2026-10-05 extra", "%Y-%m-%d") }, "invalid date"
  assert_includes assert_raises("ArgumentError") { Time.strptime("", "%Y") }, "invalid date"
  assert_includes assert_raises("ArgumentError") { Time.strptime("2026", "%Y%") }, "unsupported"
end

Cybertrain::Test.run!
