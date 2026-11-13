require "cybertrain/clock"

# Rails' ActiveSupport::Testing::TimeHelpers (spec section 2.1), as top-level
# methods like the assertions, so the class form and the top-level form of a
# test both reach them. Each one moves {Cybertrain::Clock}. With a block,
# the state found before comes back when the block ends, also when it
# raises; nested blocks each restore what they found. Without a block, the
# travel lasts until {travel_back} or the end of the test (the runner calls
# `travel_back` after each case). All of them freeze the clock and drop the
# sub-second part.
#
# The block forms forward to {Cybertrain::Clock.travel_during}, a module
# function, because a nested `travel_to` is re-entrant and only a module
# function's save-yield-ensure is proved to nest (spikes/NOTES.md rules 50
# and 103); these methods themselves hold no `ensure`.

# Sets the clock to `time` and holds it there.
# @example
#   travel_to Time.utc(2026, 1, 1) do
#     assert_equal Time.utc(2026, 1, 1), Time.current
#   end
# @param time [Time]
# @yield the code that runs at `time`; the previous clock comes back after it
# @return [nil]
# @api public
def travel_to(time)
  if block_given?
    Cybertrain::Clock.travel_during(time) { yield }
  else
    Cybertrain::Clock.travel_to(time)
  end
  nil
end

# `travel_to(Time.current + seconds)`.
# @example
#   freeze_time
#   travel 6 * 60
# @param seconds [Integer]
# @yield the code that runs at the new time; the previous clock comes back after it
# @return [nil]
# @api public
def travel(seconds)
  target = Time.current + seconds
  if block_given?
    Cybertrain::Clock.travel_during(target) { yield }
  else
    Cybertrain::Clock.travel_to(target)
  end
  nil
end

# `travel_to(Time.current)`: time stops where it is.
# @yield the code that runs on the frozen clock; the previous clock comes back after it
# @return [nil]
# @api public
def freeze_time
  target = Time.current
  if block_given?
    Cybertrain::Clock.travel_during(target) { yield }
  else
    Cybertrain::Clock.travel_to(target)
  end
  nil
end

# Returns the clock to real time.
# @return [nil]
# @api public
def travel_back
  Cybertrain::Clock.travel_back
end
