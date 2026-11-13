require "cybertrain/clock"

# Spec section 2.4, spike item 1 (PASS): in a test program, Time.now answers
# Cybertrain::Clock.now, so during a travel Time.now, and every framework or
# library call that reads it, follows the clock, as in Rails. Only test
# programs require this file; a production binary keeps the builtin.
# Cybertrain::Clock reads real time through Process.clock_gettime, never
# Time.now, so this cannot recurse. `Time.new` with no argument stays the
# builtin's real time. Like the builtin, it answers local time (the
# process's TZ): the clock's instant through `getlocal`, which keeps the
# instant and the sub-second part and compiles under Spinel 2026.11.04.7026
# (the offset and `utc?` match CRuby's under TZ=UTC, Asia/Tokyo and
# America/New_York). `Time.current` stays UTC.
class Time
  # @return [Time] {Cybertrain::Clock.now} in local time, as the builtin
  #   `Time.now` answers
  # @api public
  def self.now = Cybertrain::Clock.now.getlocal
end
