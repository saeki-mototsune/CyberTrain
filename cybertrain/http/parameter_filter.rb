module Cybertrain
  # The parameter names whose values never reach a log line or the
  # development error page: Rails' `filter_parameters`. A name is filtered
  # when it contains one of {ParameterFilter.names}, ASCII letters compared
  # case-insensitively, so `password` also filters `user[password]` and
  # `password_confirmation`, and `token` filters `authenticity_token`.
  #
  # The list starts as {DEFAULT_NAMES}; Application#boot installs
  # Config#filter_parameters (`CYBERTRAIN_FILTER_PARAMETERS`) here, since
  # the HTTP layer cannot read the Config itself (the Params.max_page
  # shape). RequestLogger filters the query string of its `Started` line
  # with {ParameterFilter.filter_query}; Dev::ErrorPage the request line
  # and its parameter dump.
  #
  # Every scan here works on bytes: a query string or a parameter name may
  # hold any bytes, invalid UTF-8 included, and is read through a `to_s`
  # local (spikes/NOTES.md rules 52 and 62).
  # @example config/app.rb
  #   config.filter_parameters = config.filter_parameters + ["otp", "ssn"]
  # @api public
  module ParameterFilter
    # What a filtered value is replaced with.
    # @api public
    FILTERED = "[FILTERED]"

    # The names filtered by default (and Config#filter_parameters' default).
    # @api public
    DEFAULT_NAMES = ["password", "password_confirmation", "token", "secret", "secret_key_base",
                     "session_key", "api_key", "authorization"]

    # The installed names, lowercase, without empty ones: a module-level
    # ivar (spikes/NOTES.md rule 18), a copy so that the constant stays
    # what it says.
    @filter_names = DEFAULT_NAMES.dup

    # @return [Array<String>] the names filtered now, lowercase
    # @api public
    def self.names
      @filter_names
    end

    # Installs the names to filter (Application#boot passes
    # Config#filter_parameters). Each is lowercased; empty ones are
    # dropped, so `[]` turns filtering off.
    # @param list [Array<String>]
    # @return [nil]
    # @api public
    def self.names=(list)
      names = Array.new(0) { "" }
      i = 0
      while i < list.size
        name = list[i].to_s.downcase
        names << name unless name.empty?
        i += 1
      end
      @filter_names = names
      nil
    end

    # Whether a parameter's value is filtered: its name contains one of
    # {ParameterFilter.names}, ASCII case-insensitively.
    # @example
    #   Cybertrain::ParameterFilter.filter?("user[Password]")  # => true
    # @param name [String] the parameter name as the application sees it
    #   (decoded)
    # @return [Boolean]
    # @api public
    def self.filter?(name)
      s = name.to_s # NOTES rule 62
      bytes = Array.new(0) { 0 }
      i = 0
      n = s.bytesize
      while i < n
        bytes << ParameterFilter.lower_byte(s.getbyte(i))
        i += 1
      end
      ParameterFilter.bytes_match?(bytes)
    end

    # A query string (or urlencoded form body) with the value of each
    # filtered pair replaced by `[FILTERED]`: `user%5Bpassword%5D=x&page=2`
    # becomes `user%5Bpassword%5D=[FILTERED]&page=2`. Pairs are split on
    # `&`; each name is percent-decoded (`+` as a space) for the
    # comparison only, and everything else is copied byte for byte,
    # undecoded, so the result is still the text as sent apart from the
    # filtered values. A pair without `=` has no value and is kept.
    # @param text [String]
    # @return [String]
    # @api public
    def self.filter_query(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return s if n == 0 || @filter_names.empty?

      # Started as +"" and filled with << only (NOTES rules 60 and 66).
      out = +""
      i = 0
      while i <= n
        j = i
        j += 1 while j < n && s.getbyte(j) != 38
        e = i
        e += 1 while e < j && s.getbyte(e) != 61
        if e < j && ParameterFilter.encoded_name_match?(s, i, e)
          out << s.byteslice(i, e - i + 1).to_s
          out << FILTERED
        else
          out << s.byteslice(i, j - i).to_s
        end
        out << "&" if j < n
        i = j + 1
      end
      out
    end

    # Whether the percent-encoded name in bytes [from, stop) of s, decoded,
    # contains a filtered name. A malformed escape stays literal.
    def self.encoded_name_match?(s, from, stop)
      bytes = Array.new(0) { 0 }
      i = from
      while i < stop
        b = s.getbyte(i)
        if b == 43
          bytes << 32
          i += 1
        elsif b == 37 && i + 2 < stop && ParameterFilter.hex_value(s.getbyte(i + 1)) >= 0 && ParameterFilter.hex_value(s.getbyte(i + 2)) >= 0
          bytes << ParameterFilter.lower_byte(ParameterFilter.hex_value(s.getbyte(i + 1)) * 16 + ParameterFilter.hex_value(s.getbyte(i + 2)))
          i += 3
        else
          bytes << ParameterFilter.lower_byte(b)
          i += 1
        end
      end
      ParameterFilter.bytes_match?(bytes)
    end

    # Whether the lowercased name bytes contain one of the filtered names.
    def self.bytes_match?(bytes)
      names = @filter_names
      k = 0
      while k < names.size
        return true if ParameterFilter.contains?(bytes, names[k])

        k += 1
      end
      false
    end

    # Whether `needle` (lowercase) occurs in `bytes`.
    def self.contains?(bytes, needle)
      w = needle.to_s # NOTES rule 62
      m = w.bytesize
      return false if m == 0 || m > bytes.size

      start = 0
      last = bytes.size - m
      while start <= last
        j = 0
        j += 1 while j < m && bytes[start + j] == w.getbyte(j)
        return true if j == m

        start += 1
      end
      false
    end

    def self.lower_byte(b)
      b >= 65 && b <= 90 ? b + 32 : b
    end

    # 0..15 for an ASCII hex digit, -1 otherwise.
    def self.hex_value(b)
      return b - 48 if b >= 48 && b <= 57
      return b - 55 if b >= 65 && b <= 70
      return b - 87 if b >= 97 && b <= 102

      -1
    end
  end
end
