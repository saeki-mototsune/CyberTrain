# Cybertrain::NumberHelper -- Rails' number helpers as module functions, for
# Ruby code; the same six are template helpers (Template::Helpers).
#
# A number is an Integer, a Float or a numeric String (decimal columns are
# Floats). nil raises ArgumentError here, as any other non-number does; the
# template helpers render "" for nil instead. Every result is built from
# the digits of Integer#to_s or Float#to_s, rounded half up on those digits
# (what Rails gets from BigDecimal(value.to_s)); Float#round is never used,
# so the output is the same under CRuby and Spinel.
module Cybertrain
  module NumberHelper
    UNIT_KEYS = [:unit, :thousand, :million, :billion, :trillion, :quadrillion]
    UNIT_NAMES = ["", "Thousand", "Million", "Billion", "Trillion", "Quadrillion"]
    # Bounds on request-supplied sizes: an exponent ("1e9") or a precision
    # larger than these would build a string of that many digits.
    MAX_EXPONENT = 400
    MAX_PRECISION = 100
    SIZE_UNITS = ["Bytes", "KB", "MB", "GB", "TB", "PB", "EB"]

    # A number as 0.<digits> * 10**point: digits has no leading or trailing
    # zeros ("" for zero), point is the count of digits before the decimal
    # point (0 or negative for 0.00ddd). places is how many fractional
    # digits the source text had.
    class Decimal
      attr_reader :negative, :digits, :point, :places

      def initialize(negative, digits, point, places)
        @negative = negative
        @digits = digits
        @point = point
        @places = places
      end
    end

    # 111.2345 -> "111.235"
    # @api public
    def self.number_with_precision(number, precision: 3, delimiter: "", separator: ".", strip_insignificant_zeros: false)
      d = NumberHelper.parse_number(number, "number_with_precision")
      NumberHelper.check_precision(precision)
      places = precision
      r = NumberHelper.round_places(d, places)
      NumberHelper.render_fixed(r, places, delimiter, separator, strip_insignificant_zeros)
    end

    # 12345678 -> "12,345,678"; the fraction is kept as given.
    # @api public
    def self.number_with_delimiter(number, delimiter: ",", separator: ".")
      d = NumberHelper.parse_number(number, "number_with_delimiter")
      NumberHelper.render_fixed(d, d.places, delimiter, separator, false)
    end

    # 1234 -> "1.23 Thousand": `precision` significant digits, insignificant
    # zeros stripped; units: { unit:, thousand:, million:, billion:,
    # trillion:, quadrillion: } replaces the names; `format:` places the
    # number (%n) and the unit (%u), the result stripped as Rails strips
    # it ("123" for a number below a thousand).
    # @api public
    def self.number_to_human(number, precision: 3, units: {}, format: "%n %u", delimiter: "", separator: ".")
      names = UNIT_NAMES.dup
      i = 0
      while i < UNIT_KEYS.length
        custom = units[UNIT_KEYS[i]]
        names[i] = custom.to_s unless custom.nil?
        i += 1
      end
      NumberHelper.human_text(number, precision, names, format, delimiter, separator)
    end

    # number_to_human over the six unit names (unit, thousand .. quadrillion);
    # the template helper builds them from its own Hash and the locale.
    def self.human_text(number, precision, names, format, delimiter, separator)
      d = NumberHelper.parse_number(number, "number_to_human")
      NumberHelper.check_precision(precision)
      sig = precision < 1 ? 1 : precision
      r = NumberHelper.round_to_k(d, sig)
      return "0" if r.digits.empty?

      idx = r.point <= 0 ? 0 : (r.point - 1) / 3
      idx = 5 if idx > 5
      shifted = Decimal.new(r.negative, r.digits, r.point - 3 * idx, 0)
      frac = r.digits.length - shifted.point
      frac = 0 if frac < 0
      text = NumberHelper.render_fixed(shifted, frac, delimiter, separator, false)
      filled = NumberHelper.fill_currency(format, names[idx], text)
      filled.strip
    end

    # 100 -> "100.000%"; `format:` places the number (%n).
    # @api public
    def self.number_to_percentage(number, precision: 3, format: "%n%", delimiter: "", separator: ".")
      d = NumberHelper.parse_number(number, "number_to_percentage")
      NumberHelper.check_precision(precision)
      places = precision
      r = NumberHelper.round_places(d, places)
      NumberHelper.fill_currency(format, "", NumberHelper.render_fixed(r, places, delimiter, separator, false))
    end

    # 1234.5 -> "$1,234.50"; a negative number takes "-" before the format.
    # @api public
    def self.number_to_currency(number, unit: "$", precision: 2, format: "%u%n", delimiter: ",", separator: ".")
      d = NumberHelper.parse_number(number, "number_to_currency")
      NumberHelper.check_precision(precision)
      places = precision
      r = NumberHelper.round_places(d, places)
      shown = Decimal.new(false, r.digits, r.point, 0)
      amount = NumberHelper.render_fixed(shown, places, delimiter, separator, false)
      pattern = r.negative ? "-#{format}" : format
      NumberHelper.fill_currency(pattern, unit, amount)
    end

    # 1234 -> "1.21 KB" (base 1024, 3 significant digits).
    # @api public
    def self.number_to_human_size(number)
      names = SIZE_UNITS.dup
      names[0] = NumberHelper.byte_count(number) == 1 ? "Byte" : "Bytes"
      NumberHelper.human_size_text(number, 3, names, "%n %u", ".")
    end

    # The whole number of bytes number_to_human_size shows for a size
    # under 1024 (its absolute value, rounded half up), which picks the
    # byte name's plural form; 0 for a larger size.
    def self.byte_count(number)
      d = NumberHelper.parse_number(number, "number_to_human_size")
      value = NumberHelper.float_of(number)
      value = -value if value < 0.0
      return 0 if value >= 1024.0

      whole = NumberHelper.round_places(Decimal.new(false, d.digits, d.point, 0), 0)
      digits = whole.digits
      n = 0
      j = 0
      while j < whole.point
        n = n * 10 + (j < digits.length ? digits[j].ord - 48 : 0)
        j += 1
      end
      n
    end

    # number_to_human_size with `precision` significant digits, the seven
    # unit names (the byte name first, then KB .. EB), the format placing
    # the number (%n) and the unit (%u), and the decimal separator.
    def self.human_size_text(number, precision, names, format, separator)
      d = NumberHelper.parse_number(number, "number_to_human_size")
      NumberHelper.check_precision(precision)
      sign = d.negative ? "-" : ""
      value = NumberHelper.float_of(number)
      value = -value if value < 0.0
      if value < 1024.0
        whole = NumberHelper.round_places(Decimal.new(false, d.digits, d.point, 0), 0)
        text = NumberHelper.render_fixed(whole, 0, "", ".", false)
        return NumberHelper.fill_currency(format, names[0], "#{sign}#{text}")
      end
      idx = 0
      while value >= 1024.0 && idx < 6
        value = value / 1024.0
        idx += 1
      end
      scaled = NumberHelper.parse_number(value, "number_to_human_size")
      sig = precision < 1 ? 1 : precision
      r = NumberHelper.round_to_k(scaled, sig)
      frac = r.digits.length - r.point
      frac = 0 if frac < 0
      text = NumberHelper.render_fixed(r, frac, "", separator, false)
      NumberHelper.fill_currency(format, names[idx], "#{sign}#{text}")
    end

    # --- internals ---------------------------------------------------------

    def self.float_of(number)
      case number
      when Integer then number.to_f
      when Float then number
      else number.to_s.to_f
      end
    end

    # A number's Decimal; anything but an Integer, a Float or a numeric
    # String raises, naming the helper.
    def self.parse_number(number, fname)
      text = nil
      case number
      when Integer then text = number.to_s
      when Float then text = number.to_s
      when String then text = number
      end
      parsed = text.nil? ? nil : NumberHelper.parse_text(text)
      if parsed.nil?
        shown = number.is_a?(String) ? "\"#{number}\"" : number.to_s
        shown = "nil" if number.nil?
        msg = "#{fname}: #{shown} is not a number"
        raise ArgumentError, msg
      end
      parsed
    end

    # ArgumentError for a precision outside 0..MAX_PRECISION.
    def self.check_precision(precision)
      return nil if precision >= 0 && precision <= MAX_PRECISION

      msg = "precision must be between 0 and #{MAX_PRECISION}, got #{precision}"
      raise ArgumentError, msg
    end

    def self.digit?(c)
      c >= "0" && c <= "9"
    end

    # "-12.50", "7", "1.0e+20" -> a Decimal, nil for anything else.
    def self.parse_text(text)
      s = text.to_s
      n = s.length
      i = 0
      negative = false
      if i < n && (s[i] == "-" || s[i] == "+")
        negative = s[i] == "-"
        i += 1
      end
      digits = +""
      point = 0
      frac = 0
      seen_dot = false
      while i < n
        c = s[i]
        if c == "."
          return nil if seen_dot

          seen_dot = true
        elsif NumberHelper.digit?(c)
          digits << c
          if seen_dot
            frac += 1
          else
            point += 1
          end
        else
          break
        end
        i += 1
      end
      return nil if digits.empty?

      exp = 0
      if i < n && (s[i] == "e" || s[i] == "E")
        i += 1
        esign = 1
        if i < n && (s[i] == "-" || s[i] == "+")
          esign = -1 if s[i] == "-"
          i += 1
        end
        start = i
        e = 0
        while i < n && NumberHelper.digit?(s[i])
          e = e * 10 + s[i].to_i
          return nil if e > MAX_EXPONENT

          i += 1
        end
        return nil if i == start

        exp = esign * e
      end
      return nil if i != n

      lead = 0
      while lead < digits.length && digits[lead] == "0"
        lead += 1
      end
      digits = digits[lead, digits.length - lead]
      point -= lead
      digits = NumberHelper.strip_trailing_zeros(digits)
      places = frac - exp
      places = 0 if places < 0
      return Decimal.new(false, "", 1, places) if digits.empty?

      Decimal.new(negative, digits, point + exp, places)
    end

    def self.strip_trailing_zeros(digits)
      n = digits.length
      n -= 1 while n > 0 && digits[n - 1] == "0"
      digits[0, n]
    end

    # "1299" -> "1300", "99" -> "100"
    def self.increment_digits(digits)
      chars = digits.chars
      i = chars.length - 1
      done = false
      while i >= 0 && !done
        if chars[i] == "9"
          chars[i] = "0"
          i -= 1
        else
          chars[i] = (chars[i].ord + 1).chr
          done = true
        end
      end
      text = chars.join
      done ? text : "1#{text}"
    end

    # Round half up to `places` fractional digits.
    def self.round_places(d, places)
      NumberHelper.round_to_k(d, d.point + places)
    end

    # Keep the first k digits of d, rounding half up on the next one.
    def self.round_to_k(d, k)
      digits = d.digits
      return d if k >= digits.length
      return Decimal.new(false, "", 1, 0) if k < 0

      point = d.point
      kept = digits[0, k]
      if digits[k] >= "5"
        if kept.empty?
          kept = "1"
          point += 1
        else
          kept = NumberHelper.increment_digits(kept)
          point += 1 if kept.length > k
        end
      end
      kept = NumberHelper.strip_trailing_zeros(kept)
      return Decimal.new(false, "", 1, 0) if kept.empty?

      Decimal.new(d.negative, kept, point, 0)
    end

    # The digits with exactly `places` fractional digits (zero padded), the
    # integer part grouped by delimiter, a "-" in front of a negative.
    def self.render_fixed(d, places, delimiter, separator, strip)
      digits = d.digits
      point = d.point
      whole = +""
      if point <= 0
        whole << "0"
      else
        j = 0
        while j < point
          whole << (j < digits.length ? digits[j] : "0")
          j += 1
        end
      end
      frac = +""
      j = 0
      while j < places
        idx = point + j
        frac << (idx >= 0 && idx < digits.length ? digits[idx] : "0")
        j += 1
      end
      frac = NumberHelper.strip_trailing_zeros(frac) if strip
      out = +""
      out << "-" if d.negative
      out << NumberHelper.group_digits(whole, delimiter)
      unless frac.empty?
        out << separator
        out << frac
      end
      out
    end

    def self.group_digits(whole, delimiter)
      return whole if delimiter.empty?

      out = +""
      i = 0
      while i < whole.length
        out << delimiter if i > 0 && (whole.length - i) % 3 == 0
        out << whole[i]
        i += 1
      end
      out
    end

    # "%u%n" -> unit and amount substituted; any other text as it is
    # (also the format of number_to_human, number_to_human_size and
    # number_to_percentage).
    def self.fill_currency(pattern, unit, amount)
      out = +""
      i = 0
      while i < pattern.length
        c = pattern[i]
        nxt = i + 1 < pattern.length ? pattern[i + 1] : ""
        if c == "%" && nxt == "u"
          out << unit
          i += 2
        elsif c == "%" && nxt == "n"
          out << amount
          i += 2
        else
          out << c
          i += 1
        end
      end
      out
    end
  end
end
