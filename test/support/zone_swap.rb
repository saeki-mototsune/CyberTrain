require "cybertrain/clock"

# Shared by the framework tests that set Time.zone (test/durations.rb,
# test/zoned_time.rb, test/helpers.rb, test/i18n.rb; each one
# `require_relative "support/zone_swap"`). Not a test program itself:
# script/gate and script/test-shard read test/*.rb only.
#
# Sets Cybertrain::Clock.zone for the block and puts the zone found before
# back when it ends, also when an assertion in it fails (pre-flight N17;
# spikes/NOTES.md rule 103's save-yield-ensure in a module function).
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
