# Cybertrain::Strftime -- strftime of a pattern built at run time, one
# directive at a time (spikes/NOTES.md rule 96). time_tag's `format:`
# (Template::Helpers.time_tag_strftime) and I18n.l's dictionary formats
# both format through Cybertrain::Strftime.walk. It requires nothing
# else, so cybertrain/i18n.rb (which also loads on its own under CRuby,
# as gen/locales.rb does) uses it without the template layer.
require "date"

module Cybertrain
  # @api private
  module Strftime
    # time formatted by pattern, one directive at a time
    # with literal patterns. Time#strftime given a built String on a
    # polymorphic receiver handed the pattern back unformatted under
    # Spinel 2026.11.04.7026 (the call goes through a dispatch that reads
    # the String's buffer and then returns that buffer).
    #
    # A directive is `%`, flags (`-` no padding, `_` space padding, `0`
    # zero padding, `^` upcase, `#` change case, `:` for `%:z`), a width,
    # then one of: Y C y m d e j H k I l M S L N s p P a A b h B u w U W
    # G g V Z z F T D R r c x X v n t %. `%3N` / `%6N` / `%9N` (any width
    # for N) give that many fraction digits; a width on a number replaces
    # its padding (`%1d`, `%5e`), as in strftime. Anything else raises
    # ArgumentError, as does a lone `%` at the end, and so does a width or
    # flag whose strftime meaning this walk does not reproduce
    # (strftime_refusal: `%6L`, `%-N`, `%:Y`, `%::z`, `%5Z`, `%-T`, `%-_d`):
    # it raises rather than render something else; each message starts
    # with label ("time_tag format", "l format"). Text between
    # directives (multibyte included) is copied as it is.
    def self.walk(time, pattern, label)
      s = pattern.to_s # NOTES rule 62: plain byte reads
      n = s.bytesize
      out = +""
      i = 0
      while i < n
        start = i
        i += 1 while i < n && s.getbyte(i) != 37
        out << s.byteslice(start, i - start).to_s if i > start
        break if i >= n

        dstart = i
        i += 1
        flags = +""
        while i < n
          f = s.getbyte(i)
          # - _ 0 ^ # :
          break unless f == 45 || f == 95 || f == 48 || f == 94 || f == 35 || f == 58

          flags << s.byteslice(i, 1).to_s
          i += 1
        end
        width = 0
        while i < n
          w = s.getbyte(i)
          break unless w >= 48 && w <= 57

          width = width * 10 + (w - 48)
          i += 1
        end
        if i >= n
          msg = "#{label}: incomplete directive #{s.byteslice(dstart, n - dstart)} in #{pattern.inspect}"
          raise ArgumentError, msg
        end
        conv = s.byteslice(i, 1).to_s
        i += 1
        refused = Strftime.strftime_refusal(conv, flags, width)
        unless refused.empty?
          msg = "#{label}: #{s.byteslice(dstart, i - dstart)} in #{pattern.inspect}: #{refused}"
          raise ArgumentError, msg
        end
        piece = Strftime.strftime_directive(time, conv, flags, width)
        if piece.nil?
          msg = "#{label}: unknown directive #{s.byteslice(dstart, i - dstart)} in #{pattern.inspect}"
          raise ArgumentError, msg
        end
        out << piece
      end
      out
    end

    # Why a directive's flags or width are refused ("" when they are
    # not): the combinations whose Time#strftime output this walk does
    # not reproduce raise instead of rendering something else.
    def self.strftime_refusal(conv, flags, width)
      pads = 0
      pads += 1 if flags.include?("-")
      pads += 1 if flags.include?("_")
      pads += 1 if flags.include?("0")
      return "combine at most one of the flags - _ 0" if pads > 1
      return "combine at most one of the flags ^ #" if flags.include?("^") && flags.include?("#")
      if conv == "z"
        return "%z takes no width and no flag but :" if width > 0 || flags.delete(":").size > 0 || flags.count(":") > 1
      elsif flags.include?(":")
        return "the : flag is only for %:z"
      end
      return "%L takes no width or flag; use %3N, %6N or %9N" if conv == "L" && (width > 0 || !flags.empty?)
      return "%N takes no flag" if conv == "N" && !flags.empty?
      return "%Z takes no width" if conv == "Z" && width > 0
      return "%#{conv} takes no flag but ^" if "FTDRrcxXv".include?(conv) && !flags.delete("^").empty?

      ""
    end

    # One directive of time_tag_strftime; nil for an unknown conversion.
    def self.strftime_directive(time, conv, flags, width)
      base = case conv
             when "Y" then time.strftime("%Y")
             when "C" then time.strftime("%C")
             when "y" then time.strftime("%y")
             when "m" then time.strftime("%m")
             when "d" then time.strftime("%d")
             when "e" then time.strftime("%e")
             when "j" then time.strftime("%j")
             when "H" then time.strftime("%H")
             when "k" then time.strftime("%k")
             when "I" then time.strftime("%I")
             when "l" then time.strftime("%l")
             when "M" then time.strftime("%M")
             when "S" then time.strftime("%S")
             when "L" then time.strftime("%L")
             when "N"
               nine = time.strftime("%9N")
               digits = width > 0 ? width : 9
               digits <= 9 ? nine[0, digits].to_s : "#{nine}#{"0" * (digits - 9)}"
             when "s" then time.strftime("%s")
             when "p" then time.strftime("%p")
             when "P" then time.strftime("%P")
             when "a" then time.strftime("%a")
             when "A" then time.strftime("%A")
             when "b", "h" then time.strftime("%b")
             when "B" then time.strftime("%B")
             when "u" then time.strftime("%u")
             when "w" then time.strftime("%w")
             when "U" then time.strftime("%U")
             when "W" then time.strftime("%W")
             when "G" then time.strftime("%G")
             when "g" then time.strftime("%g")
             when "V" then time.strftime("%V")
             when "Z" then time.strftime("%Z")
             when "z"
               zone = time.strftime("%z")
               flags.include?(":") && zone.size == 5 ? "#{zone[0, 3]}:#{zone[3, 2]}" : zone
             when "F" then time.strftime("%Y-%m-%d")
             when "T", "X" then time.strftime("%H:%M:%S")
             when "D", "x" then time.strftime("%m/%d/%y")
             when "R" then time.strftime("%H:%M")
             when "r" then time.strftime("%I:%M:%S %p")
             when "c" then time.strftime("%a %b %e %H:%M:%S %Y")
             when "v" then time.strftime("%e-%^b-%Y")
             when "n" then "\n"
             when "t" then "\t"
             when "%" then "%"
             end
      return nil if base.nil?
      return base if flags.empty? && (width == 0 || conv == "N")

      Strftime.strftime_flags(base, conv, flags, conv == "N" ? 0 : width)
    end

    # Applies the flags and width of a directive to its default text. A
    # width on a number replaces its default padding, as in strftime
    # (`%1d` is "5", `%5e` is "    5").
    def self.strftime_flags(base, conv, flags, width)
      text = base
      numeric = "YCymdejHkIlMSsuwUWGgV".include?(conv)
      if numeric && width > 0
        k = 0
        k += 1 while k < text.size - 1 && (text[k] == "0" || text[k] == " ")
        text = text[k, text.size - k].to_s
        return text if flags.include?("-") || width <= text.size

        pad = "ekl".include?(conv) ? " " : "0"
        pad = " " if flags.include?("_")
        pad = "0" if flags.include?("0")
        return "#{pad * (width - text.size)}#{text}"
      end
      if flags.include?("-")
        # "05" -> "5", " 5" -> "5"
        k = 0
        k += 1 while k < text.size - 1 && (text[k] == "0" || text[k] == " ")
        text = text[k, text.size - k].to_s
      elsif flags.include?("_")
        k = 0
        lead = +""
        while k < text.size - 1 && text[k] == "0"
          lead << " "
          k += 1
        end
        text = "#{lead}#{text[k, text.size - k]}"
      elsif flags.include?("0")
        text = text.tr(" ", "0")
      end
      text = text.upcase if flags.include?("^")
      text = text == text.upcase ? text.downcase : text.upcase if flags.include?("#")
      if width > text.size && !flags.include?("-")
        pad = flags.include?("_") || !numeric ? " " : "0"
        pad = "0" if flags.include?("0")
        text = "#{pad * (width - text.size)}#{text}"
      end
      text
    end

  end
end
