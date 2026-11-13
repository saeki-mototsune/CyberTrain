# Cybertrain::SentryDsn, read by Config's boot check and by the Sentry
# sender; it requires nothing.
module Cybertrain
  # The DSN that turns the Sentry sender on (`CYBERTRAIN_SENTRY_DSN`,
  # {Config#sentry_dsn}; spec section 13.4), read by a byte scan (no
  # regexp). The accepted form is
  #
  #   http[s]://<public key>[:<secret>]@<host>[:<port>][/<path>]/<project id>
  #
  # The secret (Sentry's legacy second half) is accepted and ignored. Every
  # message {problem} gives names the part that is wrong and never repeats
  # the key.
  # @example
  #   dsn = Cybertrain::SentryDsn.from_text("https://abc@o1.ingest.sentry.io/42")
  #   dsn.dsn_endpoint # => "https://o1.ingest.sentry.io/api/42/envelope/"
  # @api public
  class SentryDsn
    # The public key, sent as `sentry_key` in `X-Sentry-Auth`.
    # @return [String]
    # @api public
    attr_reader :dsn_public_key

    # The project id, digits.
    # @return [String]
    # @api public
    attr_reader :dsn_project_id

    # Where events are POSTed:
    # `<scheme>://<host>[:<port>][/<path>]/api/<project id>/envelope/`.
    # @return [String]
    # @api public
    attr_reader :dsn_endpoint

    # @param public_key [String]
    # @param project_id [String]
    # @param endpoint [String]
    # @api private
    def initialize(public_key, project_id, endpoint)
      @dsn_public_key = public_key
      @dsn_project_id = project_id
      @dsn_endpoint = endpoint
    end

    # The parsed DSN; raises ArgumentError with {problem}'s reason when the
    # text is not one.
    # @param text [String]
    # @return [SentryDsn]
    # @raise [ArgumentError]
    # @api public
    def self.from_text(text)
      s = text.to_s # NOTES rule 62
      why = SentryDsn.problem(s)
      raise ArgumentError, why unless why.empty?

      start = s.start_with?("https://") ? 8 : 7
      n = s.bytesize
      slash = SentryDsn.byte_index(s, 47, start, n)
      at = SentryDsn.byte_index(s, 64, start, slash)
      key_end = SentryDsn.byte_index(s, 58, start, at)
      last_slash = SentryDsn.last_byte_index(s, 47, slash, n)
      # Fresh Strings bound to locals before .new (NOTES rule 58).
      key = s.byteslice(start, key_end - start).to_s
      project = s.byteslice(last_slash + 1, n - last_slash - 1).to_s
      scheme = s.byteslice(0, start).to_s
      host_and_port = s.byteslice(at + 1, slash - at - 1).to_s
      path = s.byteslice(slash, last_slash - slash).to_s
      endpoint = "#{scheme}#{host_and_port}#{path}/api/#{project}/envelope/"
      SentryDsn.new(key, project, endpoint)
    end

    # "" when `text` is a DSN {from_text} accepts, else the reason, which
    # never contains the key: "the DSN is empty", "a space, a control
    # character or a non-ASCII byte is not allowed", "the scheme must be
    # https or http", "a query or a fragment is not allowed", "no public key
    # before the @", "the public key may hold only letters, digits, - and
    # _", "no host", "the host may hold only letters, digits, . and - (or an
    # IPv6 address in brackets)", "the port must be a number from 1 to
    # 65535", "no project id", "the project id must be digits" or "the path
    # may hold only letters, digits, -, ., _, ~ and /".
    # @param text [String]
    # @return [String]
    # @api public
    def self.problem(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return "the DSN is empty" if n == 0

      i = 0
      while i < n
        b = s.getbyte(i)
        return "a space, a control character or a non-ASCII byte is not allowed" if b <= 32 || b >= 127

        i += 1
      end
      start = 0
      if s.start_with?("https://")
        start = 8
      elsif s.start_with?("http://")
        start = 7
      end
      return "the scheme must be https or http" if start == 0
      if SentryDsn.byte_index(s, 63, start, n) < n || SentryDsn.byte_index(s, 35, start, n) < n
        return "a query or a fragment is not allowed"
      end

      # The authority ends at the first "/"; the key ends at its first "@".
      slash = SentryDsn.byte_index(s, 47, start, n)
      at = SentryDsn.byte_index(s, 64, start, slash)
      return "no public key before the @" if at == slash

      key_end = SentryDsn.byte_index(s, 58, start, at)
      return "no public key before the @" if key_end == start

      i = start
      while i < key_end
        unless SentryDsn.key_byte?(s.getbyte(i))
          return "the public key may hold only letters, digits, - and _"
        end

        i += 1
      end
      why = SentryDsn.host_problem(s, at + 1, slash)
      return why unless why.empty?

      return "no project id" if slash == n

      last_slash = SentryDsn.last_byte_index(s, 47, slash, n)
      return "no project id" if last_slash == n - 1

      i = last_slash + 1
      while i < n
        b = s.getbyte(i)
        return "the project id must be digits" if b < 48 || b > 57

        i += 1
      end
      i = slash
      while i < last_slash
        unless SentryDsn.path_byte?(s.getbyte(i))
          return "the path may hold only letters, digits, -, ., _, ~ and /"
        end

        i += 1
      end
      ""
    end

    # The reason the bytes from `from` to `to` of `s` are not a host and an
    # optional port, or "".
    # @api private
    def self.host_problem(s, from, to)
      host_chars = "the host may hold only letters, digits, . and - (or an IPv6 address in brackets)"
      host_end = to
      if from < to && s.getbyte(from) == 91
        close = SentryDsn.byte_index(s, 93, from, to)
        return host_chars if close == to
        return "no host" if close == from + 1

        i = from + 1
        while i < close
          b = s.getbyte(i)
          return host_chars unless SentryDsn.hex_byte?(b) || b == 58 || b == 46

          i += 1
        end
        host_end = close + 1
        return host_chars if host_end < to && s.getbyte(host_end) != 58
      else
        host_end = SentryDsn.byte_index(s, 58, from, to)
        return "no host" if host_end == from

        i = from
        while i < host_end
          b = s.getbyte(i)
          return host_chars unless SentryDsn.alnum_byte?(b) || b == 46 || b == 45

          i += 1
        end
      end
      return "" if host_end == to

      SentryDsn.port_problem(s, host_end + 1, to)
    end

    # The reason the bytes from `from` to `to` of `s` are not a port from 1
    # to 65535, or "".
    # @api private
    def self.port_problem(s, from, to)
      why = "the port must be a number from 1 to 65535"
      return why if to == from || to - from > 5

      value = 0
      i = from
      while i < to
        b = s.getbyte(i)
        return why if b < 48 || b > 57

        value = value * 10 + (b - 48)
        i += 1
      end
      return why if value < 1 || value > 65_535

      ""
    end

    # The index of the first `byte` in `s` from `from` up to `to`, or `to`.
    # @api private
    def self.byte_index(s, byte, from, to)
      i = from
      while i < to
        return i if s.getbyte(i) == byte

        i += 1
      end
      to
    end

    # The index of the last `byte` in `s` from `from` up to `to`, or `to`.
    # @api private
    def self.last_byte_index(s, byte, from, to)
      i = to - 1
      while i >= from
        return i if s.getbyte(i) == byte

        i -= 1
      end
      to
    end

    # A-Z, a-z or 0-9.
    # @api private
    def self.alnum_byte?(b)
      (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    end

    # 0-9, A-F or a-f.
    # @api private
    def self.hex_byte?(b)
      (b >= 48 && b <= 57) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102)
    end

    # What a public key may hold: letters, digits, "-" and "_".
    # @api private
    def self.key_byte?(b)
      SentryDsn.alnum_byte?(b) || b == 45 || b == 95
    end

    # What the path before the project id may hold: letters, digits, "-",
    # ".", "_", "~" and "/".
    # @api private
    def self.path_byte?(b)
      SentryDsn.alnum_byte?(b) || b == 45 || b == 46 || b == 95 || b == 126 || b == 47
    end
  end
end
