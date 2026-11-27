# The MySQL connection URL:
#
#   mysql://USER[:PASSWORD]@HOST[:PORT][/DATABASE][?NAME=VALUE&...]
#
# HOST is a name, a dotted IPv4 address or a bracketed IPv6 address
# ([::1]). USER and PASSWORD are percent-decoded (%40 is "@"); `+` is a
# plus. The userinfo ends at the LAST "@", so a password may hold an
# unescaped "@", "/" or "?". The parameters are ssl_mode ("verify", the
# default, or "disabled") and connect_timeout, read_timeout, write_timeout
# (whole seconds, defaults 5 / 30 / 30); any other name is refused, so a
# misspelt one is not silently ignored.
#
# ssl_mode=disabled is accepted only for a host that cannot be on the far
# side of an untrusted network: the literal "localhost", a loopback
# address (127.0.0.0/8, ::1), an RFC 1918 address (10/8, 172.16/12,
# 192.168/16) or a unique local IPv6 address (fc00::/7). The check is on
# the text of the URL; no name is looked up.
#
# Every fault is an ArgumentError whose message names the part at fault and
# never repeats the URL, so the password cannot reach a log through it.
#
# Byte scans over a `to_s` local (spikes/NOTES.md rules 27, 62); decoded
# bytes are written with setbyte into a buffer of the final size (rule 60).
require "cybertrain/http/ip_address"

