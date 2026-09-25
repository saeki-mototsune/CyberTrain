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
      when String then parse_time(v)
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
    def self.parse_time(s)
      return nil if s.size < 19
      return nil unless s[4] == "-" && s[7] == "-" && s[13] == ":" && s[16] == ":"
      return nil unless s[10] == "T" || s[10] == " "
      return nil unless digits?(s[0, 4]) && digits?(s[5, 2]) && digits?(s[8, 2])
      return nil unless digits?(s[11, 2]) && digits?(s[14, 2]) && digits?(s[17, 2])

      year = s[0, 4].to_i
      month = s[5, 2].to_i
      day = s[8, 2].to_i
      hour = s[11, 2].to_i
      minute = s[14, 2].to_i
      second = s[17, 2].to_i
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
      s.each_char { |ch| return false if ch < "0" || ch > "9" }
      true
    end
  end
end
