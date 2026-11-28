# The server's initial handshake (Protocol::HandshakeV10), and the text of
# an ERR packet, which a server sends in its place when it refuses the
# connection ("Too many connections") and during authentication.
#
# HandshakeV10: protocol version (1, 10), server version (NUL-terminated),
# connection id (4), scramble part 1 (8), filler (1), capabilities low (2),
# charset (1), status (2), capabilities high (2), auth-data length (1),
# reserved (10), scramble part 2 (max(13, length - 8), its last byte a
# NUL), auth plugin name (NUL-terminated; some servers omit the NUL). The
# scramble is part 1 and the first 12 bytes of part 2: 20 bytes.
require "cybertrain/db/error"
require "cybertrain/db/mysql/wire"
require "cybertrain/db/mysql/result"

module Cybertrain
  module DB
    module MySQL
      # @api private
      class Handshake
        CLIENT_PLUGIN_AUTH = 0x80000

        attr_reader :server_version, :connection_id, :scramble, :capabilities, :auth_plugin

        def initialize(server_version, connection_id, scramble, capabilities, auth_plugin)
          @server_version = server_version
          @connection_id = connection_id
          @scramble = scramble
          @capabilities = capabilities
          @auth_plugin = auth_plugin
        end

        # @param payload [String] the first packet's payload
        # @return [Handshake]
        # @raise [Cybertrain::DB::Error] for an ERR packet (the server's
        #   message), a protocol other than 10, or a cut packet
        def self.parse(payload)
          s = payload.to_s # NOTES rule 62
          raise Cybertrain::DB::Error, "MySQL: the server sent an empty handshake" if s.empty?

          version = s.getbyte(0)
          raise Cybertrain::DB::Error, Handshake.error_text(s) if version == 0xFF
          raise Cybertrain::DB::Error, "MySQL: handshake protocol #{version} is not supported (MySQL 8.0 or newer is needed)" unless version == 10

          got = Wire.null_str(s, 1)
          server_version = got[0]
          pos = got[1]
          connection_id = Wire.read_int_le(s, pos, 4)
          pos += 4
          raise Cybertrain::DB::Error, "MySQL: handshake ends inside the scramble" if pos + 8 > s.bytesize

          scramble = String.new
          scramble << s.byteslice(pos, 8)
          pos += 9 # and the filler
          low = Wire.read_int_le(s, pos, 2)
          pos += 3 # and the charset
          pos += 2 # status
          high = Wire.read_int_le(s, pos, 2)
          pos += 2
          capabilities = low | (high << 16)
          auth_length = Wire.read_int_le(s, pos, 1)
          pos += 11 # and the reserved bytes
          part2 = auth_length - 8
          part2 = 13 if part2 < 13
          raise Cybertrain::DB::Error, "MySQL: handshake ends inside the scramble" if pos + part2 > s.bytesize

          scramble << s.byteslice(pos, 12)
          pos += part2
          plugin = ""
          if (capabilities & CLIENT_PLUGIN_AUTH) != 0 && pos < s.bytesize
            stop = pos
            stop += 1 while stop < s.bytesize && s.getbyte(stop) != 0
            plugin = s.byteslice(pos, stop - pos)
          end
          plugin = "mysql_native_password" if plugin.empty?
          Handshake.new(server_version, connection_id, scramble, capabilities, plugin)
        end

        # "MySQL error CODE (SQLSTATE): message" for an ERR packet's
        # payload; the SQLSTATE is left out when the packet has none (an
        # ERR sent before the handshake). The packet is read as every ERR
        # is (Decode.error_parts, the text marked UTF-8); the shape is the
        # login's own, which `db` commands print as they are, while a
        # statement's error is "text (MySQL CODE, SQLSTATE)"
        # (Decode.server_error_text).
        def self.error_text(payload)
          s = payload.to_s
          return "MySQL: the server sent a short error packet" if s.bytesize < 3

          parts = Decode.error_parts(s)
          return "MySQL error #{parts[0]}: #{parts[2]}" if parts[1].empty?

          "MySQL error #{parts[0]} (#{parts[1]}): #{parts[2]}"
        end
      end
    end
  end
end
