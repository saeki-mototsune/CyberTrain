# Cybertrain::Net -- outbound TCP with every wait bounded.
#
# The socket layer under Cybertrain::HttpClient (and under anything else
# that talks to another server: a mailer needs the same). Under Spinel a
# blocking socket call holds an OS worker, and with the default
# SPINEL_WORKERS=1 that is the whole web server, so nothing here blocks:
#
# - connect is Socket#connect_nonblock + wait_writable(timeout), then
#   SO_ERROR (TCPSocket.new ignores connect_timeout: under Spinel);
# - every read is read_nonblock first and wait_readable(timeout) only when
#   it answers :wait_readable, so bytes already buffered (stdio's, or the TLS
#   record layer's) are never waited for (IO#gets buffers bytes a later
#   wait_readable does not see);
# - every write is write_nonblock + wait_writable(timeout);
# - every wait is bounded by the per-wait timeout and by the overall
#   deadline of the request ({Timer}).
#
# Name resolution (Socket.getaddrinfo) is the one blocking call left: the
# runtime has no asynchronous resolver. It is done once per request, and the
# address it answers is the one dialled (see {Net.resolve}).
#
# TLS is a separate file, cybertrain/net/tls.rb, which requires Spinel's
# openssl package; this file does not, so a program that never makes an
# https request does not link libssl. Requiring that file installs its
# connector in {Net.tls_connector}.
#
# Method names here are distinctive (`stream_read`, not `read`): a method
# named like a builtin changes how every call of that name on a boxed
# receiver compiles (spikes/NOTES.md rule 62).
require "socket"
require "cybertrain/net/address"

