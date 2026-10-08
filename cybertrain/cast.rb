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

    # Time as is; Integer as epoch seconds; "YYYY-MM-DDTHH:MM:SSZ" or
    # "YYYY-MM-DD HH:MM:SS" (both read as UTC); anything else is nil.
    def self.time_or_nil(v)
      case v
      when Time then v
      when Integer then Time.at(v).utc
      # Interpolated so parse_time's parameter is a String, not the
      # polymorphic v: its byte reads are then plain C (see Html.escape).
      when String then parse_time("#{v}")
      else nil
      end
    end

    # The value to bind for a column: Time as its UTC ISO8601 string,
    # booleans as 1/0; nil, Integer, Float and String pass through.
    def self.to_sql(v)
      case v
      when Time then iso8601(v)
      when true then 1
      when false then 0
      else v
      end
    end

    def self.iso8601(time)
      time.getutc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    # Checks the shape and the ranges (month, day of that month, hour,
    # minute, second) before calling Time.utc, which raises on out-of-range
    # fields: a bad cell or form value must read as nil, not crash.
    #
    # Reads bytes, not substrings: every datetime column of every loaded row
    # comes through here, and slicing out six fields (plus a one-character
    # String per digit for the check) was a tenth of an article page's time.
    # The 19 bytes it accepts are all ASCII, so a multibyte String is
    # refused exactly as the character-indexed version refused it.
    def self.parse_time(s)
      return nil if s.bytesize < 19
      return nil unless s.getbyte(4) == 45 && s.getbyte(7) == 45 && s.getbyte(13) == 58 && s.getbyte(16) == 58
      sep = s.getbyte(10)
      return nil unless sep == 84 || sep == 32

      year = number_at(s, 0, 4)
      month = number_at(s, 5, 2)
      day = number_at(s, 8, 2)
      hour = number_at(s, 11, 2)
      minute = number_at(s, 14, 2)
      second = number_at(s, 17, 2)
      return nil if year < 0 || day < 0 || hour < 0 || minute < 0 || second < 0
      return nil if month < 1 || month > 12
      return nil if day < 1 || day > days_in_month(year, month)
      return nil if hour > 23 || minute > 59 || second > 59

      Time.utc(year, month, day, hour, minute, second)
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

    def self.digits?(s)
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
    def self.number_at(s, from, len)
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
  end
end
