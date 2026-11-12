require "cybertrain/clock"

# Spec section 2.4, spike item 1 (PASS): in a test program, Time.now answers
# Cybertrain::Clock.now, so during a travel Time.now, and every framework or
# library call that reads it, follows the clock, as in Rails. Only test
# programs require this file; a production binary keeps the builtin.
# Cybertrain::Clock reads real time through Process.clock_gettime, never
# Time.now, so this cannot recurse. `Time.new` with no argument stays the
# builtin's real time.
class Time
  # @return [Time] {Cybertrain::Clock.now}
  # @api public
  def self.now = Cybertrain::Clock.now
end
