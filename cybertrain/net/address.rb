# Cybertrain::Net::Address -- is a resolved IP address one an outbound
# request may reach?
#
# The outbound HTTP client (cybertrain/http_client.rb) resolves a host name
# once, asks this module about the address it got, and dials that address.
# A webhook URL is often typed in by a user, so without this check it is a
# way into the server's own network: http://127.0.0.1:6379/, the cloud
# metadata service at 169.254.169.254, a database on 10.0.0.5. The check
# runs on the address, not on the name, so a name that resolves to a
# private address (an /etc/hosts entry, a DNS-rebinding record) is refused
# like the literal.
#
# Byte scans, no IPAddr (not in Spinel's library) and no Regexp. Every
# parameter is read through a `to_s` local (spikes/NOTES.md rule 62).
module Cybertrain
  module Net
    module Address
      # The reason an outbound request must not reach `ip`, or "" when it is
      # a public address. `ip` is what getaddrinfo answers: dotted IPv4
      # ("10.0.0.5") or IPv6 text ("fe80::1%eth0", "::ffff:127.0.0.1"). A
      # String that parses as neither is refused ("not an IP address").
      # @param ip [String]
      # @return [String] "" when public; else e.g. "loopback", "private"
      # @api public
      def self.blocked_reason(ip)
        text = ip.to_s # NOTES rule 62
        v4 = Address.parse_ipv4(text)
        return Address.ipv4_reason(v4) if v4.size == 4

        v6 = Address.parse_ipv6(text)
        return Address.ipv6_reason(v6) if v6.size == 16

        "not an IP address"
      end

      # True when `ip` is a public address (blocked_reason is "").
      # @param ip [String]
      # @return [Boolean]
      # @api public
      def self.public?(ip)
        Address.blocked_reason(ip).empty?
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
            d = Address.hex_value(b)
            break if d < 0

            value = value * 16 + d
            i += 1
          end
          if i < n && s.getbyte(i) == 46
            # the last 32 bits as dotted IPv4
            v4 = Address.parse_ipv4(s.byteslice(start, n - start))
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
        Address.push_groups(out, head)
        (8 - total).times { out << 0 << 0 } if gap
        Address.push_groups(out, tail)
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

      # The ranges IANA's special-purpose registry lists as not globally
      # reachable, plus multicast and the limited broadcast address.
      def self.ipv4_reason(b)
        a = b[0]
        c = b[1]
        return "unspecified" if a == 0
        return "private" if a == 10
        return "shared address space" if a == 100 && c >= 64 && c <= 127
        return "loopback" if a == 127
        return "link-local" if a == 169 && c == 254
        return "private" if a == 172 && c >= 16 && c <= 31
        return "reserved" if a == 192 && c == 0 && b[2] == 0
        return "documentation" if a == 192 && c == 0 && b[2] == 2
        return "private" if a == 192 && c == 168
        return "benchmarking" if a == 198 && (c == 18 || c == 19)
        return "documentation" if a == 198 && c == 51 && b[2] == 100
        return "documentation" if a == 203 && c == 0 && b[2] == 113
        return "multicast" if a >= 224 && a <= 239
        return "broadcast" if a == 255 && c == 255 && b[2] == 255 && b[3] == 255
        return "reserved" if a >= 240

        ""
      end

      def self.ipv6_reason(b)
        zero_prefix = true # the first 80 bits are zero
        k = 0
        while k < 10
          zero_prefix = false if b[k] != 0
          k += 1
        end
        if zero_prefix
          if b[10] == 255 && b[11] == 255
            # IPv4-mapped (::ffff:a.b.c.d): what the IPv4 address is
            return Address.ipv4_reason(Address.embedded_v4(b, 12))
          end
          rest = 0
          k = 10
          while k < 15
            rest |= b[k]
            k += 1
          end
          return "unspecified" if rest == 0 && b[15] == 0
          return "loopback" if rest == 0 && b[15] == 1

          return "reserved" # IPv4-compatible (::a.b.c.d), deprecated
        end
        # NAT64 (64:ff9b::/96) and 6to4 (2002::/16) carry an IPv4 address
        if b[0] == 0 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b && Address.zero_bytes?(b, 4, 12)
          return Address.ipv4_reason(Address.embedded_v4(b, 12))
        end
        return Address.ipv4_reason(Address.embedded_v4(b, 2)) if b[0] == 0x20 && b[1] == 0x02
        return "private" if (b[0] & 0xfe) == 0xfc # fc00::/7 unique local
        return "link-local" if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 # fe80::/10
        return "private" if b[0] == 0xfe && (b[1] & 0xc0) == 0xc0 # fec0::/10 site-local
        return "multicast" if b[0] == 0xff
        return "documentation" if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8
        return "reserved" if b[0] == 0x01 && b[1] == 0 && Address.zero_bytes?(b, 2, 8) # 100::/64 discard

        ""
      end

      def self.embedded_v4(b, at)
        out = Array.new(0) { 0 }
        out << b[at] << b[at + 1] << b[at + 2] << b[at + 3]
        out
      end

      def self.zero_bytes?(b, from, upto)
        k = from
        while k < upto
          return false if b[k] != 0
          k += 1
        end
        true
      end
    end
  end
end
