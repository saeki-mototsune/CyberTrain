# Cybertrain::TimeZone -- named time zones read from the system's TZif files.
#
# Spinel ships no tz database, and switching ENV["TZ"] to convert a time is
# process-wide (not thread-safe). This file reads `/usr/share/zoneinfo/<name>`
# (or `$TZDIR/<name>`) itself: TZif versions 1 to 4 (RFC 8536), the
# transitions and local time types, and the POSIX TZ footer that a "slim"
# file relies on for every instant after its last transition. Everything is
# Integer epoch seconds, so an application can do wall-clock arithmetic on a
# "local epoch" (the wall clock read as if it were UTC) and convert back.
#
# Parsing is byte scans with getbyte on a String local (spikes/NOTES.md
# rule 62), never String#unpack: the file is binary and its counts are
# validated against its length before anything is indexed.
#
# Leap seconds: a "right/" zone's leap-second records are skipped, not
# applied, so its instants are off by the accumulated leap seconds (the
# ordinary zones have none).
module Cybertrain
  # A named time zone, parsed from a TZif file under the zoneinfo directory
  # and cached for the life of the process. A zone is immutable once parsed,
  # so one instance is shared by every thread.
  #
  # Times are Integer epoch seconds. A *local epoch* is a wall-clock reading
  # counted as if it were UTC (`TimeZone.civil_to_epoch(2026, 3, 8, 9, 0, 0)`
  # is 09:00 on 8 March, wherever); {#utc_to_local} and {#local_to_utc}
  # convert between the two, so "tomorrow at 09:00 in Tokyo" is: convert now
  # to local, take the civil date, add a day, rebuild 09:00 and convert back.
  #
  # Unknown names do not raise: {TimeZone.find} answers a zone that behaves as UTC
  # and whose {#found?} is false, so the caller can log a warning.
  # @example The next 09:00 in Asia/Tokyo after now
  #   tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
  #   now = Time.now.to_i
  #   today = Cybertrain::TimeZone.epoch_to_civil(tokyo.utc_to_local(now))
  #   run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2], 9, 0, 0))
  #   run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2] + 1, 9, 0, 0)) if run <= now
  # @api public
  class TimeZone
    # Where zone files are looked up when `TZDIR` is unset or empty.
    DEFAULT_DIR = "/usr/share/zoneinfo"
    # A zone file larger than this is refused (the largest real ones are a
    # few KB).
    MAX_FILE_BYTES = 262_144
    # Longest accepted zone name.
    MAX_NAME_BYTES = 255

    # One date of a POSIX TZ rule: `Jn` (kind 0, n 1..365, February 29
    # never counted), `n` (kind 1, 0..365, counted) or `Mm.w.d` (kind 2),
    # plus the wall-clock time of day it takes effect at, in seconds (can be
    # negative or past 24 hours, RFC 8536 section 3.3.1).
    class TzDate
      attr_reader :rd_kind, :rd_month, :rd_week, :rd_wday, :rd_day, :rd_secs

      def initialize(kind, month, week, wday, day, secs)
        @rd_kind = kind
        @rd_month = month
        @rd_week = week
        @rd_wday = wday
        @rd_day = day
        @rd_secs = secs
      end

      # The day of the year (0 = January 1) this date falls on in year y.
      def day_of_year(year)
        leap = TimeZone.leap_year?(year)
        case @rd_kind
        when 0
          @rd_day - 1 + (leap && @rd_day >= 60 ? 1 : 0)
        when 1
          @rd_day
        else
          first = TimeZone.days_from_civil(year, @rd_month, 1)
          first_wday = (first + 4) % 7
          mday = 1 + (@rd_wday - first_wday) % 7 + (@rd_week - 1) * 7
          mday -= 7 while mday > TimeZone.days_in_month(year, @rd_month)
          first + mday - 1 - TimeZone.days_from_civil(year, 1, 1)
        end
      end

      # The instant (UTC epoch) this date's transition happens in year y,
      # given the UTC offset of the wall clock it is expressed in.
      def instant_in(year, wall_offset)
        days = TimeZone.days_from_civil(year, 1, 1) + day_of_year(year)
        days * 86_400 + @rd_secs - wall_offset
      end
    end

    # A parsed POSIX TZ string (`JST-9`, `EST5EDT,M3.2.0,M11.1.0`,
    # `<+09>-9`). Offsets are stored the RFC 8536 way, seconds east of UTC
    # (the POSIX sign is the other way round). `rule_valid` is false for an
    # empty or malformed string.
    class PosixTz
      attr_reader :rule_valid, :rule_has_dst, :std_utoff, :dst_utoff, :std_abbr, :dst_abbr, :dst_start, :dst_end

      def initialize(valid, has_dst, std_off, dst_off, std_abbr, dst_abbr, dst_start, dst_end)
        @rule_valid = valid
        @rule_has_dst = has_dst
        @std_utoff = std_off
        @dst_utoff = dst_off
        @std_abbr = std_abbr
        @dst_abbr = dst_abbr
        @dst_start = dst_start
        @dst_end = dst_end
      end

      def self.none
        never = TzDate.new(1, 0, 0, 0, 0, 0)
        PosixTz.new(false, false, 0, 0, "", "", never, never)
      end

      def self.parse(text)
        PosixParser.new(text.to_s).posix_tz
      end

      # True when DST is in effect at the UTC instant t. The year is the
      # one the standard-time wall clock shows at t; a rule whose start
      # comes after its end in the year is a southern-hemisphere one.
      def dst_in_effect?(t)
        return false unless @rule_has_dst

        year = TimeZone.epoch_to_civil(t + @std_utoff)[0]
        starts = @dst_start.instant_in(year, @std_utoff)
        ends = @dst_end.instant_in(year, @dst_utoff)
        if starts < ends
          starts <= t && t < ends
        else
          !(ends <= t && t < starts)
        end
      end
    end

    # Byte scanner for a POSIX TZ string (RFC 8536 section 3.3 and POSIX
    # 8.3, with the RFC's extensions: hours up to 167 in a rule time, a
    # negative rule time). Any syntax error makes the result invalid.
    class PosixParser
      def initialize(text)
        @src = text
        @pos = 0
        @ok = true
      end

      def posix_tz
        s = @src
        std_abbr = zone_abbr
        std_off = -clock(24)
        return PosixTz.none unless @ok && !std_abbr.empty?

        dst_none = TzDate.new(1, 0, 0, 0, 0, 0)
        if @pos >= s.bytesize
          return PosixTz.new(true, false, std_off, std_off, std_abbr, std_abbr, dst_none, dst_none)
        end

        dst_abbr = zone_abbr
        return PosixTz.none unless @ok && !dst_abbr.empty?

        dst_off = std_off + 3600
        dst_off = -clock(24) if @pos < s.bytesize && s.getbyte(@pos) != 44
        return PosixTz.none unless @ok

        if @pos >= s.bytesize
          # No rule: the US rules since 2007, as tzcode and glibc assume.
          starts = TzDate.new(2, 3, 2, 0, 0, 7200)
          ends = TzDate.new(2, 11, 1, 0, 0, 7200)
          return PosixTz.new(true, true, std_off, dst_off, std_abbr, dst_abbr, starts, ends)
        end

        expect(44)
        starts = rule_date
        expect(44)
        ends = rule_date
        return PosixTz.none unless @ok && @pos == s.bytesize

        PosixTz.new(true, true, std_off, dst_off, std_abbr, dst_abbr, starts, ends)
      end

      def expect(byte)
        s = @src
        if @pos < s.bytesize && s.getbyte(@pos) == byte
          @pos += 1
        else
          @ok = false
        end
      end

      # "JST", or "<+09>" (returned without the brackets); at least three
      # characters either way.
      def zone_abbr
        s = @src
        n = s.bytesize
        return "" if @pos >= n

        if s.getbyte(@pos) == 60
          from = @pos + 1
          i = from
          while i < n && s.getbyte(i) != 62
            c = s.getbyte(i)
            unless alnum?(c) || c == 43 || c == 45
              @ok = false
              return ""
            end
            i += 1
          end
          if i >= n || i - from < 3
            @ok = false
            return ""
          end
          @pos = i + 1
          return s.byteslice(from, i - from).to_s
        end

        from = @pos
        i = from
        i += 1 while i < n && alpha?(s.getbyte(i))
        if i - from < 3
          @ok = false
          return ""
        end
        @pos = i
        s.byteslice(from, i - from).to_s
      end

      # [+-]hh[:mm[:ss]] in seconds, hh at most max_hours.
      def clock(max_hours)
        s = @src
        sign = 1
        if @pos < s.bytesize
          c = s.getbyte(@pos)
          if c == 43
            @pos += 1
          elsif c == 45
            sign = -1
            @pos += 1
          end
        end
        hours = number(3)
        @ok = false if hours > max_hours
        total = hours * 3600
        if @pos < s.bytesize && s.getbyte(@pos) == 58
          @pos += 1
          minutes = number(2)
          @ok = false if minutes > 59
          total += minutes * 60
          if @pos < s.bytesize && s.getbyte(@pos) == 58
            @pos += 1
            seconds = number(2)
            @ok = false if seconds > 59
            total += seconds
          end
        end
        sign * total
      end

      # Up to max_digits decimal digits (at least one).
      def number(max_digits)
        s = @src
        n = s.bytesize
        value = 0
        digits = 0
        while @pos < n && digits < max_digits
          c = s.getbyte(@pos)
          break if c < 48 || c > 57

          value = value * 10 + (c - 48)
          digits += 1
          @pos += 1
        end
        @ok = false if digits.zero?
        value
      end

      # Jn | n | Mm.w.d, then an optional /time (default 02:00:00).
      def rule_date
        s = @src
        n = s.bytesize
        date = TzDate.new(1, 0, 0, 0, 0, 0)
        if @pos >= n
          @ok = false
          return date
        end
        kind = 1
        month = 0
        week = 0
        wday = 0
        day = 0
        c = s.getbyte(@pos)
        if c == 74
          @pos += 1
          kind = 0
          day = number(3)
          @ok = false if day < 1 || day > 365
        elsif c == 77
          @pos += 1
          kind = 2
          month = number(2)
          expect(46)
          week = number(1)
          expect(46)
          wday = number(1)
          @ok = false if month < 1 || month > 12 || week < 1 || week > 5 || wday > 6
        else
          day = number(3)
          @ok = false if day > 365
        end
        secs = 7200
        if @pos < n && s.getbyte(@pos) == 47
          @pos += 1
          secs = clock(167)
        end
        TzDate.new(kind, month, week, wday, day, secs)
      end

      def alpha?(c)
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
      end

      def alnum?(c)
        alpha?(c) || (c >= 48 && c <= 57)
      end
    end

    # The process-wide cache: an immutable pair of a name => index Hash and
    # a typed Array of zones (a Hash of objects boxes its values; NOTES
    # rule 56). A new zone builds a new ZoneCache and swaps the reference,
    # so a reader takes one consistent snapshot without a lock.
    class ZoneCache
      def initialize(index, list)
        @zc_index = index
        @zc_list = list
      end

      def self.empty
        index = { "" => 0 }
        index.delete("")
        ZoneCache.new(index, Array.new(0) { TimeZone::UTC })
      end

      def zone_index(key)
        @zc_index.key?(key) ? @zc_index[key].to_i : -1
      end

      def zone_at(i)
        @zc_list[i]
      end

      def zone_count
        @zc_list.size
      end

      def with_zone(key, zone)
        index = @zc_index.dup
        list = @zc_list.dup
        index[key] = list.size
        list << zone
        ZoneCache.new(index, list)
      end
    end

    def initialize(name, found, times, type_of, utoffs, dsts, abbrs, footer)
      @tz_name = name
      @tz_found = found
      @tz_times = times
      @tz_type_of = type_of
      @tz_utoffs = utoffs
      @tz_dsts = dsts
      @tz_abbrs = abbrs
      @tz_footer = footer
    end

    # The name the zone was asked for ("Asia/Tokyo").
    # @return [String]
    # @api public
    def zone_name
      @tz_name
    end

    # False when {TimeZone.find} could not resolve or parse the name; the zone then
    # behaves as UTC.
    # @return [Boolean]
    # @api public
    def found?
      @tz_found
    end

    # The opposite of {#found?}.
    # @return [Boolean]
    # @api public
    def unknown?
      !@tz_found
    end

    # The UTC offset in seconds (east positive: 32400 for JST) at an instant.
    # @param epoch [Integer] UTC epoch seconds
    # @return [Integer]
    # @api public
    def utc_offset_at(epoch)
      t = epoch.to_i
      footer = @tz_footer
      if footer_applies?(t)
        return footer.dst_in_effect?(t) ? footer.dst_utoff : footer.std_utoff
      end

      @tz_utoffs[type_at(t)]
    end

    # True when the instant falls in daylight saving time.
    # @param epoch [Integer] UTC epoch seconds
    # @return [Boolean]
    # @api public
    def dst_at?(epoch)
      t = epoch.to_i
      footer = @tz_footer
      return footer.dst_in_effect?(t) if footer_applies?(t)

      @tz_dsts[type_at(t)] == 1
    end

    # The abbreviation in use at an instant ("JST", "EDT", "+09").
    # @param epoch [Integer] UTC epoch seconds
    # @return [String]
    # @api public
    def abbreviation_at(epoch)
      t = epoch.to_i
      footer = @tz_footer
      if footer_applies?(t)
        return footer.dst_in_effect?(t) ? footer.dst_abbr : footer.std_abbr
      end

      @tz_abbrs[type_at(t)]
    end

    # The local epoch (the wall clock counted as if it were UTC) of a UTC
    # instant.
    # @param utc_epoch [Integer]
    # @return [Integer]
    # @api public
    def utc_to_local(utc_epoch)
      t = utc_epoch.to_i
      t + utc_offset_at(t)
    end

    # The UTC instant of a local epoch. Deterministic at transitions:
    # - in a gap (a wall time skipped by a forward jump, 02:30 on a US
    #   spring-forward day), the local time is read with the offset in
    #   effect before the transition, which lands after it (02:30 EST is
    #   03:30 EDT);
    # - in an overlap (a wall time repeated by a backward jump), the earlier
    #   of the two instants is returned (01:30 EDT, not 01:30 EST).
    # Assumes at most one transition within a day of the local time, which
    # holds for every zone in the tz database.
    # @param local_epoch [Integer]
    # @return [Integer]
    # @api public
    def local_to_utc(local_epoch)
      local = local_epoch.to_i
      before = utc_offset_at(local - 86_400)
      after = utc_offset_at(local + 86_400)
      early = local - before
      late = local - after
      early_ok = utc_offset_at(early) == before
      late_ok = utc_offset_at(late) == after
      if early_ok && late_ok
        early < late ? early : late
      elsif late_ok
        late
      else
        early
      end
    end

    # Number of transitions read from the file (for diagnostics and tests).
    # @return [Integer]
    def transition_count
      @tz_times.size
    end

    # True when the file has a POSIX TZ footer that parsed (version 2 and
    # later); without one the last transition's type holds for ever.
    # @return [Boolean]
    def footer?
      @tz_footer.rule_valid
    end

    def footer_applies?(t)
      return false unless @tz_footer.rule_valid

      times = @tz_times
      times.empty? || t > times[times.size - 1]
    end

    # The local time type in effect at t: the type of the last transition at
    # or before t, or type 0 before the first one (RFC 8536 section 3.2).
    def type_at(t)
      times = @tz_times
      return 0 if times.empty? || t < times[0]

      lo = 0
      hi = times.size - 1
      while lo < hi
        mid = (lo + hi + 1) / 2
        if times[mid] <= t
          lo = mid
        else
          hi = mid - 1
        end
      end
      @tz_type_of[lo]
    end

    # --- civil time ----------------------------------------------------

    # Days since 1970-01-01 of a proleptic Gregorian date (month and day
    # may run past their range: day 32 of January is February 1).
    # @param year [Integer]
    # @param month [Integer] 1..12 (others roll into the next/previous years)
    # @param day [Integer]
    # @return [Integer]
    # @api public
    def self.days_from_civil(year, month, day)
      y = year + (month - 1).div(12)
      m = (month - 1) % 12 + 1
      y -= 1 if m <= 2
      era = y.div(400)
      yoe = y - era * 400
      mp = (m + 9) % 12
      doy = (153 * mp + 2) / 5 + day - 1
      doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
      era * 146_097 + doe - 719_468
    end

    # Epoch seconds of a civil date and time, counted as UTC. Pass a local
    # wall-clock reading to get a local epoch for {#local_to_utc}.
    # Out-of-range fields roll over (hour 24 is the next day).
    # @return [Integer]
    # @api public
    def self.civil_to_epoch(year, month, day, hour, minute, second)
      days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second
    end

    # The civil fields of an epoch counted as UTC: `[year, month, day,
    # hour, minute, second, wday]` (wday 0 = Sunday). Pass a local epoch
    # from {#utc_to_local} to read the wall clock.
    # @param epoch [Integer]
    # @return [Array<Integer>]
    # @api public
    def self.epoch_to_civil(epoch)
      e = epoch.to_i
      days = e.div(86_400)
      secs = e - days * 86_400
      z = days + 719_468
      era = z.div(146_097)
      doe = z - era * 146_097
      yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
      doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
      mp = (5 * doy + 2) / 153
      day = doy - (153 * mp + 2) / 5 + 1
      month = mp < 10 ? mp + 3 : mp - 9
      year = yoe + era * 400 + (month <= 2 ? 1 : 0)
      [year, month, day, secs / 3600, (secs % 3600) / 60, secs % 60, (days + 4) % 7]
    end

    def self.leap_year?(year)
      (year % 4).zero? && (!(year % 100).zero? || (year % 400).zero?)
    end

    def self.days_in_month(year, month)
      case month
      when 2 then leap_year?(year) ? 29 : 28
      when 4, 6, 9, 11 then 30
      else 31
      end
    end

    # --- lookup --------------------------------------------------------

    # The zone named name, read from `$TZDIR/<name>` (default
    # `/usr/share/zoneinfo/<name>`) the first time and cached after that.
    # "UTC" is built in and needs no file. A name that is not a plain
    # relative path under the directory (absolute, `..` or `.` segments,
    # characters outside `A-Za-z0-9_+-./`), a missing file or one that is
    # not valid TZif gives a zone that behaves as UTC with {#found?} false;
    # those are not cached.
    #
    # Readers take no lock: the cache is copied on write under a Mutex and
    # swapped in one assignment.
    # @param name [String] an IANA zone name such as "Asia/Tokyo"
    # @return [TimeZone]
    # @api public
    def self.find(name)
      key = name.to_s
      return UTC if key == "UTC"
      return unknown(key) unless valid_name?(key)

      dir = zoneinfo_dir
      path = "#{dir}/#{key}"
      cache = @zone_cache
      i = cache.zone_index(path)
      return cache.zone_at(i) if i >= 0

      zone = load_file(key, path)
      return zone unless zone.found?

      remember(path, zone)
    end

    # The directory zone names resolve under: `TZDIR`, or {DEFAULT_DIR}.
    # @return [String]
    # @api public
    def self.zoneinfo_dir
      dir = ENV["TZDIR"].to_s
      dir.empty? ? DEFAULT_DIR : dir
    end

    # True for a name {TimeZone.find} will look up: 1 to 255 bytes of
    # `A-Za-z0-9_+-./`, relative, with no empty, `.` or `..` segment.
    # @param name [String]
    # @return [Boolean]
    # @api public
    def self.valid_name?(name)
      s = name.to_s
      n = s.bytesize
      return false if n.zero? || n > MAX_NAME_BYTES

      seg_len = 0
      seg_dots = 0
      i = 0
      while i < n
        c = s.getbyte(i)
        if c == 47
          return false if seg_len.zero? || seg_dots == seg_len

          seg_len = 0
          seg_dots = 0
        elsif (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
              c == 95 || c == 43 || c == 45 || c == 46
          seg_len += 1
          seg_dots += 1 if c == 46
        else
          return false
        end
        i += 1
      end
      seg_len.positive? && seg_dots != seg_len
    end

    # Number of zones in the process cache.
    # @return [Integer]
    def self.cached_count
      @zone_cache.zone_count
    end

    # A zone that behaves as UTC and reports {#found?} false.
    def self.unknown(name)
      TimeZone.new(name, false, Array.new(0) { 0 }, Array.new(0) { 0 }, [0], [0], ["UTC"], PosixTz.parse("UTC0"))
    end

    def self.load_file(name, path)
      return unknown(name) unless File.file?(path)
      return unknown(name) if File.size(path) > MAX_FILE_BYTES

      parse_tzif(name, File.binread(path))
    rescue SystemCallError
      unknown(name)
    end

    def self.remember(path, zone)
      kept = zone
      @zone_lock.synchronize do
        kept = store_zone(path, zone)
      end
      kept
    end

    # Under the lock: another thread may have stored the same path since
    # the caller looked, and its zone wins (one instance per path).
    def self.store_zone(path, zone)
      cache = @zone_cache
      i = cache.zone_index(path)
      return cache.zone_at(i) if i >= 0

      @zone_cache = cache.with_zone(path, zone)
      zone
    end

    # --- TZif ------------------------------------------------------------

    # Parses the bytes of a TZif file (RFC 8536, versions 1 to 4). For
    # version 2 and later the 32-bit block is skipped and the 64-bit block
    # and the footer are read. Malformed input gives a zone whose {#found?} is false.
    # @param name [String] the name to report
    # @param bytes [String] the file's contents
    # @return [TimeZone]
    # @api public
    def self.parse_tzif(name, bytes)
      s = bytes.to_s
      n = s.bytesize
      return unknown(name) unless tzif_magic?(s, 0)

      version = s.getbyte(4)
      wide = version >= 50
      pos = 0
      if wide
        v1 = block_bytes(s, 0, 4)
        return unknown(name) if v1 < 0

        pos = 44 + v1
        return unknown(name) unless tzif_magic?(s, pos)
      end
      width = wide ? 8 : 4
      size = block_bytes(s, pos, width)
      return unknown(name) if size < 0

      timecnt = be32(s, pos + 32)
      typecnt = be32(s, pos + 36)
      charcnt = be32(s, pos + 40)
      at = pos + 44
      types_at = at + timecnt * width
      ttinfo_at = types_at + timecnt
      chars_at = ttinfo_at + typecnt * 6

      times = Array.new(0) { 0 }
      type_of = Array.new(0) { 0 }
      i = 0
      while i < timecnt
        t = wide ? be64(s, at + i * 8) : be32_signed(s, at + i * 4)
        return unknown(name) if i.positive? && t <= times[i - 1]

        idx = s.getbyte(types_at + i)
        return unknown(name) if idx >= typecnt

        times << t
        type_of << idx
        i += 1
      end

      utoffs = Array.new(0) { 0 }
      dsts = Array.new(0) { 0 }
      abbrs = Array.new(0) { "" }
      i = 0
      while i < typecnt
        base = ttinfo_at + i * 6
        isdst = s.getbyte(base + 4)
        abbrind = s.getbyte(base + 5)
        return unknown(name) if isdst > 1 || abbrind >= charcnt

        abbr = abbreviation(s, chars_at + abbrind, chars_at + charcnt)
        return unknown(name) if abbr.empty?

        utoffs << be32_signed(s, base)
        dsts << isdst
        abbrs << abbr
        i += 1
      end

      footer = PosixTz.none
      footer = PosixTz.parse(footer_text(s, at + size)) if wide
      TimeZone.new(name, true, times, type_of, utoffs, dsts, abbrs, footer)
    end

    def self.tzif_magic?(s, pos)
      s.bytesize >= pos + 44 && s.getbyte(pos) == 84 && s.getbyte(pos + 1) == 90 &&
        s.getbyte(pos + 2) == 105 && s.getbyte(pos + 3) == 102
    end

    # The byte length of the data block after the header at pos, or -1
    # when the counts are inconsistent or the block runs past the end.
    def self.block_bytes(s, pos, width)
      n = s.bytesize
      isutcnt = be32(s, pos + 20)
      isstdcnt = be32(s, pos + 24)
      leapcnt = be32(s, pos + 28)
      timecnt = be32(s, pos + 32)
      typecnt = be32(s, pos + 36)
      charcnt = be32(s, pos + 40)
      return -1 if timecnt > n || typecnt > n || charcnt > n || leapcnt > n || isutcnt > n || isstdcnt > n
      return -1 if typecnt.zero? || charcnt.zero?
      return -1 unless isutcnt.zero? || isutcnt == typecnt
      return -1 unless isstdcnt.zero? || isstdcnt == typecnt

      size = timecnt * width + timecnt + typecnt * 6 + charcnt + leapcnt * (width + 4) + isstdcnt + isutcnt
      return -1 if pos + 44 + size > n

      size
    end

    # The NUL-terminated abbreviation at from (not past limit); "" when it
    # is empty or holds a byte outside printable ASCII.
    def self.abbreviation(s, from, limit)
      i = from
      while i < limit
        c = s.getbyte(i)
        break if c.zero?
        return "" if c < 32 || c > 126

        i += 1
      end
      return "" if i == from

      s.byteslice(from, i - from).to_s
    end

    # The footer between the two newlines at pos ("" when absent).
    def self.footer_text(s, pos)
      n = s.bytesize
      return "" unless pos < n && s.getbyte(pos) == 10

      i = pos + 1
      while i < n
        return s.byteslice(pos + 1, i - pos - 1).to_s if s.getbyte(i) == 10

        i += 1
      end
      ""
    end

    def self.be32(s, pos)
      (s.getbyte(pos) << 24) | (s.getbyte(pos + 1) << 16) | (s.getbyte(pos + 2) << 8) | s.getbyte(pos + 3)
    end

    def self.be32_signed(s, pos)
      v = be32(s, pos)
      v >= 2_147_483_648 ? v - 4_294_967_296 : v
    end

    # A signed 64-bit big-endian value. A negative one is read through its
    # complement so that no intermediate leaves the 63-bit range.
    def self.be64(s, pos)
      negative = s.getbyte(pos) >= 128
      v = 0
      i = 0
      while i < 8
        b = s.getbyte(pos + i)
        b = 255 - b if negative
        v = v * 256 + b
        i += 1
      end
      negative ? -(v + 1) : v
    end

    # UTC: offset 0, no transitions, found.
    # @api public
    UTC = TimeZone.new("UTC", true, Array.new(0) { 0 }, Array.new(0) { 0 }, [0], [0], ["UTC"], PosixTz.parse("UTC0"))

    @zone_cache = ZoneCache.empty
    @zone_lock = Mutex.new
  end
end
