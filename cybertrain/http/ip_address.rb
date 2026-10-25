# Cybertrain::IpAddress -- IPv4 and IPv6 text to bytes, and CIDR matching.
#
# Part of the HTTP layer (it loads alone, script/check-http-layer), so that
# Request#client_ip can ask whether its peer is a configured proxy
# (Request.trusted_proxies); Net::Address, the outbound client's check,
# parses with the same functions.
#
# Byte scans, no IPAddr (not in Spinel's library) and no Regexp. Every
# parameter is read through a `to_s` local (spikes/NOTES.md rule 62).
module Cybertrain
  module IpAddress
    # Integers in one parsed network: the prefix length, counted on the
    # sixteen bytes of the IPv6 form, then those sixteen bytes.
    NETWORK_SIZE = 17

    # The sixteen bytes of `text` as an IPv6 address, an IPv4 address given
    # in its IPv4-mapped form (::ffff:a.b.c.d), or [] when it is neither.
    # A "%zone" suffix is dropped.
    def self.bytes16(text)
      s = text.to_s # NOTES rule 62
      v4 = IpAddress.parse_ipv4(s)
      return IpAddress.parse_ipv6(s) unless v4.size == 4

      out = Array.new(0) { 0 }
      k = 0
      while k < 10
        out << 0
        k += 1
      end
      out << 255 << 255
      out << v4[0] << v4[1] << v4[2] << v4[3]
      out
    end

    # One network from "address" or "address/prefix": [prefix, 16 bytes]
    # (NETWORK_SIZE Integers), or [] when `text` is not one. An IPv4
    # address with a prefix of 0..32 becomes its IPv4-mapped IPv6 network
    # (prefix + 96), so an IPv4-mapped peer (::ffff:172.18.0.2) matches it;
    # an IPv6 prefix is 0..128. No prefix is a single address (/32, /128).
    # Host bits past the prefix are ignored, as IPAddr does. The prefix is
    # one to three decimal digits; nothing else may follow it, and an entry
    # carries no "%zone".
    def self.parse_network(text)
      s = text.to_s # NOTES rule 62
      none = Array.new(0) { 0 }
      n = s.bytesize
      slash = -1
      i = 0
      while i < n
        b = s.getbyte(i)
        return none if b == 37 # "%": a zone belongs on an address, not a network
        return none if b < 0x21 || b > 0x7e

        if b == 47 && slash < 0
          slash = i
        end
        i += 1
      end
      address = slash < 0 ? s : s.byteslice(0, slash).to_s
      v4 = IpAddress.parse_ipv4(address)
      bytes = IpAddress.bytes16(address)
      return none unless bytes.size == 16

      max = v4.size == 4 ? 32 : 128
      prefix = max
      if slash >= 0
        prefix = IpAddress.prefix_length(s, slash + 1)
        return none if prefix < 0 || prefix > max
      end
      prefix += 96 if v4.size == 4
      out = Array.new(0) { 0 }
      out << prefix
      k = 0
      while k < 16
        out << bytes[k]
        k += 1
      end
      out
    end

    # The decimal number from byte `from` to the end of `s` (one to three
    # digits), or -1.
    def self.prefix_length(s, from)
      n = s.bytesize
      return -1 if from >= n || n - from > 3

      value = 0
      i = from
      while i < n
        b = s.getbyte(i)
        return -1 if b < 48 || b > 57

        value = value * 10 + (b - 48)
        i += 1
      end
      value
    end

    # Whether the address `text` lies in one of `networks`: parse_network
    # results laid end to end (NETWORK_SIZE Integers each). False for text
    # that is not an address ("" included) and for an empty list.
    def self.in_networks?(text, networks)
      return false if networks.empty?

      bytes = IpAddress.bytes16(text)
      return false unless bytes.size == 16

      at = 0
      while at + NETWORK_SIZE <= networks.size
        return true if IpAddress.prefix_match?(bytes, networks, at)

        at += NETWORK_SIZE
      end
      false
    end

    # Whether the first networks[at] bits of `bytes` equal those of the
    # network's bytes, which start at networks[at + 1].
    def self.prefix_match?(bytes, networks, at)
      bits = networks[at]
      k = 0
      while bits >= 8
        return false if bytes[k] != networks[at + 1 + k]

        k += 1
        bits -= 8
      end
      return true if bits == 0

      mask = (255 << (8 - bits)) & 255
      (bytes[k] & mask) == (networks[at + 1 + k] & mask)
    end

    # The four bytes of a dotted-quad IPv4 address, or [] when `text` is
    # not exactly four decimal parts of 0..255 (no leading zeros past one
    # digit, no other spellings: getaddrinfo answers the canonical form).
    def self.parse_ipv4(text)
      s = text.to_s # NOTES rule 62
      out = Array.new(0) { 0 }
      n = s.bytesize
      i = 0
      value = 0
      digits = 0
      while i <= n
        b = i < n ? s.getbyte(i) : 46 # a final "." closes the last part
        if b >= 48 && b <= 57
          return Array.new(0) { 0 } if digits == 3 || (digits == 1 && value == 0)

          value = value * 10 + (b - 48)
          digits += 1
        elsif b == 46
          return Array.new(0) { 0 } if digits == 0 || value > 255 || out.size == 4

          out << value
          value = 0
          digits = 0
        else
          return Array.new(0) { 0 }
        end
        i += 1
      end
      out.size == 4 ? out : Array.new(0) { 0 }
    end

    # The sixteen bytes of an IPv6 address, or [] when `text` is not one.
    # Accepts "::" compression, a trailing dotted IPv4 part
    # ("::ffff:10.0.0.1") and a "%zone" suffix, which is dropped (a zoned
    # address is link-local anyway).
    def self.parse_ipv6(text)
      s = text.to_s # NOTES rule 62
      zone = s.byteindex("%")
      s = s.byteslice(0, zone) unless zone.nil?
      none = Array.new(0) { 0 }
      n = s.bytesize
      return none if n < 2

      head = Array.new(0) { 0 } # 16-bit groups before "::"
      tail = Array.new(0) { 0 } # and after it
      gap = false
      i = 0
      if s.getbyte(0) == 58
        return none unless s.getbyte(1) == 58

        gap = true
        i = 2
      end
      while i < n
        # one group: hex digits up to ":" or the end, or a dotted IPv4 tail
        start = i
        value = 0
        while i < n
          b = s.getbyte(i)
          d = IpAddress.hex_value(b)
          break if d < 0

          value = value * 16 + d
          i += 1
        end
        if i < n && s.getbyte(i) == 46
          # the last 32 bits as dotted IPv4
          v4 = IpAddress.parse_ipv4(s.byteslice(start, n - start))
          return none unless v4.size == 4

          groups = gap ? tail : head
          groups << (v4[0] * 256 + v4[1])
          groups << (v4[2] * 256 + v4[3])
          i = n
          break
        end
        return none if i == start || i - start > 4

        (gap ? tail : head) << value
        break if i == n
        return none unless s.getbyte(i) == 58

        i += 1
        if i < n && s.getbyte(i) == 58
          return none if gap

          gap = true
          i += 1
        elsif i == n
          return none # a trailing single ":"
        end
      end
      total = head.size + tail.size
      return none if total > 8 || (!gap && total != 8) || (gap && total > 7)

      out = Array.new(0) { 0 }
      IpAddress.push_groups(out, head)
      (8 - total).times { out << 0 << 0 } if gap
      IpAddress.push_groups(out, tail)
      out
    end

    def self.push_groups(out, groups)
      j = 0
      while j < groups.size
        out << (groups[j] >> 8)
        out << (groups[j] & 255)
        j += 1
      end
      nil
    end

    # 0..15 for an ASCII hex digit, -1 otherwise.
    def self.hex_value(b)
      return b - 48 if b >= 48 && b <= 57
      return b - 87 if b >= 97 && b <= 102
      return b - 55 if b >= 65 && b <= 70

      -1
    end
  end
end
