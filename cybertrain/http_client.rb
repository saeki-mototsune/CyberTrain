# Cybertrain::HttpClient -- outbound HTTP/1.1 requests with every wait
# bounded: a webhook, a Slack incoming webhook, a third-party API.
#
# Spinel's Net::HTTP does the TLS handshake and every read after the first
# byte as blocking C calls, each holding an OS worker (with the default
# SPINEL_WORKERS=1, the whole web server) for as long as a stalled peer
# likes. This client is built on cybertrain/net/socket.rb instead, where
# connect, each TLS step, each read and each write waits at most `timeout`
# seconds and the whole request at most `deadline` seconds.
#
# Deliberately small, a notification client and not a browser: HTTP/1.1
# with `Connection: close` (one connection per request, no keep-alive), no
# redirects (a 3xx is returned as it is), no proxy, no cookies, no
# compression. https needs `require "cybertrain/net/tls"` as well (see that
# file: it links libssl, which a plain-http program need not).
#
# Destinations that are not public (loopback, private, link-local, ...;
# Net::Address) are refused unless Config#http_allow_private is on. The host
# name is resolved once and the addresses it resolved to are checked and
# dialled (in order, the next when one refuses), never looked up again, so a
# name that resolves to a private address is refused like the literal.
# Resolution itself
# (getaddrinfo) blocks the calling thread: the runtime has no asynchronous
# resolver; the deadline is checked after it.
#
# Errors name the host and port, never the path or the query: a webhook
# URL carries its secret there.
require "cybertrain/version"
require "cybertrain/config"
require "cybertrain/net/socket"

