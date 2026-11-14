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
# Deliberately small, a notification and API client and not a browser:
# HTTP/1.1 with `Connection: close` (one connection per request, no
# keep-alive), redirects only when asked for (`redirects:`; otherwise a 3xx
# is returned as it is), no proxy, no cookies. A body can be streamed to a
# block or into a file instead of being held in memory. https needs
# `require "cybertrain/net/tls"` as well (see that file: it links libssl,
# which a plain-http program need not). `require "cybertrain"` loads this
# file and the TLS layer, through the Sentry sender
# (cybertrain/error_reporter/sentry); `require "cybertrain/core"` loads
# neither. gzip responses need
# `require "cybertrain/http/gzip_ffi"` (it links zlib; see
# {HttpClient.gzip_decoder}). `require "cybertrain"` loads the gzip file
# already, so only a program that requires this file alone adds it.
#
# Destinations that are not public (loopback, private, link-local, ...;
# Net::Address) are refused unless Config#http_allow_private is on. The host
# name is resolved once and the addresses it resolved to are checked and
# dialled (in order, the next when one refuses), never looked up again, so a
# name that resolves to a private address is refused like the literal.
# Every redirect hop is checked the same way, and a hop from https to http
# is refused. Resolution itself
# (getaddrinfo) blocks the calling thread: the runtime has no asynchronous
# resolver; the deadline is checked after it.
#
# Errors name the host and port, never the path or the query: a webhook
# URL carries its secret there.
require "cybertrain/version"
require "cybertrain/config"
require "cybertrain/cast"
require "cybertrain/net/socket"
require "cybertrain/http/gzip_decoder"

