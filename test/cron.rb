require "cybertrain/test"
require "cybertrain/time_zone"
require "cybertrain/cron"

# Cybertrain::Cron: five-field expressions (parse, and what it refuses) and
# next_after, the first matching minute strictly after an instant in a
# TimeZone, including Europe/London's two transitions of 2026 (the spring
# gap is skipped; across the autumn fold a fixed hour runs once, a wildcard
# hour runs at both occurrences). Plain Ruby, no SQLite: `ruby -I. test/cron.rb`
# runs it under CRuby too. The zone files come from the system zoneinfo.

CRON = Cybertrain::Cron
TZ = Cybertrain::TimeZone

# The message of the ArgumentError that parse raises for text, or "" when
# it parses (begin/rescue in an ordinary method, NOTES rule 32).
def parse_error(text)
  CRON.parse(text)
  ""
rescue ArgumentError => e
  e.message
end

def next_error(text, epoch)
  CRON.next_after(CRON.parse(text), epoch, TZ.find("UTC"))
  ""
rescue ArgumentError => e
  e.message
end

def utc(y, m, d, h, mi)
  TZ.civil_to_epoch(y, m, d, h, mi, 0)
end

test "parse accepts the five-field forms" do
  e = Cybertrain::Cron.parse("12 * * * *");        assert_equal [12], e.minutes; assert_equal 24, e.hours.size
  e = Cybertrain::Cron.parse("*/15 9-17 * * 1-5"); assert_equal [0, 15, 30, 45], e.minutes; assert_equal [1, 2, 3, 4, 5], e.wdays
  e = Cybertrain::Cron.parse("0 9 1,15 jan-mar sun"); assert_equal [1, 15], e.days; assert_equal [1, 2, 3], e.months; assert_equal [0], e.wdays
  assert_equal [0], Cybertrain::Cron.parse("0 0 * * 7").wdays   # 7 is Sunday
end

test "parse: steps, lists, names in any case, and the original text" do
  e = CRON.parse("  0-30/10,45 */6 1-31/10 */4 MON-fri/2  ")
  assert_equal [0, 10, 20, 30, 45], e.minutes
  assert_equal [0, 6, 12, 18], e.hours
  assert_equal [1, 11, 21, 31], e.days
  assert_equal [1, 5, 9], e.months
  assert_equal [1, 3, 5], e.wdays
  assert_equal "  0-30/10,45 */6 1-31/10 */4 MON-fri/2  ", e.expression_text
  assert_equal [0, 5, 6], CRON.parse("0 0 * * 5-7").wdays
  assert_equal [0, 1, 2, 3, 4, 5, 6], CRON.parse("0 0 * * 0-7").wdays
  assert_equal [0, 6], CRON.parse("0 0 * * sat,sun").wdays
  assert_equal [12], CRON.parse("0 0 1 Dec *").months
  assert_equal [3, 5, 7, 9, 11], CRON.parse("0 0 1 mar/2 *").months       # a/n is a through the field's end
  assert_equal [59], CRON.parse("59\t23 31 12 6").minutes                   # tabs separate too
  assert_equal [5, 7, 9], CRON.parse("5,9,7,5 * * * *").minutes             # sorted, no duplicates
  assert_equal 31, CRON.parse("0 0 * * *").days.size
  assert_equal 12, CRON.parse("0 0 * * *").months.size
  assert_equal 7, CRON.parse("0 0 * * *").wdays.size
end

test "parse refuses what it cannot run" do
  ["* * * *", "60 * * * *", "*/0 * * * *", "0 0 * foo *", "0 0 31 2 *", "@hourly"].each do |bad|
    assert_raises("ArgumentError") { Cybertrain::Cron.parse(bad) }
  end
end

