# Phase 5a spike, item 2 (spec section 16; pre-flight rulings B1 and R12):
# methods on Integer and Time, ZonedTime's readers beside Time's, and each
# new name compiled beside the framework method it shares a name with, in
# one program that requires the whole framework. A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from the repository root; a shared 4-vCPU
# cloud machine):
#   spinel --strict-require -I . -I spikes/phase5 spikes/phase5/durations.rb -o $TMPDIR/durations && $TMPDIR/durations
#   spinel --strict-require -I . -I spikes/phase5 spikes/phase5/durations.rb -c -o $TMPDIR/d.c
#   grep -c 'sp_raise_nomethod(sp_nomethod_msg("hour"' $TMPDIR/d.c    (also min, day, wday, zone, advance, minutes, seconds)
# Built in 234 s (C only: 143 s). This program was compiled with the names
# as they stood at ac0beb1 (Net::Timer.seconds, Stream::Poller.advance), so
# it shows the clashes the pre-flight scan feared compile and answer; Task 1
# renamed those two anyway (pre-flight B1) and the calls below use the new
# names. Output (the first build):
#   -- Integer
#   5.minutes 300 (== 300 true); 1.day 86400; 1.hour 3600; 2.weeks 1209600; 90.seconds 90; 1.minute 60; 1.week 604800
#   frozen at 2026-11-12 12:00 UTC: 2.weeks.ago 2026-10-29 12:00:00; 3.days.from_now 2026-11-15 12:00:00
#   Time.current 2026-11-12 12:00:00 (Time); Date.current 2026-11-12 (Date)
#   -- Time
#   beginning_of_day 2026-01-31 00:00:00
#   advance(months: 1) 2026-02-28 10:20:30 (Jan 31 -> Feb 28)
#   advance(days: 1, hours: 2) 2026-02-01 12:20:30
#   months_ago(2) 2025-11-30 10:20:30
#   Time#hour/min/day/wday/zone on a typed Time: 10 20 31 6 UTC
#   -- ZonedTime
#   in Tokyo: hour 19 min 20 sec 30 day 31 month 1 year 2026 wday 6 yday 31 zone JST utc_offset 32400
#   to_time true to_date 2026-01-31
#   in_time_zone with the default zone: UTC hour 10
#   Time.zone UTC; Clock.zone UTC
#   -- boxed receivers (rule 62)
#   boxed Time: hour 10 min 20 day 31 wday 6 zone UTC
#   boxed ZonedTime: hour 19 min 20 day 31 wday 6 zone JST
#   boxed Integer: minutes 300 hour 18000 day 432000 seconds 5
#   boxed Time advance: 1
#   -- the existing namesakes
#   Cron::Expression minutes [0, 15, 30, 45] hours 9 days [1, 15]
#   Net::Timer.seconds(5.0) 5s; (0.25) 0.25s
#   Net::Timer.now Float? true; Test::Receiver.now Float? true
#   Cache.now Integer? true
#   Flash#now Cybertrain::FlashNow
#   Stream::Poller.advance answered nil, poller moved
#   Template::Parser#advance ran: Array
#   Schema.current nil? true
#   Schema.current after define: Cybertrain::Schema::Definition
#   Time.now.zone (builtin) UTC
# The C: on a boxed receiver, `hour` / `day` / `wday` / `zone` compile to a
# switch over Date, DateTime, ZonedTime and Integer whose default arm checks
# for the builtin Time and calls sp_time_hour (and so on) before raising
# NoMethodError, so rule 62's hazard does not reach Time: one
# sp_raise_nomethod each for hour, day, minutes, seconds; two for wday,
# zone, advance; none for min. `minutes` on a boxed receiver dispatches to
# Cron::Expression's ivar (Array) or Integer#minutes and answers a boxed
# value. Verdict: PASS, no fallback (Integer methods; ZonedTime#hour and its
# siblings keep Rails' names).
require "cybertrain"
require "cybertrain/test/receiver"
require "standins/clock"

T0 = Time.utc(2026, 1, 31, 10, 20, 30)

# Values of mixed types in one Hash are boxed (sp_RbVal): calls on them are
# rule 62's dispatch over every class that defines the name.
def boxed(key)
  { "time" => T0, "int" => 5, "zoned" => T0.in_time_zone(Cybertrain::TimeZone.find("Asia/Tokyo")), "nil" => nil }[key]
