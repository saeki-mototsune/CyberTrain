require "cybertrain/cast"
require "cybertrain/clock"

# Class methods added to Time from Ruby source (spikes/NOTES.md rule 87),
# for the parts of Ruby's `time` library an application reaches for.
class Time
  STRPTIME_MONTHS = ["january", "february", "march", "april", "may", "june", "july",
                     "august", "september", "october", "november", "december"]
  STRPTIME_DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
  # Milliseconds per digit count of a %L fraction (index = digits read).
  STRPTIME_MS_SCALE = [0, 100, 10, 1]

  # The Time of an ISO 8601 string (`T` or a space, a fraction, `Z` or an
  # offset), as {Cybertrain::Cast.parse_time} reads it.
  # @param text [String]
  # @return [Time]
  # @raise [ArgumentError] "invalid date: ..." when the text is not ISO 8601
  # @api public
  def self.iso8601(text)
    time = Cybertrain::Cast.parse_time(text)
    raise ArgumentError, "invalid date: #{text}" if time.nil?
    time
  end

  # The Time of an RFC 2822 string (`Thu, 05 Nov 2026 09:00:00 +0000`).
  # @param text [String]
  # @return [Time]
  # @raise [ArgumentError] "invalid date: ..." when the text is not RFC 2822
  # @api public
  def self.rfc2822(text)
    time = Cybertrain::Cast.parse_time(text)
    raise ArgumentError, "invalid date: #{text}" if time.nil?
    time
  end

  # Parses `text` by `format`. Directives: `%Y %m %d %H %M %S` (`%m` and
  # `%d` take one or two digits), `%L` (milliseconds), `%z` (`Z`, `+HH`,
  # `+HHMM`, `+HH:MM`), `%Z` (`UTC`, `GMT`, `Z`), `%b %B %a %A` (English
  # names, any case, abbreviated or full), `%j` (day of year), `%s` (epoch
  # seconds) and `%%`; any other byte matches itself. Fields the format
  # leaves out are 1970-01-01 00:00:00; the result is UTC.
  # @example
  #   Time.strptime("05/10/2026 09:07", "%d/%m/%Y %H:%M") # => 2026-10-05 09:07:00 UTC
  # @param text [String]
  # @param format [String]
  # @return [Time]
  # @raise [ArgumentError] "invalid date: ..." when the text does not fit,
  #   "unsupported strptime directive %q" for a directive not listed
  # @api public
  def self.strptime(text, format)
    s = text.to_s # NOTES rule 62: plain byte reads
    f = format.to_s
    n = s.bytesize
    fn = f.bytesize
    year = 1970
    month = 1
    day = 1
    hour = 0
    minute = 0
    second = 0
    usec = 0
    offset = 0
    yday = 0
    epoch = 0
    has_epoch = false
    i = 0
    j = 0
    while j < fn
      c = f.getbyte(j)
      j += 1
      if c != 37
        raise ArgumentError, "invalid date: #{text}" if i >= n || s.getbyte(i) != c
        i += 1
        next
      end
      raise ArgumentError, "unsupported strptime directive %" if j >= fn
      d = f.byteslice(j, 1)
      j += 1
      if d == "%"
        raise ArgumentError, "invalid date: #{text}" if i >= n || s.getbyte(i) != 37
        i += 1
      elsif d == "Y"
        len = strptime_digits(s, i, 4)
        raise ArgumentError, "invalid date: #{text}" if len < 4
        year = Cybertrain::Cast.number_at(s, i, len)
        i += len
      elsif d == "m" || d == "d" || d == "H" || d == "M" || d == "S"
        len = strptime_digits(s, i, 2)
        # %H, %M and %S want two digits; %m and %d accept one.
        min = (d == "m" || d == "d") ? 1 : 2
        raise ArgumentError, "invalid date: #{text}" if len < min
        v = Cybertrain::Cast.number_at(s, i, len)
        i += len
        if d == "m"
          month = v
        elsif d == "d"
          day = v
        elsif d == "H"
          hour = v
        elsif d == "M"
          minute = v
        else
          second = v
        end
      elsif d == "L"
        len = strptime_digits(s, i, 3)
        raise ArgumentError, "invalid date: #{text}" if len == 0
        usec = Cybertrain::Cast.number_at(s, i, len) * STRPTIME_MS_SCALE[len] * 1000
        i += len
      elsif d == "j"
        len = strptime_digits(s, i, 3)
        raise ArgumentError, "invalid date: #{text}" if len == 0
        yday = Cybertrain::Cast.number_at(s, i, len)
        raise ArgumentError, "invalid date: #{text}" if yday < 1 || yday > 366
        i += len
      elsif d == "s"
        neg = i < n && s.getbyte(i) == 45
        i += 1 if neg
        len = strptime_digits(s, i, 18)
        raise ArgumentError, "invalid date: #{text}" if len == 0
        epoch = Cybertrain::Cast.number_at(s, i, len)
        epoch = -epoch if neg
        has_epoch = true
        i += len
      elsif d == "b" || d == "B"
        idx = strptime_name(s, i, STRPTIME_MONTHS)
        raise ArgumentError, "invalid date: #{text}" if idx < 0
        month = idx + 1
        i += strptime_name_length(s, i, STRPTIME_MONTHS[idx])
      elsif d == "a" || d == "A"
        idx = strptime_name(s, i, STRPTIME_DAYS)
        raise ArgumentError, "invalid date: #{text}" if idx < 0
        i += strptime_name_length(s, i, STRPTIME_DAYS[idx])
      elsif d == "Z"
        w = strptime_word(s, i)
        zone = s.byteslice(i, w).downcase
        raise ArgumentError, "invalid date: #{text}" unless zone == "utc" || zone == "gmt" || zone == "z"
        i += w
      elsif d == "z"
        sign = i < n ? s.getbyte(i) : 0
        if sign == 90 || sign == 122
          i += 1
        else
          raise ArgumentError, "invalid date: #{text}" unless sign == 43 || sign == 45
          i += 1
          raise ArgumentError, "invalid date: #{text}" if strptime_digits(s, i, 2) < 2
          hh = Cybertrain::Cast.number_at(s, i, 2)
          i += 2
          i += 1 if i < n && s.getbyte(i) == 58
          mm = 0
          if strptime_digits(s, i, 2) == 2
            mm = Cybertrain::Cast.number_at(s, i, 2)
            i += 2
          end
          raise ArgumentError, "invalid date: #{text}" if hh > 23 || mm > 59
          offset = (hh * 3600 + mm * 60) * (sign == 45 ? -1 : 1)
        end
      else
        raise ArgumentError, "unsupported strptime directive %#{d}"
      end
    end
    raise ArgumentError, "invalid date: #{text}" if i != n
    return Time.at(epoch).utc if has_epoch

    if yday > 0
      month = 1
      day = 1
    end
    time = Cybertrain::Cast.utc_time(year, month, day, hour, minute, second, usec, offset)
    raise ArgumentError, "invalid date: #{text}" if time.nil?
    return time if yday == 0
    raise ArgumentError, "invalid date: #{text}" if yday == 366 && Cybertrain::Cast.days_in_month(year, 2) == 28
    (time + (yday - 1) * 86400).utc
  end

  # How many ASCII digits (at most `max`) `s` has from byte `from`.
  def self.strptime_digits(s, from, max)
    n = s.bytesize
    i = from
    i += 1 while i < n && i - from < max && s.getbyte(i) >= 48 && s.getbyte(i) <= 57
    i - from
  end

  # How many ASCII letters `s` has from byte `from`.
  def self.strptime_word(s, from)
    n = s.bytesize
    i = from
    while i < n
      b = s.getbyte(i) | 32
      break if b < 97 || b > 122
      i += 1
    end
    i - from
  end

  # The index in `names` (lower-case full names) that `s` has at byte
  # `from`, as the full name or its first three letters, any case; -1 when
  # none. The full name wins over the abbreviation.
  def self.strptime_name(s, from, names)
    w = strptime_word(s, from)
    word = s.byteslice(from, w).downcase
    k = 0
    while k < names.length
      return k if word.start_with?(names[k]) && w >= names[k].bytesize
      k += 1
    end
    k = 0
    while k < names.length
      return k if w >= 3 && word.start_with?(names[k].byteslice(0, 3))
      k += 1
    end
    -1
  end

  # Bytes the name `full` occupies in `s` at `from`: the whole name when it
  # is spelled out, else the three-letter abbreviation.
  def self.strptime_name_length(s, from, full)
    w = strptime_word(s, from)
    w >= full.bytesize && s.byteslice(from, full.bytesize).downcase == full ? full.bytesize : 3
  end

  private_class_method :strptime_digits, :strptime_word, :strptime_name, :strptime_name_length

  # --- the calendar in Time.zone (spec sections 3.2 and 4) ---------------
  #
  # Each method below answers a UTC Time. Boundaries and calendar steps are
  # taken in `Time.zone` ({Cybertrain::Clock.zone}, UTC by default): the
  # instant's wall clock is read through `zone.utc_to_local` and
  # `TimeZone.epoch_to_civil`, moved on the civil calendar, and turned back
  # through `TimeZone.civil_to_epoch` and `zone.local_to_utc`. A wall time
  # the zone skips (a spring-forward gap) moves forward by the gap; one that
  # occurs twice takes the earlier instant (ActiveSupport's choice for
  # `Time.zone.local`). A week starts on Monday (Rails' default).

  # The first instant of this instant's day in `Time.zone`.
  # @example With Time.zone Asia/Tokyo
  #   Time.utc(2026, 11, 11, 20).beginning_of_day # => 2026-11-11 15:00:00 UTC
  # @return [Time]
  # @api public
  def beginning_of_day
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.start_of(wall[0], wall[1], wall[2])
  end

  # The last instant of this instant's day in `Time.zone`: 23:59:59.999999
  # (one microsecond before the next day's beginning).
  # @return [Time]
  # @api public
  def end_of_day
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.end_before(wall[0], wall[1], wall[2] + 1)
  end

  # Monday 00:00 of this instant's week in `Time.zone`.
  # @return [Time]
  # @api public
  def beginning_of_week
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.start_of(wall[0], wall[1], wall[2] - (wall[6] + 6) % 7)
  end

  # The last instant of this instant's week (Sunday 23:59:59.999999) in
  # `Time.zone`.
  # @return [Time]
  # @api public
  def end_of_week
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.end_before(wall[0], wall[1], wall[2] - (wall[6] + 6) % 7 + 7)
  end

  # The first instant of this instant's month in `Time.zone`.
  # @return [Time]
  # @api public
  def beginning_of_month
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.start_of(wall[0], wall[1], 1)
  end

  # The last instant of this instant's month in `Time.zone`.
  # @return [Time]
  # @api public
  def end_of_month
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.end_before(wall[0], wall[1] + 1, 1)
  end

  # The first instant of this instant's year in `Time.zone`.
  # @return [Time]
  # @api public
  def beginning_of_year
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.start_of(wall[0], 1, 1)
  end

  # The last instant of this instant's year in `Time.zone`.
  # @return [Time]
  # @api public
  def end_of_year
    wall = Cybertrain::Calendar.wall(to_i)
    Cybertrain::Calendar.end_before(wall[0] + 1, 1, 1)
  end

  # This instant moved by calendar and clock amounts, as Rails'
  # `Time#advance`. Years, months, weeks and days move the wall date in
  # `Time.zone`'s calendar, keeping the wall time of day; a day past the end
  # of the target month is clamped to its last day (31 January plus one
  # month is 28 February, or 29 in a leap year). Hours, minutes and seconds
  # are then added as elapsed seconds. The sub-second part is kept.
  # @example
  #   Time.utc(2026, 1, 31).advance(months: 1) # => 2026-02-28 00:00:00 UTC
  # @param years [Integer]
  # @param months [Integer]
  # @param weeks [Integer]
  # @param days [Integer]
  # @param hours [Integer]
  # @param minutes [Integer]
  # @param seconds [Integer]
  # @return [Time]
  # @api public
  def advance(years: 0, months: 0, weeks: 0, days: 0, hours: 0, minutes: 0, seconds: 0)
    epoch = to_i
    if years != 0 || months != 0 || weeks != 0 || days != 0
      zone = Cybertrain::Clock.zone
      wall = Cybertrain::TimeZone.epoch_to_civil(zone.utc_to_local(epoch))
      count = wall[0] * 12 + wall[1] - 1 + years * 12 + months
      year = count.div(12)
      month = count % 12 + 1
      day = wall[2]
      last = Cybertrain::TimeZone.days_in_month(year, month)
      day = last if day > last
      local = Cybertrain::TimeZone.civil_to_epoch(year, month, day + weeks * 7 + days, wall[3], wall[4], wall[5])
      epoch = zone.local_to_utc(local)
    end
    Time.at(epoch + hours * 3600 + minutes * 60 + seconds, usec).utc
  end

  # `advance(months: -n)`.
  # @param n [Integer]
  # @return [Time]
  # @api public
  def months_ago(n) = advance(months: -n)

  # `advance(months: n)`.
  # @param n [Integer]
  # @return [Time]
  # @api public
  def months_since(n) = advance(months: n)

  # `advance(years: -n)`.
  # @param n [Integer]
  # @return [Time]
  # @api public
  def years_ago(n) = advance(years: -n)

  # `advance(years: n)`.
  # @param n [Integer]
  # @return [Time]
  # @api public
  def years_since(n) = advance(years: n)

  # `advance(days: -1)`: the same wall time the day before in `Time.zone`.
  # @return [Time]
  # @api public
  def yesterday = advance(days: -1)

  # `advance(days: 1)`: the same wall time the next day in `Time.zone`.
  # @return [Time]
  # @api public
  def tomorrow = advance(days: 1)
end

module Cybertrain
  # The civil-calendar steps behind the calendar methods on Time
  # (cybertrain/time_ext.rb), in {Clock.zone}.
  # @api private
  module Calendar
    # The wall-clock fields of a UTC epoch in {Clock.zone}: `[year, month,
    # day, hour, minute, second, wday]` (wday 0 = Sunday).
    # @param epoch [Integer]
    # @return [Array<Integer>]
    # @api private
    def self.wall(epoch)
      TimeZone.epoch_to_civil(Clock.zone.utc_to_local(epoch))
    end

    # The first instant (UTC) of a civil date in {Clock.zone}: its local
    # midnight, or the first instant after it when a transition skips
    # midnight. Out-of-range months and days roll over.
    # @return [Time]
    # @api private
    def self.start_of(year, month, day)
      Time.at(Clock.zone.local_to_utc(TimeZone.civil_to_epoch(year, month, day, 0, 0, 0))).utc
    end

    # One microsecond before {start_of} the given date: the last instant of
    # the period that ends there.
    # @return [Time]
    # @api private
    def self.end_before(year, month, day)
      Time.at(Clock.zone.local_to_utc(TimeZone.civil_to_epoch(year, month, day, 0, 0, 0)) - 1, 999_999).utc
    end
  end
end