test "parse says what is wrong, after the expression" do
  assert_equal "cron \"* * * *\": expected 5 fields (minute hour day-of-month month day-of-week), got 4", parse_error("* * * *")
  assert_equal "cron \"30 2 30 2\": expected 5 fields (minute hour day-of-month month day-of-week), got 4", parse_error("30 2 30 2")
  assert_equal "cron \"\": expected 5 fields (minute hour day-of-month month day-of-week), got 0", parse_error("")
  assert_equal "cron \"@hourly\": the @ shortcuts are not accepted; write the five fields", parse_error("@hourly")
  assert_equal "cron \"60 * * * *\": minute 60 is out of range 0-59", parse_error("60 * * * *")
  assert_equal "cron \"0 24 * * *\": hour 24 is out of range 0-23", parse_error("0 24 * * *")
  assert_equal "cron \"0 0 0 * *\": day of month 0 is out of range 1-31", parse_error("0 0 0 * *")
  assert_equal "cron \"0 0 * 13 *\": month 13 is out of range 1-12", parse_error("0 0 * 13 *")
  assert_equal "cron \"0 0 * * 8\": day of week 8 is out of range 0-7", parse_error("0 0 * * 8")
  assert_equal "cron \"*/0 * * * *\": minute step 0 must be at least 1", parse_error("*/0 * * * *")
  assert_equal "cron \"0 0 * foo *\": month \"foo\" is not a number or a month name", parse_error("0 0 * foo *")
  assert_equal "cron \"0 0 * * monday\": day of week \"monday\" is not a number or a day name", parse_error("0 0 * * monday")
  assert_equal "cron \"jan * * * *\": minute \"jan\" is not a number", parse_error("jan * * * *")
  assert_equal "cron \"0 0 * * fri-mon\": day of week range fri-mon runs backwards", parse_error("0 0 * * fri-mon")
  assert_equal "cron \"1,,2 * * * *\": minute has an empty entry", parse_error("1,,2 * * * *")
  assert_equal "cron \"1, * * * *\": minute has an empty entry", parse_error("1, * * * *")
  assert_equal "cron \"5/ * * * *\": minute step \"\" is not a number", parse_error("5/ * * * *")
  assert_equal "cron \"*/2/3 * * * *\": minute \"*/2/3\" has more than one step", parse_error("*/2/3 * * * *")
  assert_equal "cron \"1-2-3 * * * *\": minute \"2-3\" is not a number", parse_error("1-2-3 * * * *")
  assert_equal "cron \"-1 * * * *\": minute \"\" is not a number", parse_error("-1 * * * *")
  assert_equal "cron \"99999999999999999999 * * * *\": minute 99999999999999999999 is out of range 0-59", parse_error("99999999999999999999 * * * *")
  assert_equal "cron \"0 0 31 2 *\": day of month 31 never falls in the months allowed", parse_error("0 0 31 2 *")
  assert_equal "cron \"0 0 30,31 2 *\": day of month 30,31 never falls in the months allowed", parse_error("0 0 30,31 2 *")
  assert_equal "cron \"0 0 31 4,6,9,11 *\": day of month 31 never falls in the months allowed", parse_error("0 0 31 4,6,9,11 *")
end

test "parse accepts what can match, if rarely" do
  assert_equal "", parse_error("0 0 29 2 *")          # leap years
  assert_equal "", parse_error("0 0 31 2 1")          # day of month OR day of week: every Monday in February
  assert_equal "", parse_error("0 0 31 1,2 *")
  assert_equal "", parse_error("0 0 30,31 2,4 *")   # the 30th of April
end

test "next_after in UTC" do
  e = Cybertrain::Cron.parse("12 * * * *"); utc = Cybertrain::TimeZone.find("UTC")
  assert_equal Time.utc(2026, 11, 9, 10, 12).to_i, Cybertrain::Cron.next_after(e, Time.utc(2026, 11, 9, 10, 0).to_i, utc)
  assert_equal Time.utc(2026, 11, 9, 11, 12).to_i, Cybertrain::Cron.next_after(e, Time.utc(2026, 11, 9, 10, 12).to_i, utc) # strictly after
end

test "next_after: seconds, the year end, and day of month OR day of week" do
  z = TZ.find("UTC")
  every = CRON.parse("* * * * *")
  assert_equal utc(2026, 11, 9, 10, 1), CRON.next_after(every, utc(2026, 11, 9, 10, 0) + 30, z)
  assert_equal utc(2026, 11, 9, 10, 1), CRON.next_after(every, utc(2026, 11, 9, 10, 0), z)
  assert_equal utc(2027, 1, 1, 9, 0), CRON.next_after(CRON.parse("0 9 1 1 *"), utc(2026, 1, 1, 9, 0), z)
  assert_equal utc(2027, 1, 1, 0, 0), CRON.next_after(CRON.parse("0 0 * * *"), utc(2026, 12, 31, 0, 0), z)
  # the 13th or any Friday: from Monday 2026-11-09, Friday 13 November comes first, then Friday the 20th
  both = CRON.parse("0 0 13 * fri")
  first = CRON.next_after(both, utc(2026, 11, 9, 0, 0), z)
  assert_equal utc(2026, 11, 13, 0, 0), first
  assert_equal utc(2026, 11, 20, 0, 0), CRON.next_after(both, first, z)
  # a day-of-month OR: the 1st (a Tuesday in December 2026) or a Monday
  either = CRON.parse("0 0 1 * mon")
  assert_equal utc(2026, 11, 30, 0, 0), CRON.next_after(either, utc(2026, 11, 24, 0, 0), z)
  assert_equal utc(2026, 12, 1, 0, 0), CRON.next_after(either, utc(2026, 11, 30, 0, 0), z)
  # a */n day of month counts as unrestricted: AND with the day of week (Vixie cron)
  assert_equal utc(2026, 11, 15, 0, 0), CRON.next_after(CRON.parse("0 0 */2 * sun"), utc(2026, 11, 9, 0, 0), z)
  assert_equal utc(2028, 2, 29, 12, 0), CRON.next_after(CRON.parse("0 12 29 2 *"), utc(2026, 1, 1, 0, 0), z)
end