end

puts "-- Integer"
puts "5.minutes #{5.minutes} (== 300 #{5.minutes == 300}); 1.day #{1.day}; 1.hour #{1.hour}; 2.weeks #{2.weeks}; 90.seconds #{90.seconds}; 1.minute #{1.minute}; 1.week #{1.week}"
Cybertrain::Clock.freeze_at(Time.utc(2026, 11, 12, 12, 0, 0))
puts "frozen at 2026-11-12 12:00 UTC: 2.weeks.ago #{2.weeks.ago.utc.strftime("%F %T")}; 3.days.from_now #{3.days.from_now.utc.strftime("%F %T")}"
puts "Time.current #{Time.current.utc.strftime("%F %T")} (#{Time.current.class}); Date.current #{Date.current} (#{Date.current.class})"
Cybertrain::Clock.travel_back

puts "-- Time"
puts "beginning_of_day #{T0.beginning_of_day.strftime("%F %T")}"
puts "advance(months: 1) #{T0.advance(months: 1).strftime("%F %T")} (Jan 31 -> Feb 28)"
puts "advance(days: 1, hours: 2) #{T0.advance(days: 1, hours: 2).strftime("%F %T")}"
puts "months_ago(2) #{T0.months_ago(2).strftime("%F %T")}"
puts "Time#hour/min/day/wday/zone on a typed Time: #{T0.hour} #{T0.min} #{T0.day} #{T0.wday} #{T0.zone}"

puts "-- ZonedTime"
tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
z = T0.in_time_zone(tokyo)
puts "in Tokyo: hour #{z.hour} min #{z.min} sec #{z.sec} day #{z.day} month #{z.month} year #{z.year} wday #{z.wday} yday #{z.yday} zone #{z.zone} utc_offset #{z.utc_offset}"
puts "to_time #{z.to_time.to_i == T0.to_i} to_date #{z.to_date}"
puts "in_time_zone with the default zone: #{T0.in_time_zone.zone} hour #{T0.in_time_zone.hour}"
puts "Time.zone #{Time.zone.zone_name}; Clock.zone #{Cybertrain::Clock.zone.zone_name}"

puts "-- boxed receivers (rule 62)"
bt = boxed("time")
puts "boxed Time: hour #{bt.hour} min #{bt.min} day #{bt.day} wday #{bt.wday} zone #{bt.zone}"
bz = boxed("zoned")
puts "boxed ZonedTime: hour #{bz.hour} min #{bz.min} day #{bz.day} wday #{bz.wday} zone #{bz.zone}"
bi = boxed("int")
puts "boxed Integer: minutes #{bi.minutes} hour #{bi.hour} day #{bi.day} seconds #{bi.seconds}"
puts "boxed Time advance: #{boxed("time").advance(days: 1).day}"

puts "-- the existing namesakes"
e = Cybertrain::Cron.parse("*/15 9-17 1,15 * *")
puts "Cron::Expression minutes #{e.minutes.inspect} hours #{e.hours.size} days #{e.days.inspect}"
puts "Net::Timer.format_seconds(5.0) #{Cybertrain::Net::Timer.format_seconds(5.0)}; (0.25) #{Cybertrain::Net::Timer.format_seconds(0.25)}"
puts "Net::Timer.now Float? #{Cybertrain::Net::Timer.now.is_a?(Float)}; Test::Receiver.now Float? #{Cybertrain::Test::Receiver.now.is_a?(Float)}"
puts "Cache.now Integer? #{Cybertrain::Cache.now.is_a?(Integer)}"
f = Cybertrain::Flash.new
f.now[:alert] = "x"
puts "Flash#now #{f.now.class}"
Cybertrain::Stream::Poller.last_id = 3
Cybertrain::Stream::Poller.advance_to(7)
puts "Stream::Poller.advance_to answered nil, poller moved"
nodes = Cybertrain::Template::Template.parse("<p><%= 1 + 2 %></p>", "x").nodes
puts "Template::Parser#advance ran: #{nodes.class}"
puts "Schema.current nil? #{Cybertrain::Schema.current.nil?}"
Cybertrain::Schema.define(version: "1") { |d| d }
puts "Schema.current after define: #{Cybertrain::Schema.current.class}"
puts "Time.now.zone (builtin) #{Time.now.utc.zone}"
