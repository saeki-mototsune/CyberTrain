# Phase 3 spike, check 1 (spec section 14): cron arithmetic over a DST
# transition with Cybertrain::TimeZone, compiled. A record, not a test.
#
# next_after steps the wall clock of the zone a minute at a time from the
# minute after `after`, and for each wall minute that matches the fields
# converts it back with local_to_utc. A wall minute the zone skips (a gap)
# reads back as another wall time through utc_to_local and is dropped; in a
# fold local_to_utc answers the earlier instant, so the second reading of
# the same wall minute is not after `after` and is dropped too: the minute
# runs once.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase3/):
#   spinel $(spin flags) cron_dst.rb -o /tmp/cron_dst && /tmp/cron_dst
# and `ruby -I../.. cron_dst.rb` under CRuby 3.3.6. Output, identical
# under both:
#   london gap: after 2026-03-28 23:00 UTC -> 2026-03-30 00:30 UTC (2026-03-30 01:30 BST)
#   london fold: after 2026-10-24 23:00 UTC -> 2026-10-25 00:30 UTC (2026-10-25 01:30 BST)
#   london fold, next: after 2026-10-25 00:30 UTC -> 2026-10-26 01:30 UTC (2026-10-26 01:30 GMT)
#   london hourly over the gap: 2026-03-29 00:30 UTC (00:30 GMT), 2026-03-29 01:30 UTC (02:30 BST), 2026-03-29 02:30 UTC (03:30 BST)
#   london hourly over the fold: 2026-10-24 23:30 UTC (00:30 BST), 2026-10-25 00:30 UTC (01:30 BST), 2026-10-25 02:30 UTC (02:30 GMT)
#   tokyo: after 2026-03-28 23:00 UTC -> 2026-03-29 16:30 UTC (2026-03-30 01:30 JST)
#   zones found: true true
require "cybertrain/time_zone"

TZ = Cybertrain::TimeZone

# minute and hour: -1 means `*`.
def next_after(minute, hour, after, zone)
  local = zone.utc_to_local(after)
  local = local - local % 60 + 60
  limit = local + 400 * 86_400
  while local < limit
    f = TZ.epoch_to_civil(local)
    if (minute < 0 || f[4] == minute) && (hour < 0 || f[3] == hour)
      utc = zone.local_to_utc(local)
      return utc if zone.utc_to_local(utc) == local && utc > after
    end
    local += 60
  end
  -1
end

def two(n)
  n < 10 ? "0#{n}" : n.to_s
end

def stamp(epoch)
  f = TZ.epoch_to_civil(epoch)
  "#{f[0]}-#{two(f[1])}-#{two(f[2])} #{two(f[3])}:#{two(f[4])}"
end

def both(epoch, zone)
  "#{stamp(epoch)} UTC (#{stamp(zone.utc_to_local(epoch))} #{zone.abbreviation_at(epoch)})"
end

def clock(epoch, zone)
  f = TZ.epoch_to_civil(zone.utc_to_local(epoch))
  "#{stamp(epoch)} UTC (#{two(f[3])}:#{two(f[4])} #{zone.abbreviation_at(epoch)})"
end

london = TZ.find("Europe/London")
tokyo = TZ.find("Asia/Tokyo")

a = TZ.civil_to_epoch(2026, 3, 28, 23, 0, 0)
puts "london gap: after #{stamp(a)} UTC -> #{both(next_after(30, 1, a, london), london)}"

b = TZ.civil_to_epoch(2026, 10, 24, 23, 0, 0)
first = next_after(30, 1, b, london)
puts "london fold: after #{stamp(b)} UTC -> #{both(first, london)}"
puts "london fold, next: after #{stamp(first)} UTC -> #{both(next_after(30, 1, first, london), london)}"

t = TZ.civil_to_epoch(2026, 3, 29, 0, 0, 0)
runs = []
3.times do
  t = next_after(30, -1, t, london)
  runs << clock(t, london)
end
puts "london hourly over the gap: #{runs.join(", ")}"

t = TZ.civil_to_epoch(2026, 10, 24, 23, 0, 0)
runs = []
3.times do
  t = next_after(30, -1, t, london)
  runs << clock(t, london)
end
puts "london hourly over the fold: #{runs.join(", ")}"

puts "tokyo: after #{stamp(a)} UTC -> #{both(next_after(30, 1, a, tokyo), tokyo)}"
puts "zones found: #{london.found?} #{tokyo.found?}"
