require "cybertrain/test"
require "cybertrain/durations"
require "cybertrain/time_ext"
require_relative "support/zone_swap"

# Durations on Integer and the calendar methods on Time (spec section 3,
# acceptance 2): Integer seconds, `ago` / `from_now` on the Clock,
# month-end clamping as Rails does, `beginning_of_*` / `end_of_*` and
# `Date.current` in `Time.zone`, Asia/Tokyo and a DST transition in
# America/New_York. Plain Ruby, no FFI: the snapshot comes from CRuby or the
# compiled binary alike. Needs the system's /usr/share/zoneinfo.

test "durations are Integer seconds" do
  assert_equal [300, 86_400, 1_209_600, 1, 3_600], [5.minutes, 1.day, 2.weeks, 1.second, 1.hour]
  assert_equal [90, 60, 7_200, 172_800, 604_800], [90.seconds, 1.minute, 2.hours, 2.days, 1.week]
  assert_equal "300", 5.minutes.inspect
  travel_to(Time.utc(2026, 11, 11, 12)) do
    assert_equal Time.utc(2026, 10, 28, 12), 2.weeks.ago
    assert_equal Time.utc(2026, 11, 14, 12), 3.days.from_now
    assert_equal 5.minutes.ago, 300.ago
    assert_equal Time.utc(2026, 11, 11, 12, 1, 30), Time.current + 90.seconds
  end
end

test "advance and months_ago clamp month ends as Rails does" do
  assert_equal Time.utc(2026, 2, 28), Time.utc(2026, 1, 31).advance(months: 1)
  assert_equal Time.utc(2024, 2, 29), Time.utc(2024, 1, 31).advance(months: 1)
  assert_equal Time.utc(2025, 2, 28), Time.utc(2024, 2, 29).advance(years: 1)
  assert_equal Time.utc(2026, 9, 30), Time.utc(2026, 10, 31).months_ago(1)
  assert_equal Time.utc(2027, 1, 31, 1, 2, 3), Time.utc(2026, 12, 31).advance(months: 1, hours: 1, minutes: 2, seconds: 3)
  assert_equal Time.utc(2026, 11, 10), Time.utc(2026, 11, 11).yesterday
end

test "the other calendar methods" do
  t = Time.utc(2026, 1, 31, 10, 20, 30)
  assert_equal Time.utc(2026, 4, 30, 10, 20, 30), t.months_since(3)
  assert_equal Time.utc(2024, 1, 31, 10, 20, 30), t.years_ago(2)
  assert_equal Time.utc(2027, 1, 31, 10, 20, 30), t.years_since(1)
  assert_equal Time.utc(2026, 2, 1, 10, 20, 30), t.tomorrow
  assert_equal Time.utc(2026, 2, 14, 10, 20, 30), t.advance(weeks: 2)
  assert_equal Time.utc(2025, 12, 31, 10, 20, 30), t.advance(days: -31)
  assert_equal Time.utc(2026, 1, 31, 9, 20, 30), t.advance(hours: -1)
  assert_equal t, t.advance
  assert_equal 250_000, Time.at(t.to_i, 250_000).utc.advance(months: 1).usec
end

test "beginning_of_* in UTC" do
  t = Time.utc(2026, 11, 11, 20, 30) # a Wednesday
  assert_equal Time.utc(2026, 11, 11), t.beginning_of_day
  assert_equal [Time.utc(2026, 11, 11, 23, 59, 59).to_i, 999_999], [t.end_of_day.to_i, t.end_of_day.usec]
  assert_equal Time.utc(2026, 11, 9), t.beginning_of_week
  assert_equal Time.utc(2026, 11, 1), t.beginning_of_month
  assert_equal Time.utc(2026, 1, 1), t.beginning_of_year
end

test "end_of_* in UTC" do
  t = Time.utc(2026, 11, 11, 20, 30)
  assert_equal [Time.utc(2026, 11, 15, 23, 59, 59).to_i, 999_999], [t.end_of_week.to_i, t.end_of_week.usec]
  assert_equal [Time.utc(2026, 11, 30, 23, 59, 59).to_i, 999_999], [t.end_of_month.to_i, t.end_of_month.usec]
  assert_equal [Time.utc(2026, 12, 31, 23, 59, 59).to_i, 999_999], [t.end_of_year.to_i, t.end_of_year.usec]
  assert_equal Time.utc(2024, 2, 29, 23, 59, 59).to_i, Time.utc(2024, 2, 3).end_of_month.to_i
  # A Monday is its own week's start; a Sunday belongs to the week before.
  assert_equal Time.utc(2026, 11, 9), Time.utc(2026, 11, 9, 0, 0, 1).beginning_of_week
  assert_equal Time.utc(2026, 11, 9), Time.utc(2026, 11, 15, 23).beginning_of_week
end

test "Time.zone and Date.current are UTC by default" do
  assert_equal "UTC", Time.zone.zone_name
  assert_equal "UTC", Cybertrain::Clock.zone.zone_name
  travel_to(Time.utc(2026, 11, 11, 23, 59, 59)) { assert_equal Date.new(2026, 11, 11), Date.current }
end