module Cybertrain
  # Sends GET and POST requests to other servers, with bounded waits.
  # @example A Slack incoming webhook
  #   require "cybertrain/http_client"
  #   require "cybertrain/net/tls"
  #
  #   client = Cybertrain::HttpClient.new(timeout: 5, deadline: 15)
  #   begin
  #     res = client.post(ENV["SLACK_WEBHOOK_URL"], JSON.generate({ "text" => "Deployed" }),
  #                       content_type: "application/json")
  #     Cybertrain.logger.warn("slack answered #{res.status}") unless res.success?
  #   rescue Cybertrain::HttpClient::Error => e
  #     Cybertrain.logger.warn("slack: #{e.message}") # host and port only
  #   end
  # @api public
  class HttpClient
    # The base of every error a request raises. The message names the host
    # and port, never the path or the query.
    # @api public
    class Error < StandardError
    end

    # Connecting, a TLS step, a read or a write took longer than `timeout`,
    # or the whole request longer than `deadline`.
    # @api public
    class TimeoutError < Error
    end

    # The connection could not be made: refused, unreachable, the host name
    # did not resolve, or the peer reset it.
    # @api public
    class RefusedError < Error
    end

    # The TLS handshake failed (including a certificate that does not verify
    # or does not name the host), or https was asked for without
    # `require "cybertrain/net/tls"`.
    # @api public
    class TLSError < Error
    end

    # The host resolved to an address that is not public (loopback, private,
    # link-local, ...) and Config#http_allow_private is off.
    # @api public
    class BlockedAddressError < Error
    end

    # The response's headers or body are larger than the client accepts.
    # @api public
    class TooLargeError < Error
    end

    # The response is not well-formed HTTP/1.1, or the connection closed
    # before it was complete.
    # @api public
    class BadResponseError < Error
    end

    # A response: the status, the headers (names in lowercase) and the body.
    # @api public
    class Response
      # @return [Integer] e.g. 200
      # @api public
      attr_reader :status

      # Header names are lowercase; a header sent more than once has its
      # values joined with ", ".
      # @return [Hash{String => String}]
      # @api public
      attr_reader :headers

      # The body as received (chunked transfer coding removed), a byte
      # String: binary under CRuby, as Net::HTTP's is.
      # @return [String]
      # @api public
      attr_reader :body

      def initialize(status, headers, body)
        @status = status
        @headers = headers
        @body = body
      end

      # @param name [String] any case
      # @return [String, nil]
      # @api public
      def header(name)
        @headers[name.to_s.downcase]
      end

      # @return [Boolean] true for a 2xx status
      # @api public
      def success?
        @status >= 200 && @status <= 299
      end
    end

    # A parsed URL: what the request needs of it. Internal.
    class Target
      attr_reader :target_tls, :target_host, :target_port, :request_target, :host_header

      def initialize(tls, host, port, request_target, host_header)
        @target_tls = tls
        @target_host = host
        @target_port = port
        @request_target = request_target
        @host_header = host_header
      end

      # "example.com:443", what error messages name.
      def target_label
        @target_host.include?(":") ? "[#{@target_host}]:#{@target_port}" : "#{@target_host}:#{@target_port}"
      end
    end

    # Request headers a caller may not set: the client owns the framing.
    RESERVED_HEADERS = ["host", "connection", "content-length", "transfer-encoding", "te", "upgrade", "trailer", "keep-alive", "proxy-connection"]

    # The longest status or header line, and all header lines together.
    MAX_LINE_BYTES = 8192
    MAX_HEAD_BYTES = 65_536
    MAX_HEADER_COUNT = 100
    # Interim (1xx) responses skipped before the final one.
    MAX_INTERIM = 5

    # Seeded with a String pair, then emptied (spikes/NOTES.md rule 9): the
    # default for `headers:`.
    NO_HEADERS = { "" => "" }
    NO_HEADERS.delete("")

    # @return [Float] seconds any one wait may take
    # @api public
    attr_reader :timeout
    # @return [Float] seconds the whole request may take
    # @api public
    attr_reader :deadline
    # @return [Integer] the largest body accepted, in bytes
    # @api public
    attr_reader :max_body
    # @return [Boolean] whether non-public destinations are allowed
    # @api public
    attr_reader :allow_private

    # @param timeout [Numeric] seconds for each wait: connecting, each TLS
    #   step, each read, each write. Default 5.
    # @param deadline [Numeric] seconds for the whole request, name
    #   resolution included. Default 15.
    # @param max_body [Integer] the largest response body accepted, in bytes
    #   (larger raises TooLargeError). Default 1 MiB.
    # @param allow_private [Boolean] allow loopback, private and other
    #   non-public destinations. Default Config#http_allow_private.
    # @api public
    def initialize(timeout: 5, deadline: 15, max_body: 1_048_576, allow_private: Cybertrain.config.http_allow_private)
      @timeout = timeout.to_f
      @deadline = deadline.to_f
      @max_body = max_body.to_i
      @allow_private = allow_private == true
      raise ArgumentError, "timeout must be positive" unless @timeout > 0.0
      raise ArgumentError, "deadline must be positive" unless @deadline > 0.0
      raise ArgumentError, "max_body must be at least 0" if @max_body < 0
    end

    # GET `url`.
    # @param url [String] http:// or https://
    # @param headers [Hash{String => String}] extra request headers
    # @return [Response]
    # @raise [Error] a subclass; ArgumentError for a URL or header the client refuses
    # @api public
    def get(url, headers: NO_HEADERS)
      perform("GET", url, "", "", headers)
    end

    # POST `body` to `url`.
    # @param url [String] http:// or https://
    # @param body [String]
    # @param content_type [String] the Content-Type header
    # @param headers [Hash{String => String}] extra request headers
    # @return [Response]
    # @raise [Error] a subclass; ArgumentError for a URL or header the client refuses
    # @api public
    def post(url, body, content_type: "application/json", headers: NO_HEADERS)
      perform("POST", url, body.to_s, content_type.to_s, headers)
    end

    # One request, its Net errors translated into HttpClient's. The rescue
    # ladder is here, in a method that takes no block (NOTES rules 32, 45),
    # and tells the classes apart by rescue clause (rule 47).
    def perform(verb, url, body, content_type, headers)
      target = HttpClient.parse_url(url)
      head = HttpClient.request_head(verb, target, body, content_type, headers)
      begin
        exchange(target, head, body, verb == "POST")
      rescue Net::TimeoutError => e
        raise TimeoutError, e.message
      rescue Net::BlockedError => e
        raise BlockedAddressError, e.message
      rescue Net::TlsError => e
        raise TLSError, e.message
      rescue Net::ConnectError => e
        raise RefusedError, e.message
      rescue Net::LimitError => e
        raise TooLargeError, e.message
      rescue Net::ProtocolError => e
        raise BadResponseError, e.message
      end
    end

    def exchange(target, head, body, with_body)
      label = target.target_label
      timer = Net::Timer.new(label, @timeout, @deadline)
      endpoint = Net.resolve(target.target_host, target.target_port, label)
      timer.wait_limit("resolving the host name") # the deadline, after the blocking lookup
      tcp = Net::TcpStream.connect_to(allowed_addresses(endpoint, label), target.target_port, label, timer)
      stream = HttpClient.open_stream(tcp, target, timer)
      begin
        wire = String.new
        wire << head
        wire << body if with_body
        stream.stream_write(wire, timer)
        HttpClient.read_response(Net::Reader.new(stream, timer), label, @max_body)
      ensure
        stream.stream_close
      end
    end

    # The addresses of `endpoint` this client may dial, in their order: all
    # of them with allow_private, else the public ones. The policy is decided
    # per address, so a name with a public and a private address dials the
    # public one; when every address is refused, BlockedError names the
    # first and why.
    def allowed_addresses(endpoint, label)
      return endpoint if @allow_private

      allowed = Net::Endpoint.new
      first_ip = ""
      first_reason = ""
      i = 0
      while i < endpoint.endpoint_count
        ip = endpoint.endpoint_ip_at(i)
        reason = Net::Address.blocked_reason(ip)
        if reason.empty?
          allowed.offer(ip, endpoint.endpoint_family_at(i))
        elsif first_ip.empty?
          first_ip = ip
          first_reason = reason
        end
        i += 1
      end
      unless allowed.found?
        raise Net::BlockedError, "#{label}: refusing to connect to #{first_ip} (#{first_reason} address); " \
                                 "set Cybertrain.config.http_allow_private to allow it"
      end
      allowed
    end

    # The plain stream, or TLS over it for https.
    def self.open_stream(tcp, target, timer)
      return tcp unless target.target_tls

      Net.tls_connector.tls_wrap(tcp, target.target_host, timer)
    end

    # ---- the request --------------------------------------------------------

    # The request line and headers. Raises ArgumentError for a header name
    # that is not a token, a value with CR, LF or NUL, or a header the client
    # sets itself; the messages name the header, never its value.
    def self.request_head(verb, target, body, content_type, headers)
      head = String.new
      head << verb << " " << target.request_target << " HTTP/1.1\r\n"
      head << "Host: " << target.host_header << "\r\n"
      user_agent = false
      headers.each_key do |key|
        name = key.to_s
        value = headers[key].to_s
        HttpClient.check_header(name, value)
        lower = name.downcase
        raise ArgumentError, "set the Content-Type of a POST with content_type:" if lower == "content-type" && verb == "POST"
        user_agent = true if lower == "user-agent"
        head << name << ": " << value << "\r\n"
      end
      head << "User-Agent: cybertrain/" << VERSION << "\r\n" unless user_agent
      if verb == "POST"
        HttpClient.check_header("Content-Type", content_type)
        head << "Content-Type: " << content_type << "\r\n" unless content_type.empty?
        head << "Content-Length: " << body.bytesize.to_s << "\r\n"
      end
      head << "Connection: close\r\n\r\n"
      head
    end

    def self.check_header(name, value)
      raise ArgumentError, "header name #{name.inspect} is not a token" unless HttpClient.token?(name)

      lower = name.downcase
      i = 0
      while i < RESERVED_HEADERS.size
        raise ArgumentError, "header #{name} is set by the client itself" if RESERVED_HEADERS[i] == lower
        i += 1
      end

      s = value.to_s # NOTES rule 62
      i = 0
      n = s.bytesize
      while i < n
        b = s.getbyte(i)
        raise ArgumentError, "header #{name} contains CR, LF or NUL" if b == 13 || b == 10 || b == 0
        i += 1
      end
      nil
    end

    # RFC 9110 token characters.
    def self.token?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return false if n == 0

      i = 0
      while i < n
        b = s.getbyte(i)
        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ||
             b == 33 || (b >= 35 && b <= 39) || b == 42 || b == 43 || b == 45 || b == 46 ||
             b == 94 || b == 95 || b == 96 || b == 124 || b == 126
        return false unless ok

        i += 1
      end
      true
    end

    # ---- the URL ------------------------------------------------------------

    # Splits an http:// or https:// URL by a byte scan. Raises ArgumentError
    # for anything else; the message never repeats the URL (its path or query
    # may be a secret).
    # @return [Target]
    def self.parse_url(url)
      s = url.to_s # NOTES rule 62
      n = s.bytesize
      i = 0
      while i < n
        b = s.getbyte(i)
        raise ArgumentError, "the URL contains a space, a control character or a non-ASCII byte" if b <= 32 || b >= 127
        i += 1
      end
      tls = false
      start = 0
      if HttpClient.prefix_ci?(s, "https://")
        tls = true
        start = 8
      elsif HttpClient.prefix_ci?(s, "http://")
        start = 7
      else
        raise ArgumentError, "only http:// and https:// URLs are supported"
      end
      stop = start
      while stop < n
        b = s.getbyte(stop)
        break if b == 47 || b == 63 || b == 35 # / ? #
        stop += 1
      end
      authority = s.byteslice(start, stop - start)
      raise ArgumentError, "URLs with user information (user@host) are not supported" unless authority.index("@").nil?

      host = ""
      port_text = ""
      if authority.start_with?("[")
        bracket = authority.index("]")
        raise ArgumentError, "the URL's IPv6 host is missing its ]" if bracket.nil?

        host = authority.byteslice(1, bracket - 1)
        rest = authority.byteslice(bracket + 1, authority.bytesize - bracket - 1)
        unless rest.empty?
          raise ArgumentError, "the URL's host is malformed" unless rest.start_with?(":")

          port_text = rest.byteslice(1, rest.bytesize - 1)
        end
        raise ArgumentError, "the URL's IPv6 host is malformed" unless HttpClient.ipv6_chars?(host)
      else
        colon = authority.index(":")
        if colon.nil?
          host = authority
        else
          host = authority.byteslice(0, colon)
          port_text = authority.byteslice(colon + 1, authority.bytesize - colon - 1)
        end
        raise ArgumentError, "the URL's host is malformed" unless HttpClient.host_chars?(host)
      end
      host = host.downcase
      port = tls ? 443 : 80
      unless port_text.empty?
        port = HttpClient.port_number(port_text)
        raise ArgumentError, "the URL's port is not a number from 1 to 65535" if port < 1
      end
      path = stop < n ? s.byteslice(stop, n - stop) : "/"
      hash = path.index("#")
      path = path.byteslice(0, hash) unless hash.nil?
      path = "/" if path.empty?
      path = "/" + path if path.start_with?("?")
      shown = host.include?(":") ? "[#{host}]" : host
      default_port = tls ? 443 : 80
      host_header = port == default_port ? shown : "#{shown}:#{port}"
      Target.new(tls, host, port, path, host_header)
    end

    def self.prefix_ci?(s, prefix)
      return false if s.bytesize < prefix.bytesize

      s.byteslice(0, prefix.bytesize).downcase == prefix
    end

    # A registered name or an IPv4 literal: letters, digits, "-", ".", "_".
    def self.host_chars?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return false if n == 0 || n > 253

      i = 0
      while i < n
        b = s.getbyte(i)
        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 46 || b == 95
        return false unless ok

        i += 1
      end
      true
    end

    # Hex digits, ":" and "." (an IPv4 tail); no zone ("%"), which a URL
    # would have to escape.
    def self.ipv6_chars?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return false if n < 2

      i = 0
      while i < n
        b = s.getbyte(i)
        ok = (b >= 48 && b <= 58) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102) || b == 46
        return false unless ok

        i += 1
      end
      true
    end

    # 1..65535, or -1. At most five digits, so to_i cannot overflow (NOTES
    # rule 25).
    def self.port_number(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return -1 if n == 0 || n > 5

      value = 0
      i = 0
      while i < n
        b = s.getbyte(i)
        return -1 if b < 48 || b > 57

        value = value * 10 + (b - 48)
        i += 1
      end
      value >= 1 && value <= 65_535 ? value : -1
    end

    # ---- the response -------------------------------------------------------

    def self.read_response(reader, label, max_body)
      interim = 0
      while true
        status = HttpClient.status_code(reader.read_line(MAX_LINE_BYTES), label)
        headers = HttpClient.read_headers(reader, label)
        if status >= 100 && status <= 199
          raise Net::ProtocolError, "#{label}: answered 101 Switching Protocols, which was not asked for" if status == 101

          interim += 1
          raise Net::ProtocolError, "#{label}: more than #{MAX_INTERIM} interim responses" if interim > MAX_INTERIM

          next
        end
        body = HttpClient.read_body(reader, headers, status, label, max_body)
        return Response.new(status, headers, body)
      end
      Response.new(0, NO_HEADERS, "")
    end

    # The status code of an "HTTP/1.x NNN reason" line.
    def self.status_code(line, label)
      s = line.to_s # NOTES rule 62
      bad = "#{label}: the response does not start with an HTTP/1.x status line"
      raise Net::ProtocolError, bad if s.bytesize < 12 || !s.start_with?("HTTP/1.")

      d = s.getbyte(7)
      raise Net::ProtocolError, bad if d < 48 || d > 57 || s.getbyte(8) != 32
      raise Net::ProtocolError, bad if s.bytesize > 12 && s.getbyte(12) != 32

      code = 0
      i = 9
      while i < 12
        b = s.getbyte(i)
        raise Net::ProtocolError, bad if b < 48 || b > 57

        code = code * 10 + (b - 48)
        i += 1
      end
      raise Net::ProtocolError, bad if code < 100

      code
    end

    # Header lines up to the blank line, names lowercased. Caps the count and
    # the total size.
    def self.read_headers(reader, label)
      headers = { "" => "" }
      headers.delete("")
      total = 0
      count = 0
      while true
        line = reader.read_line(MAX_LINE_BYTES)
        return headers if line.empty?

        total += line.bytesize + 2
        count += 1
        raise Net::LimitError, "#{label}: the response headers are larger than #{MAX_HEAD_BYTES} bytes" if total > MAX_HEAD_BYTES
        raise Net::LimitError, "#{label}: more than #{MAX_HEADER_COUNT} response headers" if count > MAX_HEADER_COUNT

        first = line.getbyte(0)
        raise Net::ProtocolError, "#{label}: a folded response header line" if first == 32 || first == 9

        colon = line.byteindex(":")
        raise Net::ProtocolError, "#{label}: a response header line without a colon" if colon.nil? || colon == 0

        name = line.byteslice(0, colon)
        raise Net::ProtocolError, "#{label}: a response header name that is not a token" unless HttpClient.token?(name)

        value = HttpClient.trim(line.byteslice(colon + 1, line.bytesize - colon - 1))
        key = name.downcase
        previous = headers[key]
        if previous.nil?
          headers[key] = value
        else
          joined = String.new
          joined << previous << ", " << value
          headers[key] = joined
        end
      end
      headers
    end

    # Without leading and trailing spaces and tabs.
    def self.trim(text)
      s = text.to_s # NOTES rule 62
      from = 0
      upto = s.bytesize
      from += 1 while from < upto && (s.getbyte(from) == 32 || s.getbyte(from) == 9)
      upto -= 1 while upto > from && (s.getbyte(upto - 1) == 32 || s.getbyte(upto - 1) == 9)
      s.byteslice(from, upto - from)
    end

    # The body, framed the way RFC 9112 section 6.3 says: none for 204 and
    # 304, chunked when that is the last transfer coding, Content-Length
    # when given, else everything to the end of the connection.
    def self.read_body(reader, headers, status, label, max_body)
      return "" if status == 204 || status == 304

      coding = headers["transfer-encoding"]
      unless coding.nil?
        return HttpClient.read_chunked(reader, label, max_body) if HttpClient.last_coding_chunked?(coding)

        return reader.read_rest(max_body)
      end
      length_text = headers["content-length"]
      return reader.read_rest(max_body) if length_text.nil?

      length = HttpClient.content_length(length_text, label)
      raise Net::LimitError, "#{label}: the response body is #{length} bytes, more than #{max_body}" if length > max_body

      reader.read_exact(length)
    end

    def self.last_coding_chunked?(coding)
      parts = coding.to_s.split(",")
      return false if parts.empty?

      HttpClient.trim(parts[parts.size - 1]).downcase == "chunked"
    end

    # A Content-Length value: digits only (at most 18, NOTES rule 25); a
    # repeated header joined with ", " must repeat the same number.
    def self.content_length(text, label)
      parts = text.to_s.split(",")
      value = -1
      i = 0
      while i < parts.size
        digits = HttpClient.trim(parts[i])
        raise Net::ProtocolError, "#{label}: a malformed Content-Length" if digits.empty? || digits.bytesize > 18

        j = 0
        while j < digits.bytesize
          b = digits.getbyte(j)
          raise Net::ProtocolError, "#{label}: a malformed Content-Length" if b < 48 || b > 57
          j += 1
        end
        n = digits.to_i
        raise Net::ProtocolError, "#{label}: conflicting Content-Length values" if value >= 0 && n != value

        value = n
        i += 1
      end
      raise Net::ProtocolError, "#{label}: a malformed Content-Length" if value < 0

      value
    end

    # A chunked body: size lines in hex (extensions ignored), the data, and
    # trailer lines after the last chunk, which are read and dropped.
    def self.read_chunked(reader, label, max_body)
      body = String.new
      while true
        size = HttpClient.chunk_size(reader.read_line(MAX_LINE_BYTES), label)
        break if size == 0
        raise Net::LimitError, "#{label}: the response body is more than #{max_body} bytes" if body.bytesize + size > max_body

        body << reader.read_exact(size)
        raise Net::ProtocolError, "#{label}: a chunk not followed by CRLF" unless reader.read_line(MAX_LINE_BYTES).empty?
      end
      trailers = 0
      until reader.read_line(MAX_LINE_BYTES).empty?
        trailers += 1
        raise Net::LimitError, "#{label}: more than #{MAX_HEADER_COUNT} trailer lines" if trailers > MAX_HEADER_COUNT
      end
      body
    end

    # The hex size at the start of a chunk-size line, up to ";" or the end.
    def self.chunk_size(line, label)
      s = line.to_s # NOTES rule 62
      n = s.bytesize
      value = 0
      digits = 0
      i = 0
      while i < n
        b = s.getbyte(i)
        break if b == 59 || b == 32 || b == 9 # ; or whitespace before an extension

        d = Net::Address.hex_value(b)
        raise Net::ProtocolError, "#{label}: a malformed chunk size" if d < 0

        digits += 1
        raise Net::ProtocolError, "#{label}: a chunk size too large" if digits > 15

        value = value * 16 + d
        i += 1
      end
      raise Net::ProtocolError, "#{label}: a malformed chunk size" if digits == 0

      value
    end
  end
end
