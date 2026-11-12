require "cybertrain/test"
require "cybertrain/time_ext"

# Time#in_time_zone and Cybertrain::ZonedTime (spec section 4, "Reading wall
# fields"; acceptance 2): the wall fields of a UTC instant in Time.zone, in
# a zone named by a String or given as a TimeZone, the abbreviation and the
# offset across a DST change, the UTC instant and the civil date back, and
# the refusal of a name the system zoneinfo does not have. Plain Ruby, no
# FFI: the snapshot comes from CRuby or the compiled binary alike. Needs the
# system's /usr/share/zoneinfo.

# Sets Cybertrain::Clock.zone for the block and puts the zone found before
# back when it ends, also when an assertion in it fails (spikes/NOTES.md
# rule 103's save-yield-ensure in a module function).
module ZoneSwap
  def self.during(name)
    saved = Cybertrain::Clock.zone
    Cybertrain::Clock.zone = Cybertrain::TimeZone.find(name)
    _value = yield
    nil
  ensure
    Cybertrain::Clock.zone = saved
  end
end

def wall_fields(z)
  [z.year, z.month, z.day, z.hour, z.min, z.sec]
end

test "in_time_zone's fields" do
  t = Time.utc(2026, 11, 11, 20)
  z = t.in_time_zone("Asia/Tokyo")
  assert_equal [2026, 11, 12, 5, 0, 0], wall_fields(z)
  assert_equal 4, z.wday
  assert_equal 316, z.yday
  assert_equal 32_400, z.utc_offset
  assert_equal "JST", z.zone
  assert_equal Time.utc(2026, 11, 11, 20), z.to_time
  assert_equal Date.new(2026, 11, 12), z.to_date
  assert_equal "Cybertrain::ZonedTime", z.class.name
end

test "in_time_zone without an argument reads Time.zone at call time" do
  t = Time.utc(2026, 11, 11, 20, 30, 15)
  z = t.in_time_zone
  assert_equal [2026, 11, 11, 20, 30, 15], wall_fields(z)
  assert_equal "UTC", z.zone
  assert_equal 0, z.utc_offset
  ZoneSwap.during("Asia/Tokyo") do
    assert_equal [2026, 11, 12, 5, 30, 15], wall_fields(t.in_time_zone)
    assert_equal "JST", t.in_time_zone.zone
  end
  assert_equal "UTC", t.in_time_zone.zone
end

test "in_time_zone takes a TimeZone as well as a name" do
  london = Cybertrain::TimeZone.find("Europe/London")
  summer = Time.utc(2026, 7, 1, 23, 30).in_time_zone(london)
  assert_equal [2026, 7, 2, 0, 30, 0], wall_fields(summer)
  assert_equal "BST", summer.zone
  assert_equal 3_600, summer.utc_offset
  winter = Time.utc(2026, 12, 31, 23, 30).in_time_zone(london)
  assert_equal [2026, 12, 31, 23, 30, 0], wall_fields(winter)
  assert_equal "GMT", winter.zone
  assert_equal 365, winter.yday
end

test "the offset and abbreviation follow the zone's DST rules" do
  # 2026-03-08 02:00 EST is the change: 06:59 UTC is 01:59 EST, 07:00 UTC 03:00 EDT.
  before = Time.utc(2026, 3, 8, 6, 59).in_time_zone("America/New_York")
  after = Time.utc(2026, 3, 8, 7, 0).in_time_zone("America/New_York")
  assert_equal [2026, 3, 8, 1, 59, 0], wall_fields(before)
  assert_equal ["EST", -18_000, 0], [before.zone, before.utc_offset, before.wday]
  assert_equal [2026, 3, 8, 3, 0, 0], wall_fields(after)
  assert_equal ["EDT", -14_400, 67], [after.zone, after.utc_offset, after.yday]
  # Behind UTC the civil date is the day before.
  assert_equal Date.new(2026, 12, 31), Time.utc(2027, 1, 1, 3).in_time_zone("America/New_York").to_date
end

test "to_time is the UTC instant, sub-second part included" do
  t = Time.at(Time.utc(2026, 11, 11, 20).to_i, 250_000).utc
  back = t.in_time_zone("Asia/Tokyo").to_time
  assert_equal t, back
  assert_equal 250_000, back.usec
  assert_equal 0, back.utc_offset
end

test "an unknown zone name is an ArgumentError" do
  msg = assert_raises("ArgumentError") { Time.utc(2026, 11, 11).in_time_zone("Mars/Base") }
  assert_equal "unknown time zone \"Mars/Base\"", msg
  msg = assert_raises("ArgumentError") { Time.find_zone!("../etc/passwd") }
  assert_equal "unknown time zone \"../etc/passwd\"", msg
  assert_equal "Asia/Tokyo", Time.find_zone!("Asia/Tokyo").zone_name
  assert_equal "UTC", Time.find_zone!("UTC").zone_name
end

Cybertrain::Test.run!
