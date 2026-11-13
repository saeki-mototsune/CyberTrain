# Cybertrain::Cron -- five-field cron expressions and the next minute one
# matches in a Cybertrain::TimeZone. Pure: no clock, no I/O, no state; the
# scheduler's `cron` tasks (cybertrain/scheduler.rb) build on it.
#
# Fields are scanned byte by byte (getbyte/byteslice on a String local,
# spikes/NOTES.md rule 62), so a malformed field is refused with a message
# rather than half-parsed by String#split, which drops trailing empty
# entries.
require "cybertrain/time_zone"

module Cybertrain
  # Five-field cron expressions (minute, hour, day of month, month, day of
  # week) and the next run of one in a {TimeZone}.
  #
  # Each field takes `*`, `n`, `a-b`, `*/n`, `a-b/n`, `a/n` (`a` through the
  # field's end, every `n`) and lists of those joined with `,`. Months take
  # the names `jan`-`dec` and days of week `sun`-`sat`, in any case; day of
  # week `0` and `7` are both Sunday. The `@hourly`-style shortcuts are not
  # accepted. When both the day of month and the day of week are restricted
  # (neither starts with `*`) a day matches if either does, as in cron.
  #
  # {Cron.next_after} reads the zone's wall clock minute by minute in UTC
  # time, so a wall time that a spring transition skips never matches, and
  # across an autumn fold an expression with a fixed hour runs once (at the
  # earlier instant) while one whose hour field starts with `*` runs at both
  # occurrences of the repeated hour (Vixie cron's rule: `30 * * * *` keeps
  # its hourly cadence).
  # @example The next 09:00 on a weekday in Tokyo
  #   expr = Cybertrain::Cron.parse("0 9 * * mon-fri")
  #   tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
  #   Cybertrain::Cron.next_after(expr, Time.current.to_i, tokyo) # => epoch seconds
  # @api public
  module Cron
    # How far ahead {Cron.next_after} looks before it gives up: five years
    # of days, two of them leap days.
    SEARCH_DAYS = 1827
    # Month names, index 0 is January (month 1).
    MONTH_NAMES = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
    # Day-of-week names, index 0 is Sunday.
    WDAY_NAMES = %w[sun mon tue wed thu fri sat].freeze
    # The most days each month can have (February in a leap year).
    MONTH_MAX_DAYS = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31].freeze

    # A parsed expression: the values each field allows, sorted, and the
    # text it was parsed from. Built by {Cron.parse}; immutable.
    # @api public
    class Expression
      # @return [Array<Integer>] the minutes (0..59) it runs at, sorted
      # @api public
      attr_reader :minutes
      # @return [Array<Integer>] the hours (0..23) it runs at, sorted
      # @api public
      attr_reader :hours
      # @return [Array<Integer>] the days of month (1..31) it allows, sorted
      # @api public
      attr_reader :days
      # @return [Array<Integer>] the months (1..12) it allows, sorted
      # @api public
      attr_reader :months
      # @return [Array<Integer>] the days of week (0..6, 0 is Sunday) it
      #   allows, sorted
      # @api public
      attr_reader :wdays
      # @return [String] the text it was parsed from, as given
      # @api public
      attr_reader :expression_text

      # Use {Cron.parse}. The flags say whether the hour, day-of-month and
      # day-of-week fields start with `*` (cron's rules for the fold and for
      # day of month OR day of week).
      def initialize(text, minutes, hours, days, months, wdays, hour_star, dom_star, dow_star)
        @expression_text = text
        @minutes = minutes
        @hours = hours
        @days = days
        @months = months
        @wdays = wdays
        @cron_hour_star = hour_star
        @cron_dom_star = dom_star
        @cron_dow_star = dow_star
        @cron_minute_flags = Cron.flags_of(minutes, 60)
        @cron_hour_flags = Cron.flags_of(hours, 24)
        @cron_day_flags = Cron.flags_of(days, 32)
        @cron_month_flags = Cron.flags_of(months, 13)
        @cron_wday_flags = Cron.flags_of(wdays, 7)
      end

      # True when the hour field starts with `*` (it then runs at both
      # occurrences of an hour repeated by a fold).
      # @return [Boolean]
      def cron_hour_star?
        @cron_hour_star
      end

      # True when minute (0..59) is allowed.
      # @return [Boolean]
      def cron_minute?(minute)
        @cron_minute_flags[minute]
      end

      # True when hour (0..23) is allowed.
      # @return [Boolean]
      def cron_hour?(hour)
        @cron_hour_flags[hour]
      end

      # True when a civil date is allowed: its month, and its day of month
      # and day of week (wday 0 is Sunday) -- either one when both fields
      # are restricted, both otherwise.
      # @return [Boolean]
      def cron_day?(month, mday, wday)
        return false unless @cron_month_flags[month]

        dom = @cron_day_flags[mday]
        dow = @cron_wday_flags[wday]
        if @cron_dom_star || @cron_dow_star
          dom && dow
        else
          dom || dow
        end
      end
    end

    # Parses a five-field expression.
    # @param text [String] such as `"*/15 9-17 * * mon-fri"`
    # @return [Expression]
    # @raise [ArgumentError] `cron "<text>": <what is wrong>` for a field
    #   count other than five, an `@` shortcut, a value out of range, a step
    #   of 0, a name the field does not know, a range that runs backwards,
    #   an empty list entry, or an expression that can never match (`0 0 31
    #   2 *`)
    # @api public
    def self.parse(text)
      s = text.to_s
      fields = cron_words(s)
      if s.strip.start_with?("@")
        refuse(s, "the @ shortcuts are not accepted; write the five fields")
      end
      if fields.size != 5
        reason = "expected 5 fields (minute hour day-of-month month day-of-week), got #{fields.size}"
        refuse(s, reason)
      end
      no_names = Array.new(0) { "" }
      minutes = field_values(s, fields[0], "minute", 0, 59, no_names, 0)
      hours = field_values(s, fields[1], "hour", 0, 23, no_names, 0)
      days = field_values(s, fields[2], "day of month", 1, 31, no_names, 0)
      months = field_values(s, fields[3], "month", 1, 12, MONTH_NAMES, 1)
      wdays = field_values(s, fields[4], "day of week", 0, 7, WDAY_NAMES, 0)
      hour_star = fields[1].start_with?("*")
      dom_star = fields[2].start_with?("*")
      dow_star = fields[4].start_with?("*")
      # Both restricted: a matching day of week makes any month possible.
      if (dom_star || dow_star) && !day_fits_month?(days, months)
        reason = "day of month #{fields[2]} never falls in the months allowed"
        refuse(s, reason)
      end
      Expression.new(s, minutes, hours, days, months, wdays, hour_star, dom_star, dow_star)
    end

    # The first minute strictly after epoch whose wall-clock time in zone
    # matches expr. A wall time a forward transition skips never matches;
    # across a backward transition (a fold) an expression whose hour field
    # starts with `*` runs at both occurrences of the repeated wall time,
    # and one with a fixed hour runs only at a wall time later than
    # epoch's (so the repeated hour, already passed, is not run again).
    #
    # Walks UTC minutes, jumping to the next local midnight when the day is
    # ruled out and to the next local hour when the hour is, so a yearly
    # expression costs about a step per day; a jump that would cross a
    # change of the zone's offset is taken a minute at a time instead.
    # @param expr [Expression]
    # @param epoch [Integer] UTC epoch seconds (the last run, or now)
    # @param zone [TimeZone]
    # @return [Integer] UTC epoch seconds, on a minute boundary
    # @raise [ArgumentError] when nothing matches within five years
    # @api public
    def self.next_after(expr, epoch, zone)
      start = epoch.to_i
      last_local = zone.utc_to_local(start)
      last_local -= last_local % 60
      fixed_hour = !expr.cron_hour_star?
      t = start - start % 60 + 60
      limit = start + SEARCH_DAYS * 86_400
      while t <= limit
        local = zone.utc_to_local(t)
        f = TimeZone.epoch_to_civil(local)
        into_day = f[3] * 3600 + f[4] * 60
        step = 60
        if !expr.cron_day?(f[1], f[2], f[6])
          step = jump(zone, t, 86_400 - into_day)
          step = jump(zone, t, 3600 - f[4] * 60) if step == 60
        elsif !expr.cron_hour?(f[3])
          step = jump(zone, t, 3600 - f[4] * 60)
        elsif expr.cron_minute?(f[4])
          return t unless fixed_hour && local - local % 60 <= last_local
        end
        t += step
      end
      reason = "no run in the #{SEARCH_DAYS / 365} years after #{utc_stamp(start)}"
      refuse(expr.expression_text, reason)
      -1
    end

    # --- internal ------------------------------------------------------

    # Raises the ArgumentError of an expression (message built in a local
    # first, NOTES rule 58).
    def self.refuse(text, reason)
      message = "cron \"#{text}\": #{reason}"
      raise ArgumentError, message
    end

    # seconds when moving t by that many seconds keeps the zone's offset
    # (so the wall clock moves by as much), 60 otherwise.
    def self.jump(zone, t, seconds)
      return 60 if seconds <= 60
      return 60 if zone.utc_offset_at(t + seconds) != zone.utc_offset_at(t)

      seconds
    end

    # "YYYY-MM-DD HH:MM UTC" of an epoch, for messages.
    def self.utc_stamp(epoch)
      f = TimeZone.epoch_to_civil(epoch)
      "#{f[0]}-#{two_digits(f[1])}-#{two_digits(f[2])} #{two_digits(f[3])}:#{two_digits(f[4])} UTC"
    end

    # n (0..99) as two digits.
    def self.two_digits(n)
      n < 10 ? "0#{n}" : n.to_s
    end

    # True when some day of month in days exists in some month in months
    # (February counted with 29 days).
    def self.day_fits_month?(days, months)
      months.each do |m|
        days.each do |d|
          return true if d <= MONTH_MAX_DAYS[m - 1]
        end
      end
      false
    end

    # A table of size flags with true at each of values.
    def self.flags_of(values, size)
      flags = Array.new(size) { false }
      values.each { |v| flags[v] = true }
      flags
    end

    # The words of s, separated by spaces and tabs.
    def self.cron_words(text)
      s = text.to_s
      words = Array.new(0) { "" }
      n = s.bytesize
      i = 0
      while i < n
        while i < n && blank_byte?(s.getbyte(i))
          i += 1
        end
        from = i
        while i < n && !blank_byte?(s.getbyte(i))
          i += 1
        end
        words << s.byteslice(from, i - from).to_s if i > from
      end
      words
    end

    # True for a space, tab, CR or LF byte.
    def self.blank_byte?(b)
      b == 32 || b == 9 || b == 10 || b == 13
    end

    # The pieces of s between each sep byte, empty ones included.
    def self.cron_pieces(text, sep)
      s = text.to_s
      pieces = Array.new(0) { "" }
      n = s.bytesize
      from = 0
      i = 0
      while i < n
        if s.getbyte(i) == sep
          pieces << s.byteslice(from, i - from).to_s
          from = i + 1
        end
        i += 1
      end
      pieces << s.byteslice(from, n - from).to_s
      pieces
    end

    # The byte offset of the first sep in s, or -1.
    def self.byte_offset(text, sep)
      s = text.to_s
      n = s.bytesize
      i = 0
      while i < n
        return i if s.getbyte(i) == sep
        i += 1
      end
      -1
    end

    # The sorted values a field allows (day of week 7 folded into 0).
    def self.field_values(text, field, label, lo, hi, names, name_base)
      flags = Array.new(hi + 1) { false }
      no_names = Array.new(0) { "" }
      cron_pieces(field, 44).each do |entry| # ","
        if entry.empty?
          reason = "#{label} has an empty entry"
          refuse(text, reason)
        end
        steps = cron_pieces(entry, 47) # "/"
        if steps.size > 2
          reason = "#{label} \"#{entry}\" has more than one step"
          refuse(text, reason)
        end
        base = steps[0]
        step = 1
        if steps.size == 2
          step = field_number(text, steps[1], "#{label} step", 0, 999_999, no_names, 0, false)
          if step == 0
            reason = "#{label} step 0 must be at least 1"
            refuse(text, reason)
          end
        end
        from = lo
        to = hi
        if base == "*"
          to = hi == 7 ? 6 : hi
        else
          dash = byte_offset(base, 45) # "-"
          if dash >= 0
            first = base.byteslice(0, dash).to_s
            last = base.byteslice(dash + 1, base.bytesize - dash - 1).to_s
            from = field_number(text, first, label, lo, hi, names, name_base, true)
            to = field_number(text, last, label, lo, hi, names, name_base, true)
            if to < from
              reason = "#{label} range #{base} runs backwards"
              refuse(text, reason)
            end
          else
            from = field_number(text, base, label, lo, hi, names, name_base, true)
            to = steps.size == 2 ? hi : from
          end
        end
        v = from
        while v <= to
          flags[v] = true
          v += step
        end
      end
      flags[0] = true if hi == 7 && flags[7]
      values = Array.new(0) { 0 }
      last_value = hi == 7 ? 6 : hi
      v = lo
      while v <= last_value
        values << v if flags[v]
        v += 1
      end
      values
    end

    # One number (or name) of a field, range-checked when ranged.
    def self.field_number(text, word, label, lo, hi, names, name_base, ranged)
      s = word.to_s
      n = s.bytesize
      digits = n > 0
      i = 0
      while i < n
        b = s.getbyte(i)
        digits = false if b < 48 || b > 57
        i += 1
      end
      if digits
        value = n > 6 ? hi + 1 : s.to_i
        if ranged && (value < lo || value > hi)
          reason = "#{label} #{s} is out of range #{lo}-#{hi}"
          refuse(text, reason)
        end
        return value
      end
      unless names.empty?
        key = s.downcase
        k = 0
        while k < names.size
          return k + name_base if names[k] == key
          k += 1
        end
        kind = name_base == 1 ? "month" : "day"
        reason = "#{label} \"#{s}\" is not a number or a #{kind} name"
        refuse(text, reason)
      end
      reason = "#{label} \"#{s}\" is not a number"
      refuse(text, reason)
      -1
    end
  end
end
