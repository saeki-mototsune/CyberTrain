require "date"
require "cybertrain/time_zone"

module Cybertrain
  # The one clock of the framework (spec section 2.2): real time, or the
  # instant a test travelled to. The test helpers `travel_to`,
  # `travel`, `freeze_time` and `travel_back` move it;
  # an application never needs to. `Time.current` answers {Clock.now}.
  #
  # The clock also holds the zone whose calendar the methods of
  # cybertrain/time_ext.rb and `Date.current` use ({zone}, `Time.zone`):
  # UTC until something sets it.
  #
  # The state is module-level ivars (rules 18 and 64): a flag and the
  # instant as Integer microseconds since the epoch (an ivar holding a
  # nullable Time miscompiles, rule 7), and the zone (never nil). Real
  # time is read with `Process.clock_gettime(Process::CLOCK_REALTIME,
  # :microsecond)`, never through `Time.now`, so that a test program's
  # override of `Time.now` (cybertrain/test/time_now.rb) cannot recurse.
  #
  # Threads: the state is process-wide, so a job or server thread sees a
  # test's travel. Two ivars cannot change at once, and nothing locks them;
  # the order of the writes is the whole guarantee that a reader never pairs
  # `@travelling == true` with an instant that was not travelled to (such
  # as 0, 1970). `@micros` is only ever written with a travelled instant,
  # and before `@travelling` becomes true; going back to real time clears
  # `@travelling` alone and leaves `@micros` as it was; {now} reads the
  # flag before the instant. So a reader that saw the flag set reads the
  # instant of this travel or of the one being restored, never 0.
  # @api public
  module Clock
    @travelling = false
    @micros = 0
    @zone = TimeZone::UTC

    # The current time as a UTC Time: real time, or the travelled instant.
    # @return [Time]
    # @api public
    def self.now
      # The flag first, then the instant (the module's comment).
      us = @travelling ? @micros : Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
      Time.at(us / 1_000_000, us % 1_000_000).utc
    end

    # The real time as a UTC Time, whatever a test travelled to (file ages
    # and other readings of the outside world).
    # @return [Time]
    # @api public
    def self.real_now
      us = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
      Time.at(us / 1_000_000, us % 1_000_000).utc
    end

    # Seconds on the monotonic clock (`CLOCK_MONOTONIC`): for waiting and
    # measuring, which a travel never touches.
    # @return [Float]
    # @api public
    def self.monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Sets the clock to `time` without its sub-second part (Rails'
    # `with_usec: false`) and holds it there until {travel_back} or another
    # travel.
    # @param time [Time]
    # @return [nil]
    # @api public
    def self.travel_to(time)
      # The instant first, then the flag (the module's comment).
      @micros = time.to_i * 1_000_000
      @travelling = true
      nil
    end

    # {travel_to} for the duration of the block: the state found before
    # (real time, or the instant of an outer travel) comes back when the
    # block ends, also when it raises. What the block forms of the test
    # helpers call; not for applications. Spikes/NOTES.md rule 103: a
    # module function that saves, yields into a local (rule 90) and
    # restores in `ensure` nests safely. The writes keep the order the
    # module's comment gives: the instant before the flag; when restoring
    # real time, the flag alone.
    # @param time [Time]
    # @yield the code that runs at `time`
    # @return [nil]
    # @api private
    def self.travel_during(time)
      saved_micros = @micros
      saved_travelling = @travelling
      @micros = time.to_i * 1_000_000
      @travelling = true
      _value = yield
      nil
    ensure
      @micros = saved_micros if saved_travelling
      @travelling = saved_travelling
    end

    # Back to real time. Clears the flag only: `@micros` keeps the last
    # travelled instant, so a thread reading the clock meanwhile never sees
    # the flag set beside a cleared instant (see the module's comment).
    # @return [nil]
    # @api public
    def self.travel_back
      @travelling = false
      nil
    end

    # Whether a travel holds the clock.
    # @return [Boolean]
    # @api public
    def self.travelling?
      @travelling
    end

    # The zone whose calendar `beginning_of_day`, `advance` and the other
    # calendar methods on Time, and `Date.current`, follow. UTC by default.
    # Values stay UTC instants whatever the zone (spec section 4).
    # @return [TimeZone]
    # @api public
    def self.zone
      @zone
    end

    # Sets {zone}. Takes a {TimeZone} (`TimeZone.find("Asia/Tokyo")`); a
    # test that sets it puts the one it found back when it ends.
    # @param zone [TimeZone]
    # @return [TimeZone]
    # @api public
    def self.zone=(zone)
      @zone = zone
    end

    # The travelled instant in microseconds since the epoch (a multiple of
    # 1_000_000); 0 when not travelling.
    # @return [Integer]
    # @api public
    def self.travelled_micros
      @travelling ? @micros : 0
    end
  end
end

# Class methods added to Time from Ruby source (spikes/NOTES.md rule 87).
class Time
  # The current time on {Cybertrain::Clock}: a UTC Time (Rails answers a
  # TimeWithZone). Follows `travel_to` in tests.
  # @return [Time]
  # @api public
  def self.current = Cybertrain::Clock.now

  # The zone of {Cybertrain::Clock.zone}: a {Cybertrain::TimeZone}, UTC by
  # default (Rails answers an ActiveSupport::TimeZone; its name is
  # `Time.zone.zone_name`).
  # @return [Cybertrain::TimeZone]
  # @api public
  def self.zone = Cybertrain::Clock.zone
end

# A class method added to Date from Ruby source (spikes/NOTES.md rule 87).
class Date
  # Today on {Cybertrain::Clock}, in `Time.zone`: the date of the zone's
  # wall clock at `Time.current`, so it follows `travel_to` in tests and
  # turns at the zone's midnight. `Date.today` stays the system's date.
  # @return [Date]
  # @api public
  def self.current
    zone = Cybertrain::Clock.zone
    wall = Cybertrain::TimeZone.epoch_to_civil(zone.utc_to_local(Cybertrain::Clock.now.to_i))
    Date.new(wall[0], wall[1], wall[2])
  end
end
