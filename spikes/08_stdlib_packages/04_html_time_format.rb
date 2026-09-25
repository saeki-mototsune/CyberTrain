# SPIKE (throwaway): hand-rolled HTML escaping + perf, Time formatting/parsing/math, String formatting, Hash/Array ordering.
require "time"

puts "-- HTML escape via gsub with Hash --"
ESCAPE_MAP = { "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;", "'" => "&#39;" }
def escape_html_hash(s)
  s.gsub(/[&<>"']/, ESCAPE_MAP)
end
puts escape_html_hash("<a href=\"x\">Tom & Jerry's \"quote\"</a>")

puts "-- HTML escape via gsub with block --"
def escape_html_block(s)
  s.gsub(/[&<>"']/) do |c|
    case c
    when "&" then "&amp;"
    when "<" then "&lt;"
    when ">" then "&gt;"
    when "\"" then "&quot;"
    when "'" then "&#39;"
    else c
    end
  end
end
puts escape_html_block("<a href=\"x\">Tom & Jerry's \"quote\"</a>")

puts "-- perf: 1e6 escapes of 40-char string --"
sample = "Tom & Jerry's <b>\"great\"</b> cartoon show!!!!"
puts sample.length
t0 = Time.now
i = 0
while i < 1_000_000
  escape_html_hash(sample)
  i += 1
end
t1 = Time.now
puts "hash-gsub 1e6 iters seconds: #{t1 - t0}"

t0b = Time.now
i = 0
while i < 1_000_000
  escape_html_block(sample)
  i += 1
end
t1b = Time.now
puts "block-gsub 1e6 iters seconds: #{t1b - t0b}"

puts "-- Time formatting --"
now = Time.now.utc
iso = now.strftime("%Y-%m-%dT%H:%M:%SZ")
puts iso
puts Time.at(0).utc.strftime("%Y-%m-%dT%H:%M:%SZ")

puts "-- hand parse ISO8601 back to Time --"
def parse_iso(s)
  m = s.match(/\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/)
  return nil unless m
  Time.utc(m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i, m[5].to_i, m[6].to_i)
end
parsed = parse_iso(iso)
puts parsed
puts(parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == iso)

puts "-- Time comparison / subtraction / time_ago --"
t_old = Time.utc(2026, 1, 1, 0, 0, 0)
t_new = Time.utc(2026, 1, 1, 0, 5, 30)
puts t_new > t_old
diff = t_new - t_old
puts diff
def time_ago(seconds)
  s = seconds.to_i
  return "#{s}s ago" if s < 60
  return "#{s / 60}m ago" if s < 3600
  return "#{s / 3600}h ago" if s < 86400
  "#{s / 86400}d ago"
end
puts time_ago(diff)
puts time_ago(45)
puts time_ago(7200)
puts time_ago(200000)

puts "-- String formatting --"
puts format("%.2f", 3.14159)
puts "%.2f" % 3.14159
puts "%5s|%-5s|" % ["ab", "cd"]
puts "abc".rjust(6, "0")
puts "abc".ljust(6, "*")
puts 255.to_s(16)
puts "ff".to_i(16)
puts "hello".bytes.inspect
bs = []
"hi".each_byte { |b| bs << b }
p bs
puts "hello".encoding rescue puts "encoding: NOT SUPPORTED (#{$!.class})"
puts "hello".force_encoding("UTF-8") rescue puts "force_encoding: NOT SUPPORTED (#{$!.class})"
begin
  puts ["AAAA"].pack("a4").unpack1("a4")
rescue => e
  puts "unpack1: NOT SUPPORTED (#{e.class}: #{e.message})"
end

puts "-- Hash insertion order / Array sort_by / group_by / Comparable strings --"
h = {}
h["z"] = 1
h["a"] = 2
h["m"] = 3
puts h.keys.inspect
arr = ["banana", "apple", "cherry"]
puts arr.sort_by { |s| s.length }.inspect
puts arr.sort.inspect
g = arr.group_by { |s| s.length }
p g
puts ("apple" <=> "banana")
puts ("apple" < "banana")
