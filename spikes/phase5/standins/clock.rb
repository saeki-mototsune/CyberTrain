# Phase 5a spike: stand-ins for Tasks 2, 4 and 5 (cybertrain/clock.rb,
# cybertrain/durations.rb, cybertrain/time_ext.rb's calendar methods and
# cybertrain/zoned_time.rb), written only far enough to compile and answer
# the shapes spec sections 2 to 4 give them. Required by durations.rb,
# time_now.rb and class_app/tests.rb. A record, not the framework's code.
require "date"
require "cybertrain/time_zone"

module Cybertrain
  # The clock: Integer microseconds (rule 7: never a nullable Time ivar).
  module Clock
    @micros = 0
    @travelling = false
    @zone = TimeZone::UTC

    def self.real_micros
      Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
    end

    def self.micros
      @travelling ? @micros : real_micros
    end

    # Never reads Time.now: time_now.rb overrides it to call this.
    def self.now
      us = micros
      Time.at(us / 1_000_000, us % 1_000_000)
    end

    def self.zone
      @zone
    end

    def self.zone=(zone)
      @zone = zone
    end

    def self.travel_to(time)
      saved_micros = @micros
      saved_travelling = @travelling
      @micros = time.to_i * 1_000_000
      @travelling = true
      result = yield
      result
    ensure
      @micros = saved_micros
      @travelling = saved_travelling
    end

    def self.freeze_at(time)
      @micros = time.to_i * 1_000_000
      @travelling = true
      nil
    end

    def self.travel_back
      @micros = 0
      @travelling = false
      nil
    end
  end

  # Section 4's local reading of an instant.
  class ZonedTime
    def initialize(utc, zone)
      @zt_utc = utc
      @zt_zone = zone
      @zt_wall = Time.at(zone.utc_to_local(utc.to_i)).utc
    end

    def hour = @zt_wall.hour
    def min = @zt_wall.min
    def sec = @zt_wall.sec
    def day = @zt_wall.day
    def month = @zt_wall.month
    def year = @zt_wall.year
    def wday = @zt_wall.wday
    def yday = @zt_wall.yday
    def zone = @zt_zone.abbreviation_at(@zt_utc.to_i)
    def utc_offset = @zt_zone.utc_offset_at(@zt_utc.to_i)
    def to_time = @zt_utc
    def to_date = Date.new(@zt_wall.year, @zt_wall.month, @zt_wall.day)
  end
end

class Integer
  def seconds = self
  def second = self
  def minutes = self * 60
  def minute = self * 60
  def hours = self * 3600
  def hour = self * 3600
  def days = self * 86_400
  def day = self * 86_400
  def weeks = self * 604_800
  def week = self * 604_800
  def ago = Cybertrain::Clock.now - self
  def from_now = Cybertrain::Clock.now + self
end

class Time
  def self.current = Cybertrain::Clock.now
  def self.zone = Cybertrain::Clock.zone

  def beginning_of_day
    Time.utc(year, month, day)
  end

  def advance(years: 0, months: 0, weeks: 0, days: 0, hours: 0, minutes: 0, seconds: 0)
    m0 = year * 12 + (month - 1) + years * 12 + months
    y = m0.div(12)
    m = m0 % 12 + 1
    d = day
    last = Cybertrain::TimeZone.days_in_month(y, m)
    d = last if d > last
    t = Time.utc(y, m, d, hour, min, sec)
    t + (weeks * 7 + days) * 86_400 + hours * 3600 + minutes * 60 + seconds
  end

  def months_ago(n) = advance(months: -n)

  def in_time_zone(zone = Time.zone)
    Cybertrain::ZonedTime.new(self, zone)
  end
end

class Date
  def self.current = Time.current.in_time_zone.to_date
end
