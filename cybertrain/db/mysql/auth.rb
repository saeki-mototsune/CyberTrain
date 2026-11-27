# MySQL authentication: the client's half of the connection phase after the
# server's handshake (handshake.rb) has been read.
#
# - ssl_mode=verify: an SSL Request (capabilities with CLIENT_SSL, max
#   packet, charset, 23 zero bytes) goes out in plain text, then the
#   stream becomes TLS (see {TlsUpgrade}) and everything else, credentials
#   included, goes over TLS. A server that does not offer TLS is refused
#   before anything is sent.
# - HandshakeResponse41: capabilities (4), max packet (4), charset (1), 23
#   zero bytes, user (NUL-terminated), the auth response
#   (length-encoded: CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA), the database
#   (NUL-terminated, only with CLIENT_CONNECT_WITH_DB, which is set only
#   when the URL names one), the plugin name (NUL-terminated).
# - Then the server answers: OK (done), ERR (a DB::Error with the server's
#   message), an auth switch (0xFE: answer the named plugin with its new
#   scramble, once), or caching_sha2_password's more-data packet: 0x01
#   0x03 is the fast path (an OK follows), 0x01 0x04 asks for the
#   password itself, which is sent (with a NUL) only over TLS; without TLS
#   it is a DB::Error, never the RSA key exchange.
#
# No message here holds the password, the scramble or the URL.
require "digest"
require "cybertrain/db/error"
require "cybertrain/db/mysql/wire"
require "cybertrain/db/mysql/packet"
require "cybertrain/db/mysql/url"
require "cybertrain/db/mysql/handshake"

