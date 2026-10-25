# Cybertrain::Net TLS: the https half of the outbound socket layer.
#
# Required on its own, by an application that makes https requests:
#
#   require "cybertrain/http_client"
#   require "cybertrain/net/tls"
#
# It requires Spinel's openssl package, which links the system libssl and
# libcrypto; cybertrain/net/socket.rb and cybertrain/http_client.rb do not,
# so a program that only speaks plain http (or none) links neither.
# Requiring this file installs {OpenSSLConnector} as {Net.tls_connector}.
#
# What the handshake checks is the openssl package's, which is CRuby's
# `SSLContext#set_params`: VERIFY_PEER against the operating system's trust
# store (SSL_CTX_set_default_verify_paths, so SSL_CERT_FILE / SSL_CERT_DIR
# point it elsewhere), the certificate's name against the host name
# (SSL_set1_host, no partial wildcards), SNI with the same name, and TLS 1.2
# as the floor. The package has no X509::Store, so a custom trust store is
# only those two environment variables. The host name is the URL's, while
# the connection goes to the address it resolved to once: the certificate is
# checked against the name the caller asked for.
#
# Every step is non-blocking (connect_nonblock / read_nonblock /
# write_nonblock with exception: false), and each wait is bounded by the
# exchange's Timer, like the plain TCP layer's.
require "openssl"
require "cybertrain/net/socket"

module Cybertrain
  module Net
    # TLS over a connected {TcpStream}.
    class TlsStream < Stream
      def initialize(tcp, ssl)
        @tcp = tcp
        @ssl = ssl
      end

      def stream_label
        @tcp.stream_label
      end

      # The handshake, one non-blocking step at a time; each wait is in the
      # direction OpenSSL asks for (a handshake needs both).
      def handshake(timer)
        while true
          step = @ssl.connect_nonblock(exception: false)
          if step == :wait_readable
            @tcp.await_readable(timer, "in the TLS handshake")
          elsif step == :wait_writable
            @tcp.await_writable(timer, "in the TLS handshake")
          else
            return nil
          end
        end
        nil
      rescue OpenSSL::SSL::SSLError => e
        raise TlsError, "#{@tcp.stream_label}: TLS handshake failed: #{TlsStream.reason(e.message)}"
      end

      # The openssl package's message without its own "SSL_connect returned
      # an error: TLS handshake failed: " lead, which would repeat ours.
      def self.reason(message)
        text = message.to_s
        lead = "SSL_connect returned an error: "
        text = text.byteslice(lead.bytesize, text.bytesize - lead.bytesize) if text.start_with?(lead)
        again = "TLS handshake failed: "
        text = text.byteslice(again.bytesize, text.bytesize - again.bytesize) if text.start_with?(again)
        text
      end

      # Tries the record layer first: bytes it has already decrypted are not
      # visible as readability on the socket.
      def stream_read(max, timer)
        while true
          got = @ssl.read_nonblock(max, exception: false)
          if got == :wait_readable
            @tcp.await_readable(timer, "reading")
          elsif got == :wait_writable
            @tcp.await_writable(timer, "reading")
          elsif got.nil?
            return ""
          else
            return got.to_s
          end
        end
        ""
      rescue OpenSSL::SSL::SSLError => e
        # A peer that closes without close_notify (common after
        # `Connection: close`) is end of stream, as it is to a browser. A
        # body framed by Content-Length or chunked still has to be complete.
        return "" if e.message.downcase.include?("unexpected eof")

        raise TlsError, "#{@tcp.stream_label}: TLS read failed: #{e.message}"
      rescue SystemCallError, IOError
        raise ConnectError, "#{@tcp.stream_label}: connection reset while reading"
      end

      # OpenSSL wants a write that could not finish retried with the same
      # bytes, so each piece is retried as it is until it goes (without
      # partial-write mode SSL_write sends a piece whole or not at all).
      def stream_write(data, timer)
        s = data.to_s # NOTES rule 62
        total = s.bytesize
        sent = 0
        while sent < total
          size = total - sent
          size = 16_384 if size > 16_384
          piece = s.byteslice(sent, size)
          n = @ssl.write_nonblock(piece, exception: false)
          while n == :wait_writable || n == :wait_readable
            if n == :wait_writable
              @tcp.await_writable(timer, "writing")
            else
              @tcp.await_readable(timer, "writing")
            end
            n = @ssl.write_nonblock(piece, exception: false)
          end
          raise ConnectError, "#{@tcp.stream_label}: the connection closed while writing" if n.nil?

          sent += n.to_i
        end
        nil
      rescue OpenSSL::SSL::SSLError => e
        raise TlsError, "#{@tcp.stream_label}: TLS write failed: #{e.message}"
      rescue SystemCallError, IOError
        raise ConnectError, "#{@tcp.stream_label}: connection reset while writing"
      end

      def stream_close
        @ssl.sysclose
        @tcp.stream_close
        nil
      end
    end

    # The connector that brings TLS: installed as {Net.tls_connector} when
    # this file is required.
    class OpenSSLConnector < TlsConnector
      # @return [Stream] a TlsStream over `tcp`, handshake done. Closes `tcp`
      #   when the handshake fails.
      def tls_wrap(tcp, host, timer)
        context = OpenSSL::SSL::SSLContext.new
        context.set_params # VERIFY_PEER and host-name checking (CRuby's default is VERIFY_NONE)
        ssl = OpenSSL::SSL::SSLSocket.new(tcp.tcp_socket, context)
        ssl.hostname = host.to_s
        ssl.sync_close = false
        stream = TlsStream.new(tcp, ssl)
        begin
          stream.handshake(timer)
        rescue Error => e
          stream.stream_close
          raise e
        end
        stream
      end
    end

    Net.tls_connector = OpenSSLConnector.new
  end
end