module Cybertrain
  module Net
    # The base of everything this layer raises. Messages name the host and
    # port ("example.com:443"), never a path or a query, which is where a
    # webhook URL carries its secret.
    class Error < StandardError
    end

    # A wait ran past the per-wait timeout or the request's deadline.
    class TimeoutError < Error
    end

    # The connection could not be made (refused, unreachable, the name did
    # not resolve) or was reset.
    class ConnectError < Error
    end

    # The TLS handshake or a TLS read or write failed, including a
    # certificate that does not verify.
    class TlsError < Error
    end

    # The address is not a public one and private destinations are not
    # allowed ({Address.blocked_reason}).
    class BlockedError < Error
    end

    # A line from the peer was longer than the reader allows, or the data
    # past a limit.
    class LimitError < Error
    end

    # The peer closed the connection early, or sent bytes that do not frame.
    class ProtocolError < Error
    end

    # The clock for one exchange: a per-wait timeout and an overall deadline,
    # both in seconds, measured on the monotonic clock.
    class Timer
      attr_reader :timer_label

      # @param label [String] "host:port", for error messages
      # @param per_wait [Numeric] the longest any single wait may take
      # @param deadline [Numeric] the longest the whole exchange may take
      def initialize(label, per_wait, deadline)
        @timer_label = label
        @per_wait = per_wait.to_f
        @deadline_seconds = deadline.to_f
        @ends_at = Timer.now + @deadline_seconds
      end

      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Seconds left before the deadline (0.0 or less once it has passed).
      def remaining
        @ends_at - Timer.now
      end

      # How long the next wait may take: the per-wait timeout, or less when
      # the deadline is nearer. Raises TimeoutError once the deadline has
      # passed. `step` says what is being waited for, for the message.
      def wait_limit(step)
        left = remaining
        deadline_passed!(step) if left <= 0.0
        left < @per_wait ? left : @per_wait
      end

      # Raises the TimeoutError for a wait of `limit` seconds that ended with
      # nothing ready.
      def timed_out!(step, limit)
        deadline_passed!(step) if limit < @per_wait
        raise TimeoutError, "#{@timer_label}: #{step} timed out after #{Timer.seconds(@per_wait)}"
      end

      def deadline_passed!(step)
        raise TimeoutError, "#{@timer_label}: the #{Timer.seconds(@deadline_seconds)} deadline passed while #{step}"
      end

      # "5s", "0.25s".
      def self.seconds(value)
        whole = value.to_i
        return "#{whole}s" if value == whole.to_f

        "#{value.round(3)}s"
      end
    end

    # Where a name resolved to: the first stream address getaddrinfo answered.
    class Endpoint
      attr_reader :endpoint_ip, :endpoint_family

      def initialize
        @endpoint_ip = ""
        @endpoint_family = 0
      end

      # Keeps the first address offered.
      def offer(ip, family)
        return nil unless @endpoint_ip.empty?

        @endpoint_ip = ip
        @endpoint_family = family
        nil
      end

      def found?
        !@endpoint_ip.empty?
      end
    end

    # Resolves `host` (a name or an IP literal, without brackets) once.
    # Blocking: getaddrinfo has no non-blocking form in the runtime. Raises
    # ConnectError when nothing resolves.
    # @return [Endpoint]
    def self.resolve(host, port, label)
      found = Endpoint.new
      Net.collect_addresses(host.to_s, port, found)
      raise ConnectError, "#{label}: could not resolve the host name" unless found.found?

      found
    end

    # The begin/rescue lives here, away from any block-taking caller
    # (spikes/NOTES.md rules 32 and 45). CRuby raises SocketError for a name
    # that does not resolve; Spinel answers an empty list.
    def self.collect_addresses(host, port, found)
      list = Socket.getaddrinfo(host, port)
      list.each do |_family_name, _port, _name, ip, family, socktype, _protocol|
        found.offer(ip.to_s, family.to_i) if socktype.to_i == Socket::SOCK_STREAM
      end
      nil
    rescue SocketError
      nil
    end

    # Errno numbers a connect can end with, Linux's and the BSDs' (macOS),
    # which do not overlap for these. The runtime's SystemCallError has no
    # strerror text, so the message is spelled out here.
    CONNECT_ERRORS = {
      111 => "connection refused", 61 => "connection refused",
      110 => "connection timed out", 60 => "connection timed out",
      113 => "no route to host", 65 => "no route to host",
      101 => "network unreachable", 51 => "network unreachable",
      104 => "connection reset", 54 => "connection reset"
    }

    def self.errno_text(code)
      text = CONNECT_ERRORS[code]
      text.nil? ? "connection failed (errno #{code})" : text
    end

    # A byte stream to a peer: plain TCP ({TcpStream}) or TLS over it
    # (TlsStream, cybertrain/net/tls.rb).
    class Stream
      # Up to `max` bytes, waiting (bounded by `timer`) until some arrive.
      # "" at end of stream.
      def stream_read(max, timer)
        ""
      end

      # Writes all of `data`, each wait bounded by `timer`.
      def stream_write(data, timer)
        nil
      end

      # Closes the connection; safe to call twice.
      def stream_close
        nil
      end

      def stream_label
        ""
      end
    end

    # A connected TCP socket, opened with a bounded, non-blocking connect.
    class TcpStream < Stream
      attr_reader :tcp_socket

      # Dials `endpoint` (an already resolved address) within the timer's
      # per-wait timeout. Raises TimeoutError or ConnectError.
      # @return [TcpStream]
      def self.connect_to(endpoint, port, label, timer)
        sock = TcpStream.start_connect(endpoint, port, label)
        stream = TcpStream.new(sock, label)
        stream.finish_connect(endpoint, port, timer)
        stream
      end

      def self.start_connect(endpoint, port, label)
        sock = TcpStream.new_socket(endpoint.endpoint_family, label)
        begin
          sock.connect_nonblock(Socket.sockaddr_in(port, endpoint.endpoint_ip), exception: false)
        rescue SystemCallError
          sock.close
          raise ConnectError, "#{label}: connection failed"
        end
        sock
      end

      # A host without IPv6 refuses an AF_INET6 socket (EAFNOSUPPORT).
      def self.new_socket(family, label)
        Socket.new(family, Socket::SOCK_STREAM, 0)
      rescue SystemCallError
        raise ConnectError, "#{label}: cannot open a socket for this address family"
      end

      def initialize(sock, label)
        @tcp_socket = sock
        @label = label
      end

      def stream_label
        @label
      end

      # Waits for the non-blocking connect to finish and checks how it ended
      # (SO_ERROR): a second connect_nonblock would answer EISCONN under CRuby
      # and a bare SystemCallError under Spinel, the option the same on both.
      def finish_connect(endpoint, port, timer)
        limit = timer.wait_limit("connecting")
        if @tcp_socket.wait_writable(limit).nil?
          stream_close
          timer.timed_out!("connecting", limit)
        end
        code = @tcp_socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
        if code != 0
          stream_close
          raise ConnectError, "#{@label}: #{Net.errno_text(code)}"
        end
        nil
      end

      # Parks until the socket is readable, at most the timer's next limit.
      def await_readable(timer, step)
        limit = timer.wait_limit(step)
        timer.timed_out!(step, limit) if @tcp_socket.wait_readable(limit).nil?
        nil
      end

      def await_writable(timer, step)
        limit = timer.wait_limit(step)
        timer.timed_out!(step, limit) if @tcp_socket.wait_writable(limit).nil?
        nil
      end

      def stream_read(max, timer)
        while true
          got = @tcp_socket.read_nonblock(max, exception: false)
          if got == :wait_readable
            await_readable(timer, "reading")
          elsif got.nil?
            return ""
          else
            return got.to_s
          end
        end
        ""
      rescue SystemCallError, IOError
        raise ConnectError, "#{@label}: connection reset while reading"
      end

      def stream_write(data, timer)
        s = data.to_s # NOTES rule 62
        total = s.bytesize
        sent = 0
        while sent < total
          piece = sent == 0 ? s : s.byteslice(sent, total - sent)
          n = @tcp_socket.write_nonblock(piece, exception: false)
          if n == :wait_writable
            await_writable(timer, "writing")
          else
            sent += n.to_i
          end
        end
        nil
      rescue SystemCallError, IOError
        raise ConnectError, "#{@label}: connection reset while writing"
      end

      def stream_close
        @tcp_socket.close unless @tcp_socket.closed?
        nil
      end
    end

    # What turns a TcpStream into a TLS stream. This one has no TLS: it
    # raises, naming the file that brings it. Requiring cybertrain/net/tls
    # replaces it ({Net.tls_connector=}).
    class TlsConnector
      # False here, true once cybertrain/net/tls is required: lets a caller
      # that will need TLS later in an exchange (the mailer's STARTTLS)
      # refuse before it connects.
      def tls_ready?
        false
      end

      # @return [Stream] the TLS stream over `tcp`, handshake done
      def tls_wrap(tcp, host, timer)
        tcp.stream_close
        raise TlsError, "#{tcp.stream_label}: https needs the TLS layer: require \"cybertrain/net/tls\" (Spinel's openssl package)" unless tcp.nil?

        # Not reached; gives the method the Stream return type the TLS
        # connector's override has (spikes/NOTES.md rule 34).
        tcp
      end
    end

    # Module-level ivar, not a class variable (spikes/NOTES.md rules 18, 64).
    @tls_connector = TlsConnector.new

    # The connector https requests use.
    # @return [TlsConnector]
    def self.tls_connector
      @tls_connector
    end

    def self.tls_connector=(connector)
      @tls_connector = connector
    end

    # Bytes from a Stream, buffered, read by line or by count. One buffer
    # and a read offset into it: consumed bytes are dropped only when they
    # are most of the buffer, so reading a body costs no copy per line.
    class Reader
      def initialize(stream, timer)
        @stream = stream
        @timer = timer
        # String.new, not +"": binary under CRuby, so byteindex never meets
        # a UTF-8 character boundary check (NOTES rule 52).
        @rbuf = String.new
        @rpos = 0
        @at_eof = false
      end

      # Bytes buffered and not yet consumed.
      def buffered
        @rbuf.bytesize - @rpos
      end

      # Reads more into the buffer. False at end of stream.
      def fill_more
        return false if @at_eof

        chunk = @stream.stream_read(16_384, @timer)
        if chunk.empty?
          @at_eof = true
          return false
        end
        if @rpos > 0 && @rpos * 2 >= @rbuf.bytesize
          rest = @rbuf.byteslice(@rpos, @rbuf.bytesize - @rpos)
          @rbuf = String.new
          @rbuf << rest
          @rpos = 0
        end
        @rbuf << chunk
        true
      end

      # One line without its LF (and CR before it). Raises LimitError past
      # `max` bytes, ProtocolError when the stream ends first.
      def read_line(max)
        while true
          idx = @rbuf.byteindex("\n", @rpos)
          unless idx.nil?
            stop = idx
            stop -= 1 if stop > @rpos && @rbuf.getbyte(stop - 1) == 13
            raise LimitError, "#{@stream.stream_label}: a line longer than #{max} bytes" if stop - @rpos > max

            line = @rbuf.byteslice(@rpos, stop - @rpos)
            @rpos = idx + 1
            return line
          end
          raise LimitError, "#{@stream.stream_label}: a line longer than #{max} bytes" if buffered > max + 1
          raise ProtocolError, "#{@stream.stream_label}: the connection closed mid-line" unless fill_more
        end
        ""
      end

      # Exactly `count` bytes. Raises ProtocolError when the stream ends first.
      def read_exact(count)
        while buffered < count
          raise ProtocolError, "#{@stream.stream_label}: the connection closed before the body was complete" unless fill_more
        end
        out = @rbuf.byteslice(@rpos, count)
        @rpos += count
        out
      end

      # Everything to the end of the stream. Raises LimitError past `max`.
      def read_rest(max)
        while fill_more
          raise LimitError, "#{@stream.stream_label}: more than #{max} bytes" if buffered > max
        end
        raise LimitError, "#{@stream.stream_label}: more than #{max} bytes" if buffered > max

        out = @rbuf.byteslice(@rpos, buffered)
        @rpos = @rbuf.bytesize
        out
      end
    end
  end
end