module Cybertrain
  module DB
    module MySQL
      # What turns the connection into TLS after the SSL Request: given the
      # PacketIO over the plain stream, it returns a PacketIO over the TLS
      # stream (the handshake done, the certificate verified). Auth carries
      # the sequence number over, so an implementation only wraps.
      #
      # An object and a method rather than a lambda: a subclass that holds
      # what the upgrade needs (the TcpStream, the host name to verify, the
      # timeouts) and overrides {#mysql_tls_upgrade}, as Net::TlsConnector
      # is subclassed by the openssl connector. This base is the stub the
      # call dispatches through (spikes/NOTES.md rules 3 and 34: the same
      # PacketIO return type) and refuses, so a caller that forgets to pass
      # a real one fails before any credential is sent.
      #
      # {Auth.handshake} answers nil, so the connection takes the PacketIO
      # over TLS from its subclass, which keeps the one it made (a PacketIO
      # answer would put a second return type on the name `handshake`,
      # beside Net::TlsStream#handshake's nil: NOTES rule 34).
      # @api private
      class TlsUpgrade
        # @param io [PacketIO] the plain connection, the SSL Request sent
        # @return [PacketIO] over TLS
        def mysql_tls_upgrade(io)
          raise Cybertrain::DB::Error, "MySQL: no TLS upgrade was given for ssl_mode=verify" unless io.nil?

          io
        end
      end

      # @api private
      module Auth
        CLIENT_FOUND_ROWS = 0x2
        CLIENT_CONNECT_WITH_DB = 0x8
        CLIENT_PROTOCOL_41 = 0x200
        CLIENT_SSL = 0x800
        CLIENT_TRANSACTIONS = 0x2000
        CLIENT_SECURE_CONNECTION = 0x8000
        CLIENT_MULTI_STATEMENTS = 0x10000
        CLIENT_MULTI_RESULTS = 0x20000
        CLIENT_PS_MULTI_RESULTS = 0x40000
        CLIENT_PLUGIN_AUTH = 0x80000
        CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA = 0x200000
        CLIENT_DEPRECATE_EOF = 0x1000000

        # Every capability the client asks for, CLIENT_SSL and
        # CLIENT_CONNECT_WITH_DB aside (each added when it applies).
        CLIENT_FLAGS = CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH |
                       CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA | CLIENT_MULTI_STATEMENTS | CLIENT_MULTI_RESULTS |
                       CLIENT_PS_MULTI_RESULTS | CLIENT_FOUND_ROWS | CLIENT_TRANSACTIONS | CLIENT_DEPRECATE_EOF
        # The ones the rest of the driver relies on: a server without them
        # is refused.
        REQUIRED_FLAGS = CLIENT_PROTOCOL_41 | CLIENT_SECURE_CONNECTION | CLIENT_PLUGIN_AUTH |
                         CLIENT_PLUGIN_AUTH_LENENC_CLIENT_DATA | CLIENT_DEPRECATE_EOF
        MAX_PACKET = 0x1000000
        # utf8mb4_0900_ai_ci: the connection's character set is utf8mb4. The
        # collation the driver compares with, utf8mb4_0900_bin, is set by the
        # session and the columns (one byte here cannot name it: it is 309).
        CHARSET = 255
        NATIVE = "mysql_native_password"
        CACHING_SHA2 = "caching_sha2_password"

        # SHA1(pw) XOR SHA1(scramble + SHA1(SHA1(pw))); "" for no password.
        def self.native_password(password, scramble)
          pw = password.to_s
          return "" if pw.empty?

          stage1 = Digest::SHA1.digest(pw)
          salted = Wire.bytes(scramble)
          salted << Wire.bytes(Digest::SHA1.digest(stage1))
          Auth.xor_bytes(stage1, Digest::SHA1.digest(salted))
        end

        # SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + scramble); "" for no
        # password.
        def self.caching_sha2(password, scramble)
          pw = password.to_s
          return "" if pw.empty?

          stage1 = Digest::SHA256.digest(pw)
          salted = Wire.bytes(Digest::SHA256.digest(stage1))
          salted << Wire.bytes(scramble)
          Auth.xor_bytes(stage1, Digest::SHA256.digest(salted))
        end

        # Byte by byte; both the same size.
        def self.xor_bytes(left, right)
          a = left.to_s
          b = right.to_s
          out = Wire.zeros(a.bytesize)
          i = 0
          while i < a.bytesize
            out.setbyte(i, a.getbyte(i) ^ b.getbyte(i))
            i += 1
          end
          out
        end

        # Authenticates on `io`, whose handshake has been read and parsed
        # into `handshake`.
        # @param io [PacketIO]
        # @param url [Url]
        # @param handshake [Handshake]
        # @param tls_wrap [TlsUpgrade] used only for ssl_mode=verify
        # @return [nil] with ssl_mode=verify the connection goes on over
        #   the PacketIO `tls_wrap` made (see {TlsUpgrade}), else over `io`
        # @raise [Cybertrain::DB::Error]
        def self.handshake(io, url, handshake, tls_wrap)
          label = url.server_label
          server = handshake.capabilities
          if (server & REQUIRED_FLAGS) != REQUIRED_FLAGS
            raise Cybertrain::DB::Error, "#{label}: the MySQL server lacks protocol 4.1 authentication or CLIENT_DEPRECATE_EOF; MySQL 8.0 or newer is needed"
          end

          flags = CLIENT_FLAGS & server
          flags |= CLIENT_CONNECT_WITH_DB unless url.database.empty?
          secure = url.ssl_mode == "verify"
          conn = io
          if secure
            raise Cybertrain::DB::Error, "#{label}: the MySQL server does not offer TLS, which ssl_mode=verify needs" if (server & CLIENT_SSL) == 0

            flags |= CLIENT_SSL
            io.write_packet(Auth.response_head(flags))
            conn = tls_wrap.mysql_tls_upgrade(io)
            conn.resume_sequence(io.packet_sequence)
          end

          plugin = handshake.auth_plugin
          plugin = CACHING_SHA2 unless plugin == NATIVE
          conn.write_packet(Auth.handshake_response(flags, url, plugin, handshake.scramble))
          Auth.await_ok(conn, url, plugin, secure)
        end

        # Capabilities, max packet, charset and the 23 reserved bytes: the
        # SSL Request whole, and the start of HandshakeResponse41.
        def self.response_head(flags)
          out = Wire.int_le(flags, 4)
          out << Wire.int_le(MAX_PACKET, 4)
          out << Wire.int_le(CHARSET, 1)
          out << Wire.zeros(23)
          out
        end

        def self.handshake_response(flags, url, plugin, scramble)
          out = Auth.response_head(flags)
          out << Wire.bytes(url.url_user)
          out << "\0"
          out << Wire.lenenc_str(Auth.scrambled(plugin, url.url_password, scramble))
          unless url.database.empty?
            out << Wire.bytes(url.database)
            out << "\0"
          end
          out << Wire.bytes(plugin)
          out << "\0"
          out
        end

        def self.scrambled(plugin, password, scramble)
          return Auth.native_password(password, scramble) if plugin == NATIVE

          Auth.caching_sha2(password, scramble)
        end

        # Reads the server's answers until OK. `secure` says the stream is
        # TLS, where caching_sha2_password's full authentication may send
        # the password.
        def self.await_ok(conn, url, first_plugin, secure)
          label = url.server_label
          plugin = first_plugin
          switched = false
          while true
            packet = conn.read_packet
            raise Cybertrain::DB::Error, "#{label}: the MySQL server sent an empty packet during authentication" if packet.empty?

            kind = packet.getbyte(0)
            return nil if kind == 0x00
            raise Cybertrain::DB::Error, "#{label}: #{Handshake.error_text(packet)}" if kind == 0xFF

            if kind == 0xFE
              raise Cybertrain::DB::Error, "#{label}: MySQL switched the authentication plugin twice" if switched

              switched = true
              raise Cybertrain::DB::Error, "#{label}: MySQL asked for the pre-4.1 password authentication, which is not supported" if packet.bytesize == 1

              got = Wire.null_str(packet, 1)
              plugin = got[0]
              unless plugin == NATIVE || plugin == CACHING_SHA2
                raise Cybertrain::DB::Error, "#{label}: MySQL asked for the authentication plugin '#{plugin}', which is not supported (#{NATIVE}, #{CACHING_SHA2})"
              end

              data = packet.byteslice(got[1], packet.bytesize - got[1])
              data = data.byteslice(0, data.bytesize - 1) if data.bytesize > 0 && data.getbyte(data.bytesize - 1) == 0
              conn.write_packet(Auth.scrambled(plugin, url.url_password, data))
            elsif kind == 0x01 && plugin == CACHING_SHA2 && packet.bytesize == 2 && packet.getbyte(1) == 0x03
              nil # fast authentication succeeded; the OK follows
            elsif kind == 0x01 && plugin == CACHING_SHA2 && packet.bytesize == 2 && packet.getbyte(1) == 0x04
              raise Cybertrain::DB::Error, "caching_sha2_password full authentication needs TLS (ssl_mode=verify)" unless secure

              clear = Wire.bytes(url.url_password)
              clear << Wire.zeros(1)
              conn.write_packet(clear)
            else
              shown = "0x#{(kind + 256).to_s(16).byteslice(1, 2)}"
              shown = "#{shown} 0x#{(packet.getbyte(1) + 256).to_s(16).byteslice(1, 2)}" if packet.bytesize > 1
              raise Cybertrain::DB::Error, "#{label}: unexpected MySQL packet #{shown} during authentication"
            end
          end
        end
      end
    end
  end
end