test "boundaries in Asia/Tokyo" do
  ZoneSwap.during("Asia/Tokyo") do
    assert_equal "Asia/Tokyo", Time.zone.zone_name
    assert_equal Time.utc(2026, 11, 11, 15), Time.utc(2026, 11, 11, 20).beginning_of_day
    travel_to(Time.utc(2026, 11, 11, 14, 59, 59)) { assert_equal Date.new(2026, 11, 11), Date.current }
    travel_to(Time.utc(2026, 11, 11, 15)) { assert_equal Date.new(2026, 11, 12), Date.current }
    assert_equal Time.utc(2026, 11, 30, 15), Time.utc(2026, 12, 15).beginning_of_month
    assert_equal Time.utc(2025, 12, 31, 15), Time.utc(2026, 6, 1).beginning_of_year
  end
  assert_equal "UTC", Time.zone.zone_name
end

test "a DST transition in America/New_York" do
  ZoneSwap.during("America/New_York") do
    assert_equal Time.utc(2026, 3, 8, 5), Time.utc(2026, 3, 8, 15).beginning_of_day # EST midnight
    assert_equal Time.utc(2026, 3, 9, 4), Time.utc(2026, 3, 8, 15).advance(days: 1).beginning_of_day # EDT midnight
    assert_equal Time.utc(2026, 3, 8, 7, 30), Time.utc(2026, 3, 7, 7, 30).advance(days: 1) # 02:30 skipped -> 03:30 EDT
    assert_equal Time.utc(2026, 11, 1, 5, 30), Time.utc(2026, 10, 31, 5, 30).advance(days: 1) # 01:30 twice -> the earlier
    # The 23-hour day ends one hour before the next EDT midnight.
    assert_equal Time.utc(2026, 3, 9, 3, 59, 59).to_i, Time.utc(2026, 3, 8, 15).end_of_day.to_i
  end
  assert_equal "UTC", Time.zone.zone_name
end

test "month 13 and day 0 roll over into the next and the previous year" do
  # December's end is the instant before 1 "13" 2026, that is 1 January 2027.
  assert_equal [Time.utc(2026, 12, 31, 23, 59, 59).to_i, 999_999], [Time.utc(2026, 12, 15).end_of_month.to_i, Time.utc(2026, 12, 15).end_of_month.usec]
  # Thursday 1 January: its Monday is day -2 of January, 29 December.
  assert_equal Time.utc(2025, 12, 29), Time.utc(2026, 1, 1, 12).beginning_of_week
  assert_equal Time.utc(2025, 12, 31), Time.utc(2026, 1, 1).yesterday
  assert_equal Time.utc(2026, 2, 28), Time.utc(2026, 3, 1).advance(days: -1)
  assert_equal Time.utc(2027, 1, 1), Time.utc(2026, 12, 31).tomorrow
end

test "the 25-hour day in America/New_York" do
  ZoneSwap.during("America/New_York") do
    t = Time.utc(2026, 11, 1, 15)
    assert_equal Time.utc(2026, 11, 1, 4), t.beginning_of_day # EDT midnight
    assert_equal Time.utc(2026, 11, 2, 4, 59, 59).to_i, t.end_of_day.to_i # before EST midnight
    assert_equal 25 * 3600, t.end_of_day.to_i + 1 - t.beginning_of_day.to_i
  end
end

test "the DST days in Europe/London" do
  ZoneSwap.during("Europe/London") do
    spring = Time.utc(2026, 3, 29, 12)
    assert_equal Time.utc(2026, 3, 29), spring.beginning_of_day # GMT midnight
    assert_equal Time.utc(2026, 3, 29, 22, 59, 59).to_i, spring.end_of_day.to_i # before BST midnight
    assert_equal 23 * 3600, spring.end_of_day.to_i + 1 - spring.beginning_of_day.to_i
    # 01:30 GMT plus a day is 01:30 on the 29th, which the change skips:
    # 02:30 BST, as for New York.
    assert_equal Time.utc(2026, 3, 29, 1, 30), Time.utc(2026, 3, 28, 1, 30).advance(days: 1)
    autumn = Time.utc(2026, 10, 25, 12)
    assert_equal Time.utc(2026, 10, 24, 23), autumn.beginning_of_day # BST midnight
    assert_equal Time.utc(2026, 10, 25, 23, 59, 59).to_i, autumn.end_of_day.to_i # before GMT midnight
  end
end

test "a mixed advance across a DST change: the calendar part first, then elapsed time" do
  ZoneSwap.during("America/New_York") do
    # 12:00 EST plus a day is 12:00 EDT (16:00 UTC); two hours later is 18:00
    # UTC, not the 19:00 of 26 elapsed hours.
    assert_equal Time.utc(2026, 3, 8, 18), Time.utc(2026, 3, 7, 17).advance(days: 1, hours: 2)
    assert_equal Time.utc(2026, 3, 8, 17), Time.utc(2026, 2, 8, 17).advance(months: 1, hours: 1)
    # 12:00 EDT plus a day is 12:00 EST (17:00 UTC).
    assert_equal Time.utc(2026, 11, 1, 17, 30), Time.utc(2026, 10, 31, 16).advance(days: 1, minutes: 30)
  end
end

test "the zone comes back after a failing assertion" do
  assert_raises("AssertionFailed") do
    ZoneSwap.during("Asia/Tokyo") { assert_equal "UTC", Time.zone.zone_name }
  end
  assert_equal "UTC", Time.zone.zone_name
end

Cybertrain::Test.run!
