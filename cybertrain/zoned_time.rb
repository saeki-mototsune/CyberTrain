# Cybertrain::ZonedTime -- the wall fields of a UTC instant in one zone
# (spec section 4, "Reading wall fields"), what Time#in_time_zone answers,
# and Time.find_zone!, the name lookup that refuses a zone the system
# zoneinfo does not have.
#
# There is no TimeWithZone: every Time the framework hands out is a UTC
# instant, and `time.hour` is the UTC hour. A ZonedTime is how a program
# reads the zone's hour, day or abbreviation of one. It is a small value:
# no arithmetic, never stored; `to_time` gives the UTC instant back.
#
# The readers carry Rails' names (`hour`, `day`, `zone` ...) beside the
# builtin Time's and Integer#hour / #day (cybertrain/durations.rb): spike
# item 2 compiled them side by side (spikes/phase5/durations.rb).
require "date"
require "cybertrain/time_zone"

module Cybertrain
  # A UTC instant read in one zone: `Time.utc(2026, 11, 11, 20).in_time_zone("Asia/Tokyo")`
  # has `day` 12, `hour` 5 and `zone` "JST".
  # @api public
  class ZonedTime
    # @param epoch [Integer] the UTC instant, epoch seconds
    # @param zone [TimeZone]
    # @param usec [Integer] the instant's microseconds, kept by {#to_time}
    # @api public
    def initialize(epoch, zone, usec = 0)
      @zt_epoch = epoch.to_i
      @zt_usec = usec.to_i
      @zt_offset = zone.utc_offset_at(@zt_epoch)
      @zt_abbr = zone.abbreviation_at(@zt_epoch)
      wall = TimeZone.epoch_to_civil(@zt_epoch + @zt_offset)
      @zt_year = wall[0]
      @zt_month = wall[1]
      @zt_day = wall[2]
      @zt_hour = wall[3]
      @zt_min = wall[4]
      @zt_sec = wall[5]
      @zt_wday = wall[6]
      @zt_yday = TimeZone.days_from_civil(wall[0], wall[1], wall[2]) - TimeZone.days_from_civil(wall[0], 1, 1) + 1
    end

    # @return [Integer] the year on the zone's calendar
    # @api public
    def year = @zt_year

    # @return [Integer] the month, 1 to 12
    # @api public
    def month = @zt_month

    # @return [Integer] the day of the month
    # @api public
    def day = @zt_day

    # @return [Integer] the hour on the zone's wall clock, 0 to 23
    # @api public
    def hour = @zt_hour

    # @return [Integer] the minute, 0 to 59
    # @api public
    def min = @zt_min

    # @return [Integer] the second, 0 to 59
    # @api public
    def sec = @zt_sec

    # @return [Integer] the day of the week, 0 (Sunday) to 6
    # @api public
    def wday = @zt_wday

    # @return [Integer] the day of the year, 1 to 366
    # @api public
    def yday = @zt_yday

    # @return [Integer] seconds east of UTC at this instant (`32400` in Tokyo)
    # @api public
    def utc_offset = @zt_offset

    # The zone's abbreviation at this instant ("JST", "EDT", "GMT"), as
    # the builtin Time#zone answers it.
    # @return [String]
    # @api public
    def zone = @zt_abbr

    # The UTC instant, its microseconds included.
    # @return [Time]
    # @api public
    def to_time = Time.at(@zt_epoch, @zt_usec).utc

    # The civil date on the zone's calendar.
    # @return [Date]
    # @api public
    def to_date = Date.new(@zt_year, @zt_month, @zt_day)

    # The TimeZone `value` names: a TimeZone as it is, anything else by
    # its name through {Time.find_zone!}.
    # @param value [TimeZone, String]
    # @return [TimeZone]
    # @raise [ArgumentError] `unknown time zone "Mars/Base"`
    # @api private
    def self.zone_from(value)
      case value
      when TimeZone then value
      else Time.find_zone!(value.to_s)
      end
    end
  end
end

class Time
  # The zone named `name` (an IANA name such as "Asia/Tokyo"), as Rails'
  # `Time.find_zone!`, from the system zoneinfo ({Cybertrain::TimeZone.find}).
  # @param name [String]
  # @return [Cybertrain::TimeZone]
  # @raise [ArgumentError] `unknown time zone "Mars/Base"` for a name the
  #   system zoneinfo does not have
  # @api public
  def self.find_zone!(name)
    key = name.to_s
    zone = Cybertrain::TimeZone.find(key)
    unless zone.found?
      msg = "unknown time zone #{key.inspect}"
      raise ArgumentError, msg
    end
    zone
  end
end