module Cybertrain
  module DB
    module MySQL
      # @api private
      class Url
        DEFAULT_PORT = 3306
        PARAMETERS = "ssl_mode, connect_timeout, read_timeout, write_timeout"
        MAX_TIMEOUT = 86_400

        attr_reader :host, :port, :user, :password, :database, :ssl_mode,
                    :connect_timeout, :read_timeout, :write_timeout

        def initialize(host, port, user, password, database, ssl_mode, connect_timeout, read_timeout, write_timeout)
          @host = host
          @port = port
          @user = user
          @password = password
          @database = database
          @ssl_mode = ssl_mode
          @connect_timeout = connect_timeout
          @read_timeout = read_timeout
          @write_timeout = write_timeout
        end

        # "host:port", "[::1]:3306" for an IPv6 address: what messages name.
        def server_label
          return "[#{@host}]:#{@port}" if @host.include?(":")

          "#{@host}:#{@port}"
        end

        # @param text [String]
        # @return [Url]
        # @raise [ArgumentError] naming the fault, never with the password
        def self.parse(text)
          s = text.to_s # NOTES rule 62
          scheme = "mysql://"
          Url.refuse("must start with mysql://") unless s.start_with?(scheme)

          rest = s.byteslice(scheme.bytesize, s.bytesize - scheme.bytesize)
          at = Url.last_at(rest)
          Url.refuse("no user name") if at < 0

          userinfo = rest.byteslice(0, at)
          after = rest.byteslice(at + 1, rest.bytesize - at - 1)
          colon = Url.find_byte(userinfo, 58, 0)
          user_part = colon < 0 ? userinfo : userinfo.byteslice(0, colon)
          password_part = colon < 0 ? "" : userinfo.byteslice(colon + 1, userinfo.bytesize - colon - 1)
          user = Url.percent_decode(user_part)
          password = Url.percent_decode(password_part)
          Url.refuse("no user name") if user.empty?

          query_at = Url.find_byte(after, 63, 0)
          before_query = query_at < 0 ? after : after.byteslice(0, query_at)
          query = query_at < 0 ? "" : after.byteslice(query_at + 1, after.bytesize - query_at - 1)
          slash = Url.find_byte(before_query, 47, 0)
          authority = slash < 0 ? before_query : before_query.byteslice(0, slash)
          database = slash < 0 ? "" : before_query.byteslice(slash + 1, before_query.bytesize - slash - 1)
          Url.refuse("the database name cannot contain '/'") if Url.find_byte(database, 47, 0) >= 0

          host_and_port = Url.split_authority(authority)
          host = host_and_port[0]
          port = Url.port_number(host_and_port[1])

          ssl_mode = "verify"
          connect_timeout = 5
          read_timeout = 30
          write_timeout = 30
          pos = 0
          while pos < query.bytesize
            amp = Url.find_byte(query, 38, pos)
            stop = amp < 0 ? query.bytesize : amp
            pair = query.byteslice(pos, stop - pos)
            pos = stop + 1
            next if pair.empty?

            eq = Url.find_byte(pair, 61, 0)
            Url.refuse("malformed parameter '#{pair}' (expected name=value)") if eq < 0

            name = pair.byteslice(0, eq)
            value = pair.byteslice(eq + 1, pair.bytesize - eq - 1)
            if name == "ssl_mode"
              Url.refuse("unknown ssl_mode '#{value}' (use verify or disabled)") unless value == "verify" || value == "disabled"
              ssl_mode = value
            elsif name == "connect_timeout"
              connect_timeout = Url.timeout_seconds(name, value)
            elsif name == "read_timeout"
              read_timeout = Url.timeout_seconds(name, value)
            elsif name == "write_timeout"
              write_timeout = Url.timeout_seconds(name, value)
            else
              Url.refuse("unknown parameter '#{name}' (known: #{PARAMETERS})")
            end
          end

          if ssl_mode == "disabled" && !Url.local_host?(host_and_port[0], host_and_port[2] == "6")
            Url.refuse("ssl_mode=disabled is allowed only for localhost, a loopback address, an RFC 1918 address or fc00::/7, " \
                     "not #{host}: without TLS the session crosses the network in plain text (host names are not looked up)")
          end

          Url.new(host, port, user, password, database, ssl_mode, connect_timeout, read_timeout, write_timeout)
        end

        # Raises the ArgumentError every fault is.
        def self.refuse(why)
          raise ArgumentError, "MySQL URL: #{why}"
        end

        # The byte offset of the last "@", or -1.
        def self.last_at(text)
          s = text.to_s
          i = s.bytesize - 1
          i -= 1 while i >= 0 && s.getbyte(i) != 64
          i
        end

        # The offset of the first `byte` at or after `from`, or -1.
        def self.find_byte(text, byte, from)
          s = text.to_s
          i = from
          size = s.bytesize
          i += 1 while i < size && s.getbyte(i) != byte
          i < size ? i : -1
        end

        # [host, port text, "6" for a bracketed IPv6 host or ""]. The port
        # text is "-" when the authority has none.
        def self.split_authority(text)
          s = text.to_s
          if s.start_with?("[")
            close = Url.find_byte(s, 93, 0)
            Url.refuse("'[' without ']' in the host") if close < 0

            host = s.byteslice(1, close - 1)
            Url.refuse("no host") if host.empty?
            Url.refuse("'[#{host}]' is not an IPv6 address") unless IpAddress.parse_ipv6(host).size == 16

            tail = s.byteslice(close + 1, s.bytesize - close - 1)
            return [host, "-", "6"] if tail.empty?
            Url.refuse("unexpected text after the IPv6 address") unless tail.start_with?(":")

            return [host, tail.byteslice(1, tail.bytesize - 1), "6"]
          end

          colon = Url.find_byte(s, 58, 0)
          host = colon < 0 ? s : s.byteslice(0, colon)
          Url.refuse("no host") if host.empty?
          return [host, "-", ""] if colon < 0

          [host, s.byteslice(colon + 1, s.bytesize - colon - 1), ""]
        end

        # The port of `text` ("-" for none: the default).
        def self.port_number(text)
          s = text.to_s
          return DEFAULT_PORT if s == "-"

          value = Url.small_number(s)
          Url.refuse("the port must be a number from 1 to 65535") if value < 1 || value > 65_535
          value
        end

        # The seconds of a timeout parameter.
        def self.timeout_seconds(name, text)
          value = Url.small_number(text)
          Url.refuse("#{name} must be a whole number of seconds from 1 to #{MAX_TIMEOUT}") if value < 1 || value > MAX_TIMEOUT
          value
        end

        # One to six decimal digits as an Integer, or -1 for anything else
        # (String#to_i raises past 64 bits under Spinel, NOTES rule 25).
        def self.small_number(text)
          s = text.to_s
          return -1 if s.empty? || s.bytesize > 6

          value = 0
          i = 0
          while i < s.bytesize
            b = s.getbyte(i)
            return -1 if b < 48 || b > 57

            value = value * 10 + (b - 48)
            i += 1
          end
          value
        end

        # `text` with each %XX replaced by its byte. Not
        # URI.decode_www_form_component, which reads "+" as a space and
        # raises its own message on a bad escape (NOTES rule 28).
        def self.percent_decode(text)
          s = text.to_s
          size = s.bytesize
          count = 0
          i = 0
          while i < size
            if s.getbyte(i) == 37
              if i + 2 >= size || Url.hex_value(s.getbyte(i + 1)) < 0 || Url.hex_value(s.getbyte(i + 2)) < 0
                Url.refuse("malformed percent-escape in the user name or password")
              end
              i += 3
            else
              i += 1
            end
            count += 1
          end
          return s if count == size

          out = "0" * count
          i = 0
          k = 0
          while i < size
            b = s.getbyte(i)
            if b == 37
              out.setbyte(k, Url.hex_value(s.getbyte(i + 1)) * 16 + Url.hex_value(s.getbyte(i + 2)))
              i += 3
            else
              out.setbyte(k, b)
              i += 1
            end
            k += 1
          end
          out
        end

        def self.hex_value(b)
          return b - 48 if b >= 48 && b <= 57
          return b - 87 if b >= 97 && b <= 102
          return b - 55 if b >= 65 && b <= 70

          -1
        end

        # Whether `host` is one ssl_mode=disabled may reach: see the header.
        # `bracketed` says it was written as [IPv6].
        def self.local_host?(host, bracketed)
          s = host.to_s
          unless bracketed
            return true if s == "localhost"

            v4 = IpAddress.parse_ipv4(s)
            return v4.size == 4 && Url.local_ipv4?(v4[0], v4[1])
          end

          b = IpAddress.parse_ipv6(s)
          return false unless b.size == 16
          return true if (b[0] & 0xFE) == 0xFC

          zeros = 0
          zeros += 1 while zeros < 10 && b[zeros] == 0
          return Url.local_ipv4?(b[12], b[13]) if zeros == 10 && b[10] == 255 && b[11] == 255

          zeros += 1 while zeros < 15 && b[zeros] == 0
          zeros == 15 && b[15] == 1
        end

        # 127/8, 10/8, 172.16/12, 192.168/16, from the first two octets.
        def self.local_ipv4?(a, b)
          a == 127 || a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)
        end
      end
    end
  end
end
