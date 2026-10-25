# Cybertrain::Net::Address -- is a resolved IP address one an outbound
# request may reach?
#
# The outbound HTTP client (cybertrain/http_client.rb) resolves a host name
# once, asks this module about each address it got, and dials those it may.
# A webhook URL is often typed in by a user, so without this check it is a
# way into the server's own network: http://127.0.0.1:6379/, the cloud
# metadata service at 169.254.169.254, a database on 10.0.0.5. The check
# runs on the address, not on the name, so a name that resolves to a
# private address (an /etc/hosts entry, a DNS-rebinding record) is refused
# like the literal.
#
# Byte scans, no IPAddr (not in Spinel's library) and no Regexp. Every
# parameter is read through a `to_s` local (spikes/NOTES.md rule 62). The
# parsing itself is Cybertrain::IpAddress (cybertrain/http/ip_address.rb).
require "cybertrain/http/ip_address"

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

      # The four bytes of a dotted-quad IPv4 address, or [] (IpAddress, the
      # HTTP layer's parser, which Request#client_ip uses too).
      def self.parse_ipv4(text)
        IpAddress.parse_ipv4(text)
      end

      # The sixteen bytes of an IPv6 address, or [] (IpAddress.parse_ipv6:
      # "::" compression, a dotted IPv4 tail, a "%zone" suffix dropped).
      def self.parse_ipv6(text)
        IpAddress.parse_ipv6(text)
      end

      # 0..15 for an ASCII hex digit, -1 otherwise.
      def self.hex_value(b)
        IpAddress.hex_value(b)
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
