require "cybertrain/clock"

# Durations on Integer (spec section 3.1): `5.minutes`, `1.day`,
# `2.weeks.ago`, `3.days.from_now`, `Time.current + 90.seconds`.
#
# A duration is an Integer number of seconds (Rails answers an
# ActiveSupport::Duration): `5.minutes == 300` and `5.minutes.inspect` is
# `"300"`, so `300.ago` works as `5.minutes.ago` does.
#
# `month(s)` and `year(s)` are not defined: a month has no fixed length in
# seconds, and an Integer cannot carry "one calendar month". `1.month`
# raises NoMethodError ("undefined method 'month' for an instance of
# Integer") when it is reached, under Spinel as under CRuby: an
# application's program always defines some `month` (ZonedTime#month), and
# Spinel refuses an undefined method at build only while nothing in the
# program defines the name (spikes/phase5/durations_month.rb). Use the
# calendar-aware forms on Time instead: `1.month.ago` is
# `Time.current.months_ago(1)`, `1.year.from_now` is
# `Time.current.years_since(1)`, `time + 1.month` is
# `time.advance(months: 1)`.
class Integer
  # This many seconds (the Integer itself).
  # @return [Integer]
  # @api public
  def seconds = self

  # `1.second`: the Integer itself.
  # @return [Integer]
  # @api public
  def second = self

  # This many minutes in seconds (`5.minutes # => 300`).
  # @return [Integer]
  # @api public
  def minutes = self * 60

  # `1.minute # => 60`.
  # @return [Integer]
  # @api public
  def minute = self * 60

  # This many hours in seconds (`2.hours # => 7200`).
  # @return [Integer]
  # @api public
  def hours = self * 3600

  # `1.hour # => 3600`.
  # @return [Integer]
  # @api public
  def hour = self * 3600

  # This many days of 86,400 seconds (`2.days # => 172800`). For calendar
  # days in `Time.zone` across a DST change, use `time.advance(days: n)`.
  # @return [Integer]
  # @api public
  def days = self * 86_400

  # `1.day # => 86400`.
  # @return [Integer]
  # @api public
  def day = self * 86_400

  # This many weeks in seconds (`2.weeks # => 1209600`).
  # @return [Integer]
  # @api public
  def weeks = self * 604_800

  # `1.week # => 604800`.
  # @return [Integer]
  # @api public
  def week = self * 604_800

  # The Time this many seconds before `Time.current`, on the Clock (so it
  # follows `travel_to`): `2.weeks.ago`.
  # @return [Time]
  # @api public
  def ago = Cybertrain::Clock.now - self

  # The Time this many seconds after `Time.current`, on the Clock:
  # `3.days.from_now`.
  # @return [Time]
  # @api public
  def from_now = Cybertrain::Clock.now + self
end
