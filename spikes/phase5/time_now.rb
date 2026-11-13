# Phase 5a spike, item 1 (spec section 16, section 2.4): overriding
# Time.now in a program that requires the whole framework. A record, not a
# test.
#
# Run (Spinel 2026.11.04.7026, from the repository root; a shared 4-vCPU
# cloud machine; the program links SQLite through FFI, so CRuby cannot run
# it):
#   spinel --strict-require -I . -I spikes/phase5 spikes/phase5/time_now.rb -o $TMPDIR/time_now && $TMPDIR/time_now
# Output (182 to 294 s to compile, with other builds on the machine):
#   CLOCK_REALTIME vs builtin Time.new: within 1 ms true
#   Clock.now vs CLOCK_REALTIME: within 1 ms true
#   before: Time.now real true; Model.now_string real true
#   frozen at 1_000_000_000: Time.now.to_i 1000000000; Model.now_string 2001-09-09 01:46:40.000000
#   Time.now.utc 2001-09-09 01:46:40; Time.current 1000000000
#   Time.new (the builtin, not overridden) still real: true
#   after travel_back: Time.now real true
#   Time.at(s, us).utc round trip: 1700000000 123456 2023-11-14 22:13:20.123456
#   inner travel_to raised x
#   outer instant after the inner raise: 1000000000
#   an inner block answered 2000000000; outer again 1000000000
#   travel_to answered a String and 42; after both: real true
#   a block whose only statement raises: only statement; real after true
# Verdict: PASS. The override reaches every call site, the framework's
# included (Model.now_string, cybertrain/model.rb); CLOCK_REALTIME in
# microseconds agrees with the builtin; nested travel_to with rule 103's
# save-yield-ensure restores the outer instant after an inner raise.
require "cybertrain"
require "standins/clock"

# What cybertrain/test/time_now.rb (Task 2) will hold.
class Time
  def self.now = Cybertrain::Clock.now
end

def real_s = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond) / 1_000_000
def near_real?(s) = (s - real_s).abs <= 1

# Time.new with no argument is the builtin's current time, which the
# override does not touch.
def builtin_micros
  t = Time.new
  t.to_i * 1_000_000 + t.usec
end

def framework_now_string = Cybertrain::Model.now_string

real = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
diff = builtin_micros - real
puts "CLOCK_REALTIME vs builtin Time.new: within 1 ms #{diff.abs < 1000}"
puts "Clock.now vs CLOCK_REALTIME: within 1 ms #{(Cybertrain::Clock.micros - real).abs < 1000}"
puts "before: Time.now real #{near_real?(Time.now.to_i)}; Model.now_string real #{framework_now_string[0, 4] == Time.at(real_s).utc.strftime("%Y")}"
Cybertrain::Clock.freeze_at(Time.at(1_000_000_000))
puts "frozen at 1_000_000_000: Time.now.to_i #{Time.now.to_i}; Model.now_string #{framework_now_string}"
puts "Time.now.utc #{Time.now.utc.strftime("%F %T")}; Time.current #{Time.current.to_i}"
puts "Time.new (the builtin, not overridden) still real: #{near_real?(Time.new.to_i)}"
Cybertrain::Clock.travel_back
puts "after travel_back: Time.now real #{near_real?(Time.now.to_i)}"

t = Time.at(1_700_000_000, 123_456).utc
puts "Time.at(s, us).utc round trip: #{t.to_i} #{t.usec} #{t.strftime("%F %T.%6N")}"

t1 = Time.at(1_000_000_000)
t2 = Time.at(2_000_000_000)
v = Cybertrain::Clock.travel_to(t1) do
  begin
    Cybertrain::Clock.travel_to(t2) { raise "x" }
  rescue StandardError => e
    puts "inner travel_to raised #{e.message}"
  end
  puts "outer instant after the inner raise: #{Cybertrain::Clock.now.to_i}"
  inner = Cybertrain::Clock.travel_to(t2) { Time.now.to_i }
  puts "an inner block answered #{inner}; outer again #{Time.now.to_i}"
  "a String"
end
n = Cybertrain::Clock.travel_to(t2) { 42 }
puts "travel_to answered #{v} and #{n}; after both: real #{near_real?(Time.now.to_i)}"
begin
  Cybertrain::Clock.travel_to(t1) { raise ArgumentError, "only statement" }
rescue ArgumentError => e
  puts "a block whose only statement raises: #{e.message}; real after #{near_real?(Time.now.to_i)}"
end
