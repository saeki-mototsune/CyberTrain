require "date"
require "json"
require "cybertrain/db/blob"

module Cybertrain
  # Converts loosely typed values (SQLite cells, form strings) into the one
  # concrete type each model attribute holds. Generated models call these from
  # load_row/write_attribute; nullable attributes go through the *_or_nil
  # variants because Spinel needs a nullable ivar assigned through a helper
  # that can return nil (spikes/NOTES.md rule 7).
  module Cast
    TRUE_STRINGS = ["1", "true", "t", "on", "yes"]

    def self.int(v)
      case v
      when Integer then v
      when Float then v.to_i
      when String then v.to_i
      when true then 1
      else 0
      end
    end

    # nil and "" (an empty form field) mean "no value".
    def self.int_or_nil(v)
      case v
      when nil then nil
      when Integer then v
      when Float then v.to_i
      when String then v.empty? ? nil : v.to_i
      when true then 1
      when false then 0
      else nil
      end
    end

    def self.str(v)
      case v
      when nil then ""
      when String then v
      when Time then iso8601(v)
      else v.to_s
      end
    end

    def self.str_or_nil(v)
      case v
      when nil then nil
      when String then v
      when Time then iso8601(v)
      else v.to_s
      end
    end

    # A binary (BLOB) cell or attribute as its bytes: the String itself (a
    # BLOB cell from `Connection#execute` is a String of the exact bytes),
    # a {DB::Blob}'s bytes, "" for nil.
    # @param v [String, DB::Blob, nil]
    # @return [String]
    # @api public
    def self.binary(v)
      case v
      when nil then ""
      when String then v
      when DB::Blob then v.blob_bytes
      else v.to_s
      end
    end

    def self.float(v)
      case v
      when Float then v
      when Integer then v.to_f
      when String then v.to_f
      else 0.0
      end
    end

    def self.float_or_nil(v)
      case v
      when nil then nil
      when Float then v
      when Integer then v.to_f
      when String then v.empty? ? nil : v.to_f
      else nil
      end
    end

    # true/false, 1/0 (SQLite), "1"/"0", "true"/"false", "on" (checkbox), "".
    def self.bool(v)
      case v
      when true then true
      when false then false
      when Integer then v != 0
      when String then TRUE_STRINGS.include?(v.downcase)
      else false
      end
    end

    def self.bool_or_nil(v)
      case v
      when nil then nil
      when String then v.empty? ? nil : bool(v)
      else bool(v)
      end
    end

    # Time as is; Integer as epoch seconds; a String through {Cast.parse_time}
    # (ISO 8601 with `T` or a space, a fraction, `Z` or an offset; RFC 2822);
    # anything else is nil.
    # @param v [Time, Integer, String, nil]
    # @return [Time, nil]
    # @api public
    def self.time_or_nil(v)
      case v
      when Time then v
      when Integer then Time.at(v).utc
      # v.to_s so parse_time's parameter is a String, not the polymorphic
      # v: its byte reads are then plain C (see Html.escape).
      when String then parse_time(v.to_s)
      else nil
      end
    end

    # The value to bind for a column: a Time in the storage format
    # ({Cast.sql_datetime}), a Date as `YYYY-MM-DD`, a Hash as its JSON
    # text ({Cast.json_text}), booleans as 1/0; nil, Integer, Float and
    # String pass through. `when Time` comes before the container branch
    # (NOTES rule 8).
    # @param v [Object]
    # @return [Object]
    # @api public
    def self.to_sql(v)
      case v
      when Time then sql_datetime(v)
      when Date then v.to_s
      when Hash then json_text(v)
      when true then 1
      when false then 0
      else v
      end
    end

    # The storage format of a datetime, the one Rails writes to SQLite:
    # UTC, a space, six fraction digits, no suffix
    # (`2026-10-05 09:00:00.123456`). Every writer of a DATETIME column
    # binds this; it sorts as text in time order.
    # @param time [Time]
    # @return [String]
    # @api public
    def self.sql_datetime(time)
      time.getutc.strftime("%Y-%m-%d %H:%M:%S.%6N")
    end

    # The display format of a datetime, Rails' `as_json`: UTC, `T`,
    # milliseconds, `Z` (`2026-10-05T09:00:00.123Z`). `as_json`, `to_json`
    # and {Cast.str} use it; storage uses {Cast.sql_datetime}.
    # @param time [Time]
    # @return [String]
    # @api public
    def self.iso8601(time)
      time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    # `YYYY-MM-DD[T ]HH:MM:SS`, then an optional `.` and 1 to 9 fraction
    # digits (the first six kept: microseconds), then an optional `Z`,
    # `+HH:MM`, `-HH:MM`, `+HHMM` or `-HHMM` (applied: the answer is the
    # same instant in UTC), and nothing after it. A String whose fourth byte
    # is `,` is read as RFC 2822 instead ({Cast.parse_rfc2822}). Anything
    # else is nil. The C reader `cybertrain_sqlite_column_epoch`
    # (db/sqlite_ffi.rb) accepts the same shapes.
    #
    # Checks the shape and the ranges (month, day of that month, hour,
    # minute, second) before calling Time.utc, which raises on out-of-range
    # fields: a bad cell or form value must read as nil, not crash.
    #
    # Reads bytes, not substrings: every datetime column of every loaded row
    # comes through here, and slicing out six fields (plus a one-character
    # String per digit for the check) was a tenth of an article page's time.
    # The bytes it accepts are all ASCII, so a multibyte String is refused
    # exactly as the character-indexed version refused it.
    #
    # The argument is read through a `to_s` local: it is often boxed (a
    # value out of JSON.parse or a Hash of mixed values, or what Cast.str
    # hands back: `when String then v` returns the boxed v), and a boxed
    # `getbyte` raises NoMethodError in a program that requires the openssl
    # package (spikes/NOTES.md rule 62). For a String, `to_s` is no copy.
    # @param text [String]
    # @return [Time, nil]
    # @api public
    def self.parse_time(text)
      s = text.to_s
      n = s.bytesize
      return parse_rfc2822(s) if n > 3 && s.getbyte(3) == 44
      return nil if n < 19
      return nil unless s.getbyte(4) == 45 && s.getbyte(7) == 45 && s.getbyte(13) == 58 && s.getbyte(16) == 58
      sep = s.getbyte(10)
      return nil unless sep == 84 || sep == 32

      i = 19
      usec = 0
      if i < n && s.getbyte(i) == 46
        start = i + 1
        i = start
        i += 1 while i < n && i - start < 10 && s.getbyte(i) >= 48 && s.getbyte(i) <= 57
        digits = i - start
        return nil if digits == 0 || digits > 9
        kept = digits < 6 ? digits : 6
        # A table, not a `usec *= 10` loop: Spinel types an Integer
        # multiplied in an unbounded loop as a Bigint.
        usec = number_at(s, start, kept) * FRACTION_SCALE[kept]
      end
      offset = 0
      if i < n
        offset = offset_at(s, i)
        return nil if offset == OFFSET_INVALID
      end
      utc_time(number_at(s, 0, 4), number_at(s, 5, 2), number_at(s, 8, 2),
               number_at(s, 11, 2), number_at(s, 14, 2), number_at(s, 17, 2), usec, offset)
    end

    # FRACTION_SCALE[k]: what k fraction digits are multiplied by to make
    # microseconds.
    FRACTION_SCALE = [1_000_000, 100_000, 10_000, 1_000, 100, 10, 1]

    # What {Cast.offset_at} answers for a suffix it does not accept (no
    # real offset is this many seconds).
    OFFSET_INVALID = -1_000_000

    # The UTC offset in seconds of the zone suffix that starts at byte
    # `from` and runs to the end of `text`: `Z` is 0, `+HH:MM` / `+HHMM`
    # east, `-HH:MM` / `-HHMM` west; {OFFSET_INVALID} for anything else.
    def self.offset_at(text, from)
      s = text.to_s # NOTES rule 62, as in parse_time
      rest = s.bytesize - from
      sign = s.getbyte(from)
      return(rest == 1 ? 0 : OFFSET_INVALID) if sign == 90
      return OFFSET_INVALID unless sign == 43 || sign == 45
      # The length first: number_at reads every byte it is asked for.
      return OFFSET_INVALID unless rest == 5 || rest == 6
      hours = number_at(s, from + 1, 2)
      if rest == 6 && s.getbyte(from + 3) == 58
        minutes = number_at(s, from + 4, 2)
      elsif rest == 5
        minutes = number_at(s, from + 3, 2)
      else
        return OFFSET_INVALID
      end
      return OFFSET_INVALID if hours < 0 || hours > 23 || minutes < 0 || minutes > 59
      seconds = hours * 3600 + minutes * 60
      sign == 45 ? -seconds : seconds
    end

    RFC2822_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    RFC2822_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    # RFC 2822 (`Thu, 05 Nov 2026 09:00:00 +0000`): the English day name and
    # a comma, a one- or two-digit day, the English month name, a four-digit
    # year, `HH:MM:SS`, and a `+HHMM` / `-HHMM` offset (or `GMT` / `UT`),
    # single spaces between. The answer is in UTC; anything else is nil.
    # Bytes, as in {Cast.parse_time}.
    # @param text [String]
    # @return [Time, nil]
    # @api public
    def self.parse_rfc2822(text)
      s = text.to_s # NOTES rule 62, as in parse_time
      n = s.bytesize
      return nil if n < 26
      return nil unless RFC2822_DAYS.include?(s.byteslice(0, 3)) && s.getbyte(3) == 44 && s.getbyte(4) == 32
      i = 5
      day_len = s.getbyte(6) == 32 ? 1 : 2
      day = number_at(s, i, day_len)
      i += day_len
      return nil unless s.getbyte(i) == 32
      month = month_at(s, i + 1)
      return nil if month < 0
      i += 4
      return nil unless s.getbyte(i) == 32 && s.getbyte(i + 5) == 32
      year = number_at(s, i + 1, 4)
      i += 6
      return nil if n < i + 9
      return nil unless s.getbyte(i + 2) == 58 && s.getbyte(i + 5) == 58 && s.getbyte(i + 8) == 32
      hour = number_at(s, i, 2)
      minute = number_at(s, i + 3, 2)
      second = number_at(s, i + 6, 2)
      i += 9
      zone = s.byteslice(i, n - i)
      offset = if zone == "GMT" || zone == "UT"
                 0
               elsif n - i == 5
                 offset_at(s, i)
               else
                 OFFSET_INVALID
               end
      return nil if offset == OFFSET_INVALID
      utc_time(year, month, day, hour, minute, second, 0, offset)
    end

    # The month (1 to 12) whose English three-letter name starts at byte
    # `from`, -1 for none (an Integer sentinel, not `index`'s nil: NOTES
    # rule 11).
    def self.month_at(text, from)
      name = text.to_s.byteslice(from, 3)
      m = 0
      while m < 12
        return m + 1 if RFC2822_MONTHS[m] == name
        m += 1
      end
      -1
    end

    # Time.utc of the fields, less `offset` seconds (the fields were local
    # to that offset), or nil when a field is out of range (-1 from
    # {Cast.number_at} included): Time.utc raises on those.
    def self.utc_time(year, month, day, hour, minute, second, usec, offset)
      return nil if year < 0 || day < 0 || hour < 0 || minute < 0 || second < 0
      return nil if month < 1 || month > 12
      return nil if day < 1 || day > days_in_month(year, month)
      return nil if hour > 23 || minute > 59 || second > 59

      time = Time.utc(year, month, day, hour, minute, second, usec)
      offset == 0 ? time : (time - offset).utc
    end

    # A DATE cell or attribute: a Date as is, `YYYY-MM-DD` text as that
    # Date, and `Date.new(1970, 1, 1)` for anything else, so a NOT NULL
    # column holding a corrupt cell does not take the row down.
    # @param v [Date, String, nil]
    # @return [Date]
    # @api public
    def self.date(v)
      d = date_or_nil(v)
      d.nil? ? Date.new(1970, 1, 1) : d
    end

    # {Cast.date} for a nullable column: a Date as is, `YYYY-MM-DD` text
    # (strict: no other shape, valid month and day) as that Date, nil for
    # anything else. `when Time` first (NOTES rule 8): a Time is not a Date.
    # @param v [Date, String, nil]
    # @return [Date, nil]
    # @api public
    def self.date_or_nil(v)
      case v
      when Time then nil
      when Date then v
      when String then parse_date(v.to_s)
      else nil
      end
    end

    # `YYYY-MM-DD` as a Date, nil for any other text (bytes, NOTES rule 62).
    def self.parse_date(text)
      s = text.to_s
      return nil unless s.bytesize == 10 && s.getbyte(4) == 45 && s.getbyte(7) == 45
      year = number_at(s, 0, 4)
      month = number_at(s, 5, 2)
      day = number_at(s, 8, 2)
      return nil if year < 0 || month < 1 || month > 12
      return nil if day < 1 || day > days_in_month(year, month)
      Date.new(year, month, day)
    end

    def self.days_in_month(year, month)
      case month
      when 4, 6, 9, 11 then 30
      when 2 then leap_year?(year) ? 29 : 28
      else 31
      end
    end

    def self.leap_year?(year)
      (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    end

    def self.digits?(text)
      s = text.to_s # NOTES rule 62, as in parse_time
      i = 0
      n = s.bytesize
      while i < n
        b = s.getbyte(i)
        return false if b < 48 || b > 57
        i += 1
      end
      true
    end

    # The decimal number in s's bytes [from, from + len), or -1 when one of
    # them is not an ASCII digit.
    def self.number_at(text, from, len)
      s = text.to_s # NOTES rule 62, as in parse_time
      value = 0
      i = from
      stop = from + len
      while i < stop
        b = s.getbyte(i)
        return -1 if b < 48 || b > 57
        value = value * 10 + (b - 48)
        i += 1
      end
      value
    end

    # --- binds, LIKE patterns, JSON containers (issue #74) ------------------

    # The bind Array `Connection#execute` takes, each value through
    # {Cast.to_sql} (a Time in the storage format, a Date as its text, a
    # Hash as JSON, booleans as 1/0).
    # A splat compiles under Spinel (Params#permit takes one too); the
    # result is the polymorphic Array, seeded so it stays one when every
    # argument has the same type.
    # @example
    #   sql = "SELECT COUNT(*) AS n FROM stats WHERE project_id = ? AND at >= ?"
    #   Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(project.id, since)) }
    # A {DB::Blob} passes through and binds as a BLOB.
    # @param values [Array<Object>] nil, Integer, Float, String, true/false,
    #   Time, Date, Hash or DB::Blob
    # @return [Array<Object>]
    # @api public
    def self.binds(*values)
      out = [nil, 0, 0.0, "", DB::Blob.new("")]
      out.clear
      values.each { |v| out << to_sql(v) }
      out
    end

    # `text` with `\`, `%` and `_` escaped by a backslash, for a LIKE
    # pattern written with `ESCAPE '\'`. Relation#where_like wraps it in
    # `%...%`; a prefix search writes its own pattern:
    # @example
    #   pattern = Cybertrain::Cast.like_escape(params[:q]) + "%"
    #   Article.all.where_sql("title LIKE ? ESCAPE '\\'", [pattern])
    # @param text [String]
    # @return [String]
    # @api public
    def self.like_escape(text)
      s = text.to_s # NOTES rule 62: a boxed String argument (request data)
      out = +""
      i = 0
      n = s.bytesize
      start = 0
      while i < n
        b = s.getbyte(i)
        # 92 `\`, 37 `%`, 95 `_`: ASCII bytes, so the byteslice boundaries
        # around them are character boundaries.
        if b == 92 || b == 37 || b == 95
          out << s.byteslice(start, i - start) if i > start
          out << "\\"
          start = i
        end
        i += 1
      end
      out << s.byteslice(start, n - start) if n > start
      out
    end

    # A fresh empty Hash typed String => any value, what {Cast.hash}
    # returns for a value that is not a Hash. Seeded with a value of every
    # scalar type (NOTES rules 9 and 46), so `spinel --emit-rbs` reads it as
    # `Hash[String, untyped]` rather than an empty literal's guess.
    # @return [Hash{String => Object}]
    # @api public
    def self.empty_hash
      h = { "" => [nil, 0, 0.0, "", true][0] }
      h.delete("")
      h
    end

    # A fresh empty Array of any values ({Cast.array}'s fallback), seeded
    # like {Cast.empty_hash}.
    # @return [Array<Object>]
    # @api public
    def self.empty_array
      a = [[nil, 0, 0.0, "", true][0]]
      a.clear
      a
    end

    # Narrows a parsed JSON value (or any polymorphic one) to a Hash: its
    # pairs, keys through to_s, copied into a fresh {Cast.empty_hash}, or
    # that empty Hash when `v` is not a Hash. A copy, not `v` itself: the
    # copy is typed `Hash[String, untyped]` for the compiler, where handing
    # back the boxed `v` leaves every later call on it on the slow path.
    # It is shallow (nested containers are shared). `when Time` comes
    # before the container branches (NOTES rule 8).
    # @example
    #   doc = Cybertrain::Cast.hash(JSON.parse(body))
    #   tags = Cybertrain::Cast.array(doc["tags"])
    # @param v [Object]
    # @return [Hash{String => Object}]
    # @api public
    def self.hash(v)
      out = empty_hash
      case v
      when Time then nil
      when Hash then v.each { |k, x| out[k.to_s] = x }
      end
      out
    end

    # {Cast.hash} for a nullable json column: nil for nil and `""`; a
    # String is JSON text, parsed and then narrowed by {Cast.hash} (a
    # non-object root or invalid JSON is `{}`, no exception); any other
    # value goes to {Cast.hash} as it is.
    # @example
    #   meta = Cybertrain::Cast.hash_or_nil(row["meta"])
    # @param v [String, Hash, nil]
    # @return [Hash{String => Object}, nil]
    # @api public
    def self.hash_or_nil(v)
      case v
      when nil then nil
      when Time then hash(v)
      when String
        text = v.to_s
        text.empty? ? nil : hash(parse_json(text))
      else hash(v)
      end
    end

    # JSON.parse of `text`, nil when it is not JSON. NestingError is named
    # first (NOTES rule 61).
    def self.parse_json(text)
      JSON.parse(text)
    rescue JSON::NestingError
      nil
    rescue JSON::ParserError
      nil
    end

    # A json column's stored text: `JSON.generate` of a Hash, nil for nil
    # (SQL NULL); any other value is narrowed by {Cast.hash} first (`{}`).
    # @param v [Hash, nil]
    # @return [String, nil]
    # @api public
    def self.json_text(v)
      case v
      when nil then nil
      when Time then JSON.generate(hash(v))
      when Hash then JSON.generate(v)
      else JSON.generate(hash(v))
      end
    end

    # A decimal value rounded to the column's scale: `v` as a Float,
    # `round(scale)`; a negative scale (none declared) leaves it unrounded.
    # A Float at every scale: `Float#round(0)` answers an Integer, so the
    # rounded value goes through `to_f`.
    # @param v [Float, Integer, String]
    # @param scale [Integer]
    # @return [Float]
    # @api public
    def self.round_scale(v, scale)
      f = float(v)
      scale < 0 ? f : f.round(scale).to_f
    end

    # {Cast.round_scale} for a nullable decimal column: nil (and `""`, an
    # empty form field) stay nil, so an unset value is stored as NULL,
    # never 0.0; anything else is {Cast.float_or_nil}'s Float rounded to
    # `scale`.
    # @param v [Float, Integer, String, nil]
    # @param scale [Integer]
    # @return [Float, nil]
    # @api public
    def self.round_scale_or_nil(v, scale)
      f = float_or_nil(v)
      return nil if f.nil?
      scale < 0 ? f : f.round(scale).to_f
    end

    # A NOT NULL json column's value as a Hash: a Hash's pairs (keys
    # through to_s, {Cast.hash}'s typed copy); a String is the stored JSON
    # text, parsed and then narrowed by {Cast.hash}, so an object root is
    # its Hash and an array or scalar root, invalid JSON or `""` is `{}`
    # (a corrupt cell does not take the row down); anything else is `{}`.
    # {Cast.hash} alone would read the stored text as `{}`.
    # `when Time` first (NOTES rule 8).
    # @example
    #   meta = Cybertrain::Cast.json_hash(row["meta"])
    # @param v [String, Hash, nil]
    # @return [Hash{String => Object}]
    # @api public
    def self.json_hash(v)
      case v
      when Time then empty_hash
      when String
        text = v.to_s
        text.empty? ? empty_hash : hash(parse_json(text))
      else hash(v)
      end
    end

    # {Cast.hash} for Arrays: `v`'s elements in a fresh {Cast.empty_array},
    # or that empty Array when `v` is not an Array.
    # @param v [Object]
    # @return [Array<Object>]
    # @api public
    def self.array(v)
      out = empty_array
      case v
      when Time then nil
      when Array then v.each { |x| out << x }
      end
      out
    end
  end
end