test "next_after searches five years and no further" do
  assert_equal "cron \"0 0 29 2 *\": no run in the 5 years after 2096-03-01 00:00 UTC", next_error("0 0 29 2 *", utc(2096, 3, 1, 0, 0))
  assert_equal "", next_error("0 0 29 2 *", utc(2095, 3, 1, 0, 0))
end

test "next_after over the Europe/London transitions" do
  e = Cybertrain::Cron.parse("30 1 * * *"); london = Cybertrain::TimeZone.find("Europe/London")
  # 2026-03-29 01:30 does not exist (clocks go 01:00 -> 02:00): the next run is 2026-03-30 01:30 BST
  assert_equal london.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(2026, 3, 30, 1, 30, 0)), Cybertrain::Cron.next_after(e, Time.utc(2026, 3, 28, 2, 0).to_i, london)
  # 2026-10-25 01:30 occurs twice: run once (the first), and the next run is the 26th
  first = Cybertrain::Cron.next_after(e, Time.utc(2026, 10, 24, 2, 0).to_i, london)
  assert_equal Time.utc(2026, 10, 25, 0, 30).to_i, first   # the first occurrence (01:30 BST), not 01:30 GMT an hour later
  assert_equal Time.utc(2026, 10, 26, 1, 30).to_i, Cybertrain::Cron.next_after(e, first, london)
end

test "a fixed hour does not run again in the repeated hour, wherever the search starts" do
  london = TZ.find("Europe/London")
  e = CRON.parse("30 1 * * *")
  # 00:45 UTC is 01:45 BST: 01:30 GMT (01:30 UTC) is a wall time already passed
  assert_equal utc(2026, 10, 26, 1, 30), CRON.next_after(e, utc(2026, 10, 25, 0, 45), london)
  # every minute of hour 1 runs once: 01:00-01:59 BST, then nothing until the 26th
  hour = CRON.parse("* 1 * * *")
  assert_equal utc(2026, 10, 26, 1, 0), CRON.next_after(hour, utc(2026, 10, 25, 0, 59), london)
end

test "an hourly expression runs at both occurrences of the repeated hour" do
  e = Cybertrain::Cron.parse("30 * * * *"); london = Cybertrain::TimeZone.find("Europe/London")
  a = Cybertrain::Cron.next_after(e, Time.utc(2026, 10, 25, 0, 0).to_i, london)   # 01:30 BST = 00:30 UTC
  b = Cybertrain::Cron.next_after(e, a, london)                                   # 01:30 GMT = 01:30 UTC
  assert_equal Time.utc(2026, 10, 25, 0, 30).to_i, a
  assert_equal Time.utc(2026, 10, 25, 1, 30).to_i, b
end

test "an hourly expression over the spring gap skips the hour that does not exist" do
  london = TZ.find("Europe/London")
  e = CRON.parse("30 * * * *")
  runs = []
  t = utc(2026, 3, 29, 0, 0)
  3.times do
    t = CRON.next_after(e, t, london)
    runs << t
  end
  # 00:30 GMT, then 02:30 BST (01:30 UTC), 03:30 BST
  assert_equal [utc(2026, 3, 29, 0, 30), utc(2026, 3, 29, 1, 30), utc(2026, 3, 29, 2, 30)], runs
end

test "a day jump does not cross a transition blindly" do
  london = TZ.find("Europe/London")
  # Midnight and 00:30 local on the days around both transitions
  e = CRON.parse("30 0 * * sun,mon")
  assert_equal utc(2026, 3, 29, 0, 30), CRON.next_after(e, utc(2026, 3, 25, 12, 0), london)   # 00:30 GMT on the 29th
  assert_equal utc(2026, 3, 29, 23, 30), CRON.next_after(e, utc(2026, 3, 29, 0, 30), london)  # 00:30 BST on the 30th
  assert_equal utc(2026, 10, 24, 23, 30), CRON.next_after(e, utc(2026, 10, 21, 12, 0), london) # 00:30 BST on the 25th
  assert_equal utc(2026, 10, 26, 0, 30), CRON.next_after(e, utc(2026, 10, 24, 23, 30), london) # 00:30 GMT on the 26th
end

test "Asia/Tokyo weekday mornings" do
  e = Cybertrain::Cron.parse("0 9 * * 1-5"); tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
  assert_equal Time.utc(2026, 11, 9, 0, 0).to_i, Cybertrain::Cron.next_after(e, Time.utc(2026, 11, 6, 0, 0).to_i, tokyo) # Fri -> Mon 09:00 JST
end

test "a yearly expression walks ten years quickly" do
  e = CRON.parse("0 9 1 1 *")
  tokyo = TZ.find("Asia/Tokyo")
  t = utc(2026, 1, 1, 0, 0)
  10.times { t = CRON.next_after(e, t, tokyo) }
  assert_equal utc(2036, 1, 1, 0, 0), t   # 09:00 JST is 00:00 UTC
end

Cybertrain::Test.run!