module Cybertrain
  # Sends HTTP requests (GET, POST, PUT, PATCH, DELETE, HEAD) to other
  # servers, with bounded waits.
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
  # @example A large download, streamed into a file
  #   client = Cybertrain::HttpClient.new(deadline: 600, redirects: 3)
  #   res = client.get_to_file("https://example.com/dump.csv", "tmp/dump.csv")
  #   Cybertrain.logger.info("#{res.bytes_written} bytes") if res.success?
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
    # before it was complete, or a redirect named a URL the client does not
    # take.
    # @api public
    class BadResponseError < Error
    end

    # A response redirected again after the `redirects:` the client allows
    # had been followed. The message names the hop count and the host and
    # port of the last URL requested.
    # @api public
    class TooManyRedirectsError < Error
    end

    # A response: the status, the headers (names in lowercase) and the body.
    # A streamed response (a block, {HttpClient#get_to_file}) has an empty
    # body.
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

      # The bytes {HttpClient#get_to_file} wrote to the file; 0 for every
      # other form.
      # @return [Integer]
      # @api public
      attr_reader :bytes_written

      def initialize(status, headers, body, bytes_written = 0)
        @status = status
        @headers = headers
        @body = body
        @bytes_written = bytes_written
      end

      # The body parsed as a JSON object.
      # @example
      #   name = client.get(url).json_hash["name"]
      # @return [Hash{String => Object}] `{}` when the body is not a JSON
      #   object (an array, a scalar, not JSON, empty)
      # @api public
      def json_hash
        Cast.json_hash(@body)
      end

      # The body parsed as a JSON array.
      # @return [Array<Object>] `[]` when the body is not a JSON array
      # @api public
      def json_array
        text = @body
        parsed = Cast.parse_json(text)
        Cast.array(parsed)
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

    # Where a streamed body goes, one piece at a time as it arrives. This
    # base takes nothing and is not streaming: a request without a block
    # buffers its body. The readers call #sink_feed; the subclasses
    # override #sink_take (a stub here, spikes/NOTES.md rule 3) and
    # #sink_streaming?. A Proc is stored and called from a plain method,
    # never yielded through the reader's frames (rules 32, 45, 69, 90).
    # Internal.
    class ChunkSink
      # The bytes fed so far.
      attr_reader :sink_bytes

      def initialize
        @sink_bytes = 0
      end

      def sink_streaming?
        false
      end

      def sink_feed(data)
        @sink_bytes += data.bytesize
        sink_take(data)
        nil
      end

      def sink_take(data)
        nil
      end

      # Called with the final status before its body is read.
      def sink_begin(status)
        nil
      end
    end

    # The block of `request(...) { |chunk| }`.
    class BlockChunkSink < ChunkSink
      def initialize(chunk_block)
        super()
        @chunk_block = chunk_block
      end

      def sink_streaming?
        true
      end

      def sink_take(data)
        @chunk_block.call(data)
        nil
      end
    end

    # The open `.part` file of {HttpClient#get_to_file}. Only a 2xx body
    # is written; any other is counted and dropped.
    class FileChunkSink < ChunkSink
      def initialize(chunk_file)
        super()
        @chunk_file = chunk_file
        @chunk_keep = false
      end

      def sink_streaming?
        true
      end

      def sink_begin(status)
        @chunk_keep = status >= 200 && status <= 299
        nil
      end

      def sink_take(data)
        @chunk_file.write(data) if @chunk_keep
        nil
      end
    end

    # A gzip body on its way to another sink: each piece read is pushed
    # into the decoder and the inflated pieces (at most 64 KiB each) are fed
    # on, so the inner sink counts inflated bytes. read_body closes the
    # decoder on every exit.
    class GzipChunkSink < ChunkSink
      def initialize(inner, decoder, label)
        super()
        @gz_inner = inner
        @gz_decoder = decoder
        @gz_label = label
      end

      def sink_streaming?
        true
      end

      def sink_take(data)
        @gz_decoder.gzip_push(data)
        while true
          piece = @gz_decoder.gzip_pull
          HttpClient.check_gzip(@gz_decoder, @gz_label, 0)
          break if piece.empty?

          @gz_inner.sink_feed(piece)
        end
        nil
      end
    end

    # The verbs {#request} sends.
    VERBS = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    # Verbs whose request always carries a body and its Content-Length
    # (empty is a body too). DELETE carries one when it is given.
    BODY_VERBS = ["POST", "PUT", "PATCH"]

    # The statuses a client with `redirects:` follows when they come with
    # a Location.
    REDIRECT_STATUSES = [301, 302, 303, 307, 308]

    # Request headers a caller's redirect does not take to another origin.
    CREDENTIAL_HEADERS = ["authorization", "cookie", "proxy-authorization"]

    # A streamed chunked frame larger than this is handed on in pieces of
    # this size: no one frame is held whole.
    STREAM_PIECE_BYTES = 1_048_576

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

    # The gzip support requests use: {GzipDecoder}'s base (no gzip) until
    # `require "cybertrain/http/gzip_ffi"` installs the zlib one. With it,
    # every request says `Accept-Encoding: gzip` (unless the caller sent an
    # Accept-Encoding of its own) and a `Content-Encoding: gzip` (or
    # `x-gzip`) body is inflated: a kept body under `max_body` (the bytes on
    # the wire and the inflated bytes alike), a streamed one piece by piece,
    # at most 64 KiB at a time. Without it, a gzip response is a
    # BadResponseError naming the file to require; a Content-Encoding other
    # than gzip or identity is one either way. The Response's headers are
    # the ones received (Content-Encoding included).
    # @example
    #   require "cybertrain/http_client"
    #   require "cybertrain/http/gzip_ffi"
    #
    #   Cybertrain::HttpClient.gzip_decoder.gzip_ready? # => true
    # @return [GzipDecoder]
    # @api public
    def self.gzip_decoder
      GzipDecoder.installed
    end

    # Replaces the gzip support (cybertrain/http/gzip_ffi installs its
    # decoder when it is required). The reader is {.gzip_decoder}.
    # @param decoder [GzipDecoder]
    # @return [GzipDecoder]
    # @api public
    def self.gzip=(decoder)
      GzipDecoder.installed = decoder
    end

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
    # @return [Integer] how many redirects a request follows (0: none)
    # @api public
    attr_reader :redirects

    # @param timeout [Numeric] seconds for each wait: connecting, each TLS
    #   step, each read, each write. Default 5.
    # @param deadline [Numeric] seconds for the whole request, name
    #   resolution included. Default 15.
    # @param max_body [Integer] the largest response body accepted, in bytes
    #   (larger raises TooLargeError). Default 1 MiB.
    # @param allow_private [Boolean] allow loopback, private and other
    #   non-public destinations. Default Config#http_allow_private.
    # @param redirects [Integer] how many 301 / 302 / 303 / 307 / 308
    #   responses with a Location a request follows; past that it raises
    #   TooManyRedirectsError. Default 0: a 3xx is returned as it is. A
    #   Location that is not a plain-ASCII http(s) URL is a BadResponseError.
    # @api public
    def initialize(timeout: 5, deadline: 15, max_body: 1_048_576, allow_private: Cybertrain.config.http_allow_private,
                   redirects: 0)
      @timeout = timeout.to_f
      @deadline = deadline.to_f
      @max_body = max_body.to_i
      @allow_private = allow_private == true
      @redirects = redirects.to_i
      raise ArgumentError, "timeout must be positive" unless @timeout > 0.0
      raise ArgumentError, "deadline must be positive" unless @deadline > 0.0
      raise ArgumentError, "max_body must be at least 0" if @max_body < 0
      raise ArgumentError, "redirects must be at least 0" if @redirects < 0
    end

    # GET `url`; with a block, the body is streamed to it (see {#request}).
    # @param url [String] http:// or https://
    # @param headers [Hash{String => String}] extra request headers
    # @yield [chunk] each piece of the body as it arrives, when a block is given
    # @yieldparam chunk [String] bytes of the body
    # @return [Response]
    # @raise [Error] a subclass; ArgumentError for a URL or header the client refuses
    # @api public
    def get(url, headers: NO_HEADERS, &block)
      request("GET", url, headers: headers, &block)
    end

    # POST `body` to `url`; with a block, the response body is streamed to
    # it (see {#request}).
    # @param url [String] http:// or https://
    # @param body [String]
    # @param content_type [String] the Content-Type header
    # @param headers [Hash{String => String}] extra request headers
    # @yield [chunk] each piece of the body as it arrives, when a block is given
    # @yieldparam chunk [String] bytes of the body
    # @return [Response]
    # @raise [Error] a subclass; ArgumentError for a URL or header the client refuses
    # @api public
    def post(url, body, content_type: "application/json", headers: NO_HEADERS, &block)
      request("POST", url, body: body, content_type: content_type, headers: headers, &block)
    end

    # Sends `verb` to `url`. POST, PUT and PATCH always carry `body` (and
    # its Content-Length, and `content_type` unless empty); DELETE carries
    # one when it is not empty; GET and HEAD carry none. Content-Type
    # accompanies a body only: a `content_type:` given to a request that
    # sends none (GET, HEAD, a DELETE with an empty body) is not sent. A
    # HEAD response has no body.
    #
    # With a block, the response body is not kept: each piece is yielded as
    # it arrives (a chunked frame, up to 1 MiB at a time, or what each read
    # delivered) and the Response's body is `""`. `max_body` does not apply
    # then; `timeout` and `deadline` do, so give a long stream a long
    # `deadline:`. The body of a redirect that is followed is never yielded.
    # @example Server-Sent Events from an API
    #   client = Cybertrain::HttpClient.new(deadline: 180)
    #   client.request("POST", url, body: payload, content_type: "application/json") do |chunk|
    #     parser.feed(chunk) { |event| handle(event) }
    #   end
    # @param verb [String] "GET", "POST", "PUT", "PATCH", "DELETE" or "HEAD"
    # @param url [String] http:// or https://
    # @param body [String]
    # @param content_type [String] the Content-Type header of the body
    # @param headers [Hash{String => String}] extra request headers
    # @yield [chunk] each piece of the body as it arrives, when a block is given
    # @yieldparam chunk [String] bytes of the body
    # @return [Response]
    # @raise [Error] a subclass; ArgumentError for an unknown verb, a body on
    #   GET or HEAD, or a URL or header the client refuses
    # @api public
    def request(verb, url, body: "", content_type: "", headers: NO_HEADERS, &block)
      name = verb.to_s
      unless VERBS.include?(name)
        message = "unknown HTTP verb #{name.inspect}: GET, POST, PUT, PATCH, DELETE or HEAD"
        raise ArgumentError, message
      end
      data = body.to_s
      if !data.empty? && (name == "GET" || name == "HEAD")
        message = "a #{name} request carries no body"
        raise ArgumentError, message
      end
      if block.nil?
        perform(name, url.to_s, data, content_type.to_s, headers, ChunkSink.new)
      else
        perform(name, url.to_s, data, content_type.to_s, headers, BlockChunkSink.new(block))
      end
    end

    # GETs `url` into the file `path`: a 2xx body is written to
    # `path + ".part"` as it arrives (never held in memory, `max_body` does
    # not apply) and renamed onto `path` when the response is complete. The
    # body of any other final status (a 404 page, a 503) never reaches the
    # disk: it is read and counted, the `.part` is removed and `path` is
    # left as it was; check {Response#success?}. On any error (or an
    # interrupt) the `.part` file is removed and `path` is left as it was.
    # @param url [String] http:// or https://
    # @param path [String] the file to write; its directory must exist
    # @param headers [Hash{String => String}] extra request headers
    # @return [Response] with an empty body and {Response#bytes_written}
    #   (the bytes of the body read, written or not)
    # @raise [Error] a subclass; SystemCallError when the file cannot be
    #   written; ArgumentError for a URL or header the client refuses
    # @api public
    def get_to_file(url, path, headers: NO_HEADERS)
      final = path.to_s
      part = "#{final}.part"
      file = File.open(part, "wb")
      sink = FileChunkSink.new(file)
      res = fetch_into(url.to_s, final, part, file, sink, headers)
      Response.new(res.status, res.headers, "", sink.sink_bytes)
    end

    # get_to_file's request, close and rename (a 2xx only). On every other
    # exit (a non-2xx status, an error, an interrupt) the `.part` is closed
    # and removed. No block here (rule 32).
    def fetch_into(url, final, part, file, sink, headers)
      renamed = false
      begin
        res = perform("GET", url, "", "", headers, sink)
        file.close
        if res.success?
          File.rename(part, final)
          renamed = true
        end
        res
      ensure
        unless renamed
          file.close unless file.closed?
          File.delete(part) if File.exist?(part)
        end
      end
    end

    # A request and the redirects it is allowed to follow. Each hop is a
    # whole request of its own (perform_once: name resolution, the address
    # policy, a new connection), so the private-address check runs on
    # every hop. The deadline covers all the hops together: a later hop
    # gets what is left of it.
    def perform(verb, url, body, content_type, headers, sink)
      ends_at = Net::Timer.now + @deadline
      current = url
      hop_verb = verb
      hop_body = body
      hop_type = content_type
      hop_headers = headers
      hops = 0
      while true
        target = HttpClient.parse_url(current)
        budget = hops == 0 ? @deadline : ends_at - Net::Timer.now
        if budget <= 0.0
          message = "#{target.target_label}: the #{Net::Timer.format_seconds(@deadline)} deadline passed while following redirects"
          raise TimeoutError, message
        end
        res = perform_once(hop_verb, target, hop_body, hop_type, hop_headers, sink, budget)
        return res unless @redirects > 0 && REDIRECT_STATUSES.include?(res.status)

        location = HttpClient.location_of(res)
        return res if location.empty?

        if hops >= @redirects
          message = "#{target.target_label}: redirected again after #{hops} #{hops == 1 ? "redirect" : "redirects"}, the limit"
          raise TooManyRedirectsError, message
        end
        next_url = HttpClient.next_hop(current, location)
        status = res.status
        if (status == 303 && hop_verb != "HEAD") || ((status == 301 || status == 302) && hop_verb == "POST")
          hop_verb = "GET"
          hop_body = ""
          hop_type = ""
        end
        next_target = HttpClient.parse_url(next_url)
        hop_headers = HttpClient.cross_origin_headers(hop_headers) unless HttpClient.same_origin?(target, next_target)
        current = next_url
        hops += 1
      end
      Response.new(0, NO_HEADERS, "")
    end

    # One request, its Net errors translated into HttpClient's. The rescue
    # ladder is here, in a method that takes no block (NOTES rules 32, 45),
    # and tells the classes apart by rescue clause (rule 47).
    def perform_once(verb, target, body, content_type, headers, sink, budget)
      head = HttpClient.request_head(verb, target, body, content_type, headers)
      with_body = HttpClient.body_sent?(verb, body)
      begin
        exchange(target, head, body, with_body, sink, verb == "HEAD", budget)
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

    # One connection: `budget` seconds for all of it.
    def exchange(target, head, body, with_body, sink, head_only, budget)
      label = target.target_label
      timer = Net::Timer.new(label, @timeout, budget)
      stream = HttpClient.dial(target, timer, @allow_private)
      begin
        wire = String.new
        wire << head
        wire << body if with_body
        stream.stream_write(wire, timer)
        reader = Net::Reader.new(stream, timer)
        HttpClient.read_response(reader, label, @max_body, sink, head_only, @redirects > 0)
      ensure
        stream.stream_close
      end
    end

    # Connects to `target` the way every outbound client of the framework
    # does (the WebSocket client too): resolves the host once, checks the
    # deadline after the blocking lookup, keeps the addresses
    # `allow_private` permits, dials them in order and wraps TLS when the
    # target asks for it. Raises the Net errors; the caller translates them.
    # @return [Net::Stream]
    def self.dial(target, timer, allow_private)
      label = target.target_label
      endpoint = Net.resolve(target.target_host, target.target_port, label)
      timer.wait_limit("resolving the host name") # the deadline, after the blocking lookup
      tcp = Net::TcpStream.connect_to(HttpClient.allowed_addresses(endpoint, label, allow_private), target.target_port, label, timer)
      HttpClient.open_stream(tcp, target, timer)
    end

    # The addresses of `endpoint` a client may dial, in their order: all
    # of them with allow_private, else the public ones. The policy is decided
    # per address, so a name with a public and a private address dials the
    # public one; when every address is refused, BlockedError names the
    # first and why.
    def self.allowed_addresses(endpoint, label, allow_private)
      return endpoint if allow_private

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

    # ---- redirects ----------------------------------------------------------

    # The Location of a response, "" when it has none.
    def self.location_of(res)
      value = res.headers["location"]
      value.nil? ? "" : value.to_s
    end

    # The URL a redirect from `current` to `location` goes to:
    # {resolve_location}, checked. Raises BlockedAddressError for a hop from
    # https to http and BadResponseError for a URL the client does not
    # take; the messages name a host and port only.
    # @return [String]
    def self.next_hop(current, location)
      from = HttpClient.parse_url(current)
      resolved = HttpClient.resolve_location(current, location)
      to = HttpClient.redirect_target(resolved, from.target_label)
      if from.target_tls && !to.target_tls
        message = "#{to.target_label}: refusing to follow a redirect from https to http"
        raise BlockedAddressError, message
      end
      resolved
    end

    # parse_url of a redirect's URL, its ArgumentError a BadResponseError
    # naming the host and port that redirected.
    def self.redirect_target(url, label)
      HttpClient.parse_url(url)
    rescue ArgumentError
      message = "#{label}: redirected to a URL the client does not take"
      raise BadResponseError, message
    end

    def self.same_origin?(a, b)
      a.target_tls == b.target_tls && a.target_host == b.target_host && a.target_port == b.target_port
    end

    # `headers` without the credentials (CREDENTIAL_HEADERS), for a hop to
    # another origin.
    def self.cross_origin_headers(headers)
      kept = { "" => "" }
      kept.delete("")
      headers.each_key do |key|
        name = key.to_s
        kept[name] = headers[key].to_s unless CREDENTIAL_HEADERS.include?(name.downcase)
      end
      kept
    end

    # Resolves a redirect's Location against the URL that answered it
    # (RFC 3986 section 5.2): an absolute URL as it is, `//host/path` with
    # the current scheme, `/path` on the current origin, `?query` on the
    # current path, a relative path against the current path's directory,
    # dot segments removed. The fragment is dropped.
    # @example
    #   Cybertrain::HttpClient.resolve_location("https://a.example/x/y?q=1", "../z")
    #   # => "https://a.example/z"
    # @param current [String] an absolute http:// or https:// URL
    # @param location [String] the Location header's value
    # @return [String] an absolute URL (not checked: a scheme the client
    #   does not take is returned as it is)
    # @api public
    def self.resolve_location(current, location)
      base = current.to_s # NOTES rule 62
      loc = HttpClient.without_fragment(location.to_s)
      return loc if HttpClient.scheme_prefix?(loc)

      base = HttpClient.without_fragment(base)
      n = base.bytesize
      mark = base.index("://")
      raise ArgumentError, "the current URL has no scheme" if mark.nil?

      if loc.start_with?("//")
        out = String.new
        out << base.byteslice(0, mark) << ":" << loc
        return out
      end
      stop = mark + 3
      while stop < n
        b = base.getbyte(stop)
        break if b == 47 || b == 63 # / ?
        stop += 1
      end
      origin = base.byteslice(0, stop)
      rest = base.byteslice(stop, n - stop)
      query_at = rest.index("?")
      path = query_at.nil? ? rest : rest.byteslice(0, query_at)
      path = "/" if path.empty?
      out = String.new
      out << origin
      if loc.empty?
        out << path
        out << rest.byteslice(query_at, rest.bytesize - query_at) unless query_at.nil?
        return out
      end
      if loc.start_with?("?")
        out << path << loc
        return out
      end
      loc_query_at = loc.index("?")
      loc_path = loc_query_at.nil? ? loc : loc.byteslice(0, loc_query_at)
      merged = String.new
      if loc.start_with?("/")
        merged << loc_path
      else
        slash = path.rindex("/")
        merged << path.byteslice(0, slash + 1) unless slash.nil?
        merged << loc_path
      end
      out << HttpClient.remove_dot_segments(merged)
      out << loc.byteslice(loc_query_at, loc.bytesize - loc_query_at) unless loc_query_at.nil?
      out
    end

    # `url` up to its "#", if any.
    def self.without_fragment(url)
      s = url.to_s # NOTES rule 62
      hash = s.index("#")
      hash.nil? ? s : s.byteslice(0, hash)
    end

    # Whether `text` starts with a URI scheme and ":" ("https:", "ftp:"),
    # so it is an absolute URL.
    def self.scheme_prefix?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      return false if n == 0

      first = s.getbyte(0)
      return false unless (first >= 65 && first <= 90) || (first >= 97 && first <= 122)

      i = 1
      while i < n
        b = s.getbyte(i)
        return true if b == 58 # :

        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 43 || b == 45 || b == 46
        return false unless ok

        i += 1
      end
      false
    end

    # An absolute path without "." and ".." segments (RFC 3986 section
    # 5.2.4); a final "." or ".." leaves a trailing "/".
    def self.remove_dot_segments(path)
      s = path.to_s # NOTES rule 62
      n = s.bytesize
      segments = Array.new(0) { "" }
      from = s.start_with?("/") ? 1 : 0
      i = from
      while i <= n
        if i == n || s.getbyte(i) == 47
          segments << s.byteslice(from, i - from)
          from = i + 1
        end
        i += 1
      end
      kept = Array.new(0) { "" }
      k = 0
      while k < segments.size
        segment = segments[k]
        last = k == segments.size - 1
        if segment == "." || segment == ".."
          kept.pop if segment == ".." && kept.size > 0
          kept << "" if last
        else
          kept << segment
        end
        k += 1
      end
      out = String.new
      out << "/" << kept.join("/")
      out
    end

    # ---- the request --------------------------------------------------------

    # Whether a `verb` request with `body` sends a body (and its
    # Content-Length and Content-Type).
    def self.body_sent?(verb, body)
      BODY_VERBS.include?(verb) || (verb == "DELETE" && !body.empty?)
    end

    # The request line and headers. Raises ArgumentError for a header name
    # that is not a token, a value with CR, LF or NUL, or a header the client
    # sets itself; the messages name the header, never its value.
    def self.request_head(verb, target, body, content_type, headers)
      head = String.new
      head << verb << " " << target.request_target << " HTTP/1.1\r\n"
      head << "Host: " << target.host_header << "\r\n"
      user_agent = false
      accept_encoding = false
      with_body = HttpClient.body_sent?(verb, body)
      headers.each_key do |key|
        name = key.to_s
        value = headers[key].to_s
        HttpClient.check_header(name, value)
        lower = name.downcase
        if lower == "content-type" && with_body
          message = "set the Content-Type of a #{verb} with content_type:"
          raise ArgumentError, message
        end
        user_agent = true if lower == "user-agent"
        accept_encoding = true if lower == "accept-encoding"
        head << name << ": " << value << "\r\n"
      end
      head << "User-Agent: cybertrain/" << VERSION << "\r\n" unless user_agent
      head << "Accept-Encoding: gzip\r\n" if !accept_encoding && HttpClient.gzip_decoder.gzip_ready?
      if with_body
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
      HttpClient.parse_url_for(url, "http://", "https://")
    end

    # parse_url for another pair of schemes ("ws://", "wss://"): the same
    # byte scan, the same messages, port 80 or 443 by default.
    # @return [Target]
    def self.parse_url_for(url, plain_scheme, tls_scheme)
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
      if HttpClient.prefix_ci?(s, tls_scheme)
        tls = true
        start = tls_scheme.bytesize
      elsif HttpClient.prefix_ci?(s, plain_scheme)
        start = plain_scheme.bytesize
      else
        raise ArgumentError, "only #{plain_scheme} and #{tls_scheme} URLs are supported"
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

    # The final response. `sink` takes the body when it is streaming;
    # `head_only` (a HEAD request) reads no body; `follow` (redirects are
    # on) leaves the body of a redirect with a Location unread: the
    # connection is closed and the next hop made.
    def self.read_response(reader, label, max_body, sink, head_only, follow)
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
        return Response.new(status, headers, "") if head_only
        if follow && REDIRECT_STATUSES.include?(status)
          location = headers["location"]
          return Response.new(status, headers, "") if !location.nil? && !location.empty?
        end
        sink.sink_begin(status)
        body = HttpClient.read_body(reader, headers, status, label, max_body, sink)
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

    # The body: none for 204 and 304, else framed (read_framed) and, for a
    # `Content-Encoding: gzip` body, inflated (read_gzip). The decoder is
    # closed here on every exit (no block in this method: rules 32, 45).
    def self.read_body(reader, headers, status, label, max_body, sink)
      return "" if status == 204 || status == 304

      gzip = HttpClient.gzip_coded?(headers["content-encoding"], label)
      return HttpClient.read_framed(reader, headers, label, max_body, sink) unless gzip

      decoder = HttpClient.gzip_decoder.gzip_open
      body = ""
      begin
        body = HttpClient.read_gzip(reader, headers, label, max_body, sink, decoder)
      ensure
        decoder.gzip_close
      end
      body
    end

    # A gzip body: a kept one read whole (the bytes on the wire under
    # `max_body`) and inflated under `max_body`; a streamed one fed through
    # a GzipChunkSink, and refused when the bytes end inside the gzip
    # stream. No bytes at all (Content-Length: 0) is an empty body.
    def self.read_gzip(reader, headers, label, max_body, sink, decoder)
      unless sink.sink_streaming?
        wire = HttpClient.read_framed(reader, headers, label, max_body, sink)
        return "" if wire.empty?

        text = decoder.gzip_whole(wire, max_body)
        HttpClient.check_gzip(decoder, label, max_body)
        return text
      end
      gz = GzipChunkSink.new(sink, decoder, label)
      HttpClient.read_framed(reader, headers, label, max_body, gz)
      if gz.sink_bytes > 0 && !decoder.gzip_done?
        message = "#{label}: the gzip response body ended before its gzip stream did"
        raise Net::ProtocolError, message
      end
      ""
    end

    # Whether a Content-Encoding (nil: none) is gzip: "gzip" or "x-gzip",
    # any case, spaces around it ignored. "identity" and none are not; any
    # other coding, or gzip without the gzip support loaded, is a
    # Net::ProtocolError.
    def self.gzip_coded?(coding, label)
      return false if coding.nil?

      name = HttpClient.trim(coding).downcase
      return false if name.empty? || name == "identity"

      if name == "gzip" || name == "x-gzip"
        return true if HttpClient.gzip_decoder.gzip_ready?

        message = "#{label}: the response body is gzip-encoded and gzip support is not loaded: require \"cybertrain/http/gzip_ffi\""
        raise Net::ProtocolError, message
      end
      message = "#{label}: the response body has a Content-Encoding the client does not decode (#{name})"
      raise Net::ProtocolError, message
    end

    # Raises for a decoder whose last step failed: past `max_body` is a
    # Net::LimitError, anything else not valid gzip.
    def self.check_gzip(decoder, label, max_body)
      status = decoder.gzip_status
      return nil if status == GzipDecoder::GZIP_OK

      if status == GzipDecoder::GZIP_TOO_LARGE
        message = "#{label}: the response body inflates to more than #{max_body} bytes"
        raise Net::LimitError, message
      end
      message = "#{label}: the response body is not valid gzip data"
      raise Net::ProtocolError, message
    end

    # The body, framed the way RFC 9112 section 6.3 says: chunked when that
    # is the last transfer coding, Content-Length when given, else
    # everything to the end of the connection. A streaming `sink` is fed
    # the body and "" is returned; `max_body` applies only to a body that
    # is kept.
    def self.read_framed(reader, headers, label, max_body, sink)
      streaming = sink.sink_streaming?
      coding = headers["transfer-encoding"]
      unless coding.nil?
        if HttpClient.last_coding_chunked?(coding)
          return HttpClient.stream_chunked(reader, label, sink) if streaming

          return HttpClient.read_chunked(reader, label, max_body)
        end
        return HttpClient.stream_rest(reader, sink) if streaming

        return reader.read_rest(max_body)
      end
      length_text = headers["content-length"]
      if length_text.nil?
        return HttpClient.stream_rest(reader, sink) if streaming

        return reader.read_rest(max_body)
      end

      length = HttpClient.content_length(length_text, label)
      return HttpClient.stream_exact(reader, length, label, sink) if streaming

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

    # A chunked body fed to `sink`: each frame whole when it is at most
    # STREAM_PIECE_BYTES, else in pieces of that size. Returns "".
    def self.stream_chunked(reader, label, sink)
      while true
        size = HttpClient.chunk_size(reader.read_line(MAX_LINE_BYTES), label)
        break if size == 0

        left = size
        while left > 0
          take = left > STREAM_PIECE_BYTES ? STREAM_PIECE_BYTES : left
          piece = reader.read_exact(take)
          sink.sink_feed(piece)
          left -= take
        end
        unless reader.read_line(MAX_LINE_BYTES).empty?
          message = "#{label}: a chunk not followed by CRLF"
          raise Net::ProtocolError, message
        end
      end
      trailers = 0
      until reader.read_line(MAX_LINE_BYTES).empty?
        trailers += 1
        if trailers > MAX_HEADER_COUNT
          message = "#{label}: more than #{MAX_HEADER_COUNT} trailer lines"
          raise Net::LimitError, message
        end
      end
      ""
    end

    # `count` bytes fed to `sink` as the reads deliver them. Returns "".
    def self.stream_exact(reader, count, label, sink)
      left = count
      while left > 0
        if reader.buffered == 0 && !reader.fill_more
          message = "#{label}: the connection closed before the body was complete"
          raise Net::ProtocolError, message
        end

        take = reader.buffered
        take = left if take > left
        piece = reader.read_exact(take)
        sink.sink_feed(piece)
        left -= take
      end
      ""
    end

    # Everything to the end of the connection, fed to `sink` as the reads
    # deliver it. Returns "".
    def self.stream_rest(reader, sink)
      while reader.buffered > 0 || reader.fill_more
        piece = reader.read_exact(reader.buffered)
        sink.sink_feed(piece)
      end
      ""
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
