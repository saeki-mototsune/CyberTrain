require "cybertrain/http/query"
require "cybertrain/http/header_name"
require "cybertrain/http/parser"
require "cybertrain/http/multipart"

module Cybertrain
  # The request body cannot be decoded as its Content-Encoding says
  # (corrupt gzip data, an encoding the server does not decode, or a gzip
  # body in a program with no inflater installed). Raised by
  # {Request#decoded_body}; a client fault, answered 400 (see ClientError).
  # A QueryInvalid, like the other faults in request data, so
  # `rescue Cybertrain::QueryInvalid` covers it.
  # @api public
  class BodyUndecodable < QueryInvalid
  end

  # The request body is larger than the limit once decoded: a plain body
  # over it, or a gzip body whose inflated bytes reached it. Raised by
  # {Request#decoded_body}; a client fault, answered 400.
  # @api public
  class BodyTooLarge < QueryInvalid
  end

  # One incoming HTTP request. Header names are expected lowercased (as
  # HttpParser produces them), but #header also finds mixed-case keys so
  # hand-built requests in tests behave the same.
  #
  # {Controller#request} in an action. Read parameters through
  # {Controller#params}; the request holds the raw parts. The client's
  # address is {#client_ip} (Rails' `remote_ip`, with one trusted proxy on
  # this host at most, see {Request.trusted_proxy}). There is no `xhr?`,
  # `format` or `url`.
  # @example
  #   request.header("user-agent")
  #   JSON.parse(request.body) if request.json?   # JSON bodies are not parsed into params
  #   JSON.parse(request.decoded_body)            # the same for a gzip-compressed body
  # @api public
  class Request
    # The largest decoded body {#decoded_body} returns by default, 10 MiB,
    # the same as the server's default limit on the body as sent
    # (Config#max_body_bytes). An endpoint that expects more passes its own
    # limit (at most 2 GiB - 1, what the inflater can hand back), sized to
    # its payload: inflating costs about 1.4 ms per MiB of output and runs
    # in C without yielding, so a large default would let a small body keep
    # the worker busy.
    # @api public
    MAX_DECODED_BODY_BYTES = 10_485_760

    # A gzip member is at least a 10-byte header and an 8-byte trailer.
    GZIP_MIN_BYTES = 18
    # The method, upper case, after a form's `_method` override (so
    # `"PATCH"` for an edit form).
    # @return [String]
    # @api public
    attr_reader :method

    # The path as sent, without the query string and not percent-decoded.
    # @return [String]
    # @api public
    attr_reader :path

    # The raw query string, without the `?` (`""` when there is none).
    # @return [String]
    # @api public
    attr_reader :query_string

    # The headers, by lowercase name. {#header} looks one up.
    # @return [Hash{String => String}]
    # @api public
    attr_reader :headers

    # The raw body (`""` when there is none).
    # @return [String]
    # @api public
    attr_reader :body

    # The peer's IP address (the reverse proxy's, behind one).
    # @return [String]
    # @api public
    attr_reader :remote_addr

    attr_reader :http_version

    def initialize(method, target, headers, body, remote_addr = "", http_version = "HTTP/1.1")
      @method = method.upcase
      q = target.index("?")
      if q.nil?
        @path = target
        @query_string = ""
      else
        @path = target[0, q]
        @query_string = target[q + 1, target.size - q - 1]
      end
      @headers = headers
      @body = body
      @remote_addr = remote_addr
      @http_version = http_version
      @utf8_query_string = nil
      @utf8_body = nil
      @decoded_body = nil
      @multipart_form = nil
      @path_segments_cache = nil
    end

    # Used by MethodOverride to turn a POST form into PATCH/PUT/DELETE.
    def override_method!(m)
      @method = m.upcase
    end

    # @example
    #   request.header("Referer")
    # @param name [String] any case
    # @return [String, nil]
    # @api public
    def header(name)
      value = @headers[HeaderName.lower(name)]
      return value unless value.nil?

      @headers.each do |k, v|
        return v if HeaderName.same?(k, name)
      end
      nil
    end

    # The largest Integer a 64-bit runtime holds; what an overlong
    # Content-Length reports.
    INT64_MAX = 9223372036854775807

    # The Content-Length header as an Integer.
    #
    # 0 when the header is absent or not a plain non-negative integer. A
    # value of more than 18 digits is reported as 9223372036854775807
    # without parsing it (Spinel's `String#to_i` raises RangeError past
    # 2**63-1, NOTES rule 25; CRuby would return a Bignum): the Server's 413
    # limit rejects it either way.
    # @return [Integer]
    # @api public
    def content_length
      value = header("content-length")
      return 0 if value.nil? || value.empty?
      return 0 unless HttpParser.digits?(value)
      return INT64_MAX if value.bytesize > 18

      value.to_i
    end

    # Media type only: "text/html; charset=utf-8" -> "text/html".
    # Lowercase; `""` when absent.
    # @return [String]
    # @api public
    def content_type
      value = header("content-type")
      return "" if value.nil?

      semi = value.index(";")
      value = value[0, semi] unless semi.nil?
      value.strip.downcase
    end

    # The Content-Encoding header, lowercase; `""` when absent.
    # @return [String]
    # @api public
    def content_encoding
      value = header("content-encoding")
      return "" if value.nil?

      value.strip.downcase
    end

    # The body with its Content-Encoding undone, once per request: the body
    # itself when there is none (or `identity`), the inflated bytes for
    # `gzip` (what an SDK or API client sends past a few kilobytes). The
    # server does not decode on its way in, so an action that does not ask
    # never pays for it; {#body} stays the bytes as sent.
    #
    # The result is never larger than `limit` bytes: a gzip body is inflated
    # by the installed inflater ({GzipFFI}, zlib streamed with a ceiling on
    # the output, so a body that is small on the wire and huge inflated is
    # refused as soon as the ceiling is reached, not after), and a plain body
    # over the limit is refused as well. The bytes on the wire are bounded
    # separately by the server (Config#max_body_bytes). Other encodings
    # (`deflate`, `br`) are not decoded: a 400. A multi-member gzip file is
    # inflated whole; bytes after the last member that are not a member of
    # their own make the body undecodable.
    #
    # Pass a limit sized to the endpoint's payload: DEFLATE expands up to
    # about 1032 times, so reaching a 10 MiB ceiling takes a 10 KB body and
    # about 14 ms of the worker's time (the inflate runs in C and does not
    # yield), which is the cost a hostile client can impose per request.
    #
    # `require "cybertrain"` installs the inflater. A program that loads only
    # the HTTP layer answers every gzip body as undecodable (a 400) until it
    # requires `cybertrain/http/gzip_ffi` and calls {GzipFFI.install!}.
    # @example
    #   JSON.parse(request.decoded_body)
    #   request.decoded_body(52_428_800)   # an endpoint that takes bodies up to 50 MiB
    # @param limit [Integer] the largest decoded body accepted, in bytes
    # @return [String]
    # @raise [BodyUndecodable] on corrupt gzip data, an encoding that is not
    #   decoded here, or a gzip body with no inflater installed (a 400 when
    #   unhandled)
    # @raise [BodyTooLarge] when the decoded body would exceed `limit` (a
    #   400 when unhandled)
    # @api public
    def decoded_body(limit = MAX_DECODED_BODY_BYTES)
      cached = @decoded_body
      unless cached.nil?
        raise BodyTooLarge, "request body is #{cached.bytesize} bytes, over the limit of #{limit}" if cached.bytesize > limit

        return cached
      end

      encoding = content_encoding
      text = ""
      if encoding == "" || encoding == "identity"
        raise BodyTooLarge, "request body is #{@body.bytesize} bytes, over the limit of #{limit}" if @body.bytesize > limit

        text = @body
      elsif encoding == "gzip" || encoding == "x-gzip"
        text = Request.gunzip(@body, limit)
      else
        raise BodyUndecodable, "Content-Encoding #{encoding.inspect} is not supported (gzip or identity)"
      end
      @decoded_body = text
      text
    end

    # Inflates one gzip body under a size limit through the installed
    # inflater. The gzip magic (1f 8b, method 8) is checked here, so a body
    # that is not gzip at all is undecodable before the inflater is asked.
    # The trailer's ISIZE is deliberately not consulted: it is the sender's
    # claim (and the last four bytes of a body with trailing junk are not a
    # trailer at all); the inflater measures the real output as it goes.
    # `body` can be boxed (a caller's nullable or polymorphic body), and a
    # boxed `getbyte` raises NoMethodError in a program that requires the
    # openssl package (spikes/NOTES.md rule 62): read it through `to_s`.
    def self.gunzip(body, limit)
      data = body.to_s
      if data.bytesize < GZIP_MIN_BYTES || data.getbyte(0) != 0x1f || data.getbyte(1) != 0x8b || data.getbyte(2) != 8
        raise BodyUndecodable, "request body is not gzip data"
      end

      inflater.call(data, limit)
    end

    # The inflater behind #decoded_body: a lambda taking (data, limit) and
    # returning the inflated String, raising BodyUndecodable / BodyTooLarge.
    # The default refuses every gzip body: the only bounded inflater is
    # GzipFFI (system zlib through Spinel FFI), which cannot be loaded here
    # (CRuby loads this file for the portable tests and check-http-layer),
    # so `require "cybertrain"` installs it. A module-level ivar with a
    # lambda default, the shape Views.url_resolver has (NOTES rules 18, 42).
    @inflater = ->(data, limit) { raise BodyUndecodable, "gzip request bodies are not decoded: no inflater is installed (require \"cybertrain\")" }

    def self.inflater
      @inflater
    end

    def self.inflater=(inflater)
      @inflater = inflater
    end

    # Connection is a comma-separated token list; tokens are compared
    # exactly (case-insensitively), and "close" wins over "keep-alive".
    def keep_alive?
      connection = header("connection")
      close = false
      keep = false
      unless connection.nil?
        connection.split(",").each do |t|
          token = t.strip.downcase
          close = true if token == "close"
          keep = true if token == "keep-alive"
        end
      end
      return false if close

      @http_version == "HTTP/1.0" ? keep : true
    end

    # @return [Boolean]
    # @api public
    def get?
      @method == "GET"
    end

    # @return [Boolean]
    # @api public
    def post?
      @method == "POST"
    end

    # @return [Boolean]
    # @api public
    def head?
      @method == "HEAD"
    end

    # @return [Boolean]
    # @api public
    def patch?
      @method == "PATCH"
    end

    # @return [Boolean]
    # @api public
    def put?
      @method == "PUT"
    end

    # @return [Boolean]
    # @api public
    def delete?
      @method == "DELETE"
    end

    # @return [Boolean] true for an `application/x-www-form-urlencoded`
    #   body, the only kind parsed into params
    # @api public
    def form?
      content_type == "application/x-www-form-urlencoded"
    end

    # @return [Boolean] true for an `application/json` body
    # @api public
    def json?
      content_type == "application/json"
    end

    # @return [Boolean] true for a `multipart/form-data` body (a form with
    #   file fields). Its text parts and files reach {Controller#params}
    #   (files through {Params#upload}); see {#multipart_form}.
    # @api public
    def multipart?
      content_type == "multipart/form-data"
    end

    # The boundary of a multipart body, from the full Content-Type header
    # (#content_type drops the parameters); `""` when there is none or it is
    # not a valid boundary.
    # @return [String]
    # @api public
    def multipart_boundary
      Multipart.boundary_from(header("content-type").to_s)
    end

    # The parsed multipart body, once per request (MethodOverride and
    # CsrfProtection read their one field from it before routing, then the
    # Router fills the controller's params from the same result). Callers
    # check #multipart? first. The ivar starts as nil and is assigned from a
    # method's result (NOTES rule 7); a raise is not cached, so every later
    # call raises again and the request still ends as that 400.
    #
    # A multipart body with a Content-Encoding is refused: the parser works on
    # the bytes as sent and nothing here inflates a body it then slices.
    # @return [MultipartForm]
    # @raise [MultipartMalformed] for an encoded body or a malformed one; the
    #   Multipart* faults are client faults, answered 400
    # @api public
    def multipart_form
      cached = @multipart_form
      return cached unless cached.nil?

      enc = content_encoding
      raise MultipartMalformed, "encoded multipart bodies are not supported" unless enc.empty? || enc == "identity"

      form = Multipart.parse(@body, header("content-type").to_s)
      @multipart_form = form
      form
    end

    # What the request exposes of its parameters, each validated once:
    # utf8_query_string and utf8_body (the validated UTF-8 text of the
    # fields, see below), form_value / query_value / form_or_query_value
    # (one key), multipart_form (the parsed multipart body) and
    # path_segments. There is no cached parameter tree: nobody in the
    # framework asks for one (the Router builds the controller's own with
    # Query.parse_valid and Multipart.fill, MethodOverride and CsrfProtection
    # read one key). An
    # app or middleware that wants a whole tree calls
    # `Query.parse(request.utf8_query_string)` and owns it, a private,
    # writable Params.
    #
    # The query string as validated UTF-8 text (Query.utf8!: a raw or
    # percent-encoded invalid sequence is QueryMalformed whatever the String's
    # tag), once per request: every reader (query_value, the Router's parse)
    # takes this text and skips its own O(length) validation. For a String
    # that is already UTF-8 (every one under Spinel) it is the field itself;
    # for a binary CRuby socket buffer it is one copy. A raise is not cached:
    # every call raises again and the request still ends as that 400. The ivar
    # starts as nil and is assigned from a method's result (NOTES rule 7).
    def utf8_query_string
      cached = @utf8_query_string
      return cached unless cached.nil?

      text = Query.utf8!(@query_string)
      @utf8_query_string = text
      text
    end

    # The body as validated UTF-8 text, once per request, like
    # #utf8_query_string. Only meaningful for a form body (#form?): callers
    # check that first, and any other body is never validated. On a form POST
    # this is where the body is validated: MethodOverride reads it first, then
    # CsrfProtection and the Router's parse reuse the result, so a hostile
    # body costs one O(body) validation, not one per reader.
    def utf8_body
      cached = @utf8_body
      return cached unless cached.nil?

      text = Query.utf8!(@body)
      @utf8_body = text
      text
    end

    # The decoded value of one key of the query string, "" when absent: one
    # scan of the validated text, no tree (Query.value_of_valid has the
    # semantics: last pair wins, `name[]` evicts, limits and malformed input
    # raise as a parse would). For the framework middleware that read a
    # single field before routing.
    def query_value(name)
      Query.value_of_valid(utf8_query_string, name)
    end

    # The same for the form body, one scan per call. Only meaningful for a
    # form body (#form?): callers check that first.
    def form_value(name)
      Query.value_of_valid(utf8_body, name)
    end

    # One field from the form body or, failing that, the query string: the
    # form body wins (read only when #form?), one Query.value_of_valid scan
    # each, "" when neither has it. A multipart body (#multipart?) counts as
    # a form body: its text part of that name (a file part never answers),
    # from the one parse #multipart_form caches. For the middleware that read
    # one field before routing (MethodOverride's `_method`, CsrfProtection's
    # token), so both work for a form with a file field. #form? stays false
    # for multipart, so utf8_body never sees binary data.
    def form_or_query_value(name)
      value = ""
      value = form_value(name) if form?
      value = multipart_form.text_value(name) if value.empty? && multipart?
      value = query_value(name) if value.empty?
      value
    end

    # The path split into percent-decoded segments, once per request:
    # "/posts/1/" -> ["posts", "1"]. Static (every GET/HEAD) and the Router
    # both need them, and the path is validated whole and each segment holding
    # a "%" decoded (valid_escapes?, decode_valid and its result check), so it
    # is done once per request. The decision to answer 400 for an invalid
    # UTF-8 byte sequence in the path (QueryMalformed) is therefore made in one
    # place, by whichever reader comes first (Static for GET/HEAD, the Router
    # otherwise); a raise is not cached, so every later call raises again and
    # the request still ends as that 400. The returned Array is the cached
    # one, shared by both readers: callers must not mutate it, nor the Strings
    # in it (neither does: they only read, compare and join; the Router dups a
    # capture before it puts it into the controller's params); one that needs
    # to change either dups it. The ivar starts as nil and is assigned from a
    # method's result (NOTES rule 7).
    def path_segments
      cached = @path_segments_cache
      return cached unless cached.nil?

      parsed = Request.split_path(@path)
      @path_segments_cache = parsed
      parsed
    end

    # "/posts/1/" -> ["posts", "1"]; each segment is percent-decoded, but a
    # "+" stays a plus (it only means space in query strings and forms).
    # The WHOLE path is validated once, first, as UTF-8 whatever the String's
    # tag (Query.utf8!): a raw invalid byte anywhere in it is QueryMalformed
    # (a 400, as Rails answers for an invalid path encoding), also in a
    # segment that is never decoded. Doing it on the whole path before
    # `split` also keeps `split` itself safe: CRuby's raises ArgumentError on
    # a broken UTF-8-tagged String (Spinel's accepts it, NOTES rule 52).
    # A segment with a malformed escape ("%ZZ", a trailing "%" or "%2") is
    # kept literal: CRuby's decoder raises ArgumentError on it while Spinel's
    # silently yields a NUL byte, so neither runtime ever sees it. That
    # policy is why the escapes are scanned twice here (Query.valid_escapes?,
    # then the decoding loop): the loop raises QueryMalformed on a malformed
    # escape, which is right for a query string (Query.decode does not
    # pre-scan) but would turn a path like "/50%off" into a 400 instead of
    # a 404 by non-match. The decoding is the byte-chunked loop of query
    # strings with "+" left alone: URI.decode_www_form_component on a whole
    # segment is quadratic on non-ASCII text under Spinel (NOTES rule 49), and
    # Static routes every GET/HEAD through the segments, anonymous requests
    # included, so a ~60 KB segment (inside the 64 KB head limit) holding one
    # non-ASCII byte and one "%41" costs ~0.5 s of CPU per request. Passing
    # false for the plus flag keeps "+" literal without a `gsub("+", "%2B")`
    # pass over the segment.
    #
    # Per segment holding a "%", the same on both runtimes:
    #   (i)  Query.valid_escapes?(seg) false -> the segment stays literal;
    #   (ii) Query.decode_valid(seg, false), whose result check catches an
    #        escape that decodes to an invalid byte ("%81").
    # A segment without any "%" is never decoded and stays literal (404 by
    # non-match). The path is valid UTF-8 before either runs, so the answers
    # do not depend on the runtime or the tag:
    #   /%zz       literal (404)
    #   /%81       400 (result check)
    #   /\x81%zz   400 (whole-path check)
    #   /\x81%41   400 (whole-path check)
    #   /\xC3%A9   400 (whole-path check: half a character raw is not valid,
    #              though CRuby would decode "\xC3" + "%A9" as "e-acute" in a
    #              binary buffer)
    #
    # Lives here, not in Router: Router requires Middleware -> Context ->
    # Request, so Request requiring Router would be a require cycle (and
    # CRuby 3.3 only warns about it, half-loading one of the two).
    def self.split_path(path)
      segments = []
      Query.utf8!(path).split("/").each do |seg|
        next if seg.empty?

        if seg.byteindex("%").nil? || !Query.valid_escapes?(seg)
          segments << seg
        else
          segments << Query.decode_valid(seg, false)
        end
      end
      segments
    end

    # Whether {#client_ip} may read X-Forwarded-For, `false`: a module-level
    # ivar with a literal default, the Params.max_page shape (spikes/NOTES.md
    # rule 18). Application#boot installs Config#trusted_proxy here, since
    # the HTTP layer cannot read the Config itself.
    @trusted_proxy = false

    # @return [Boolean] whether a loopback peer's X-Forwarded-For names the
    #   client ({#client_ip}); Config#trusted_proxy
    # @api public
    def self.trusted_proxy
      @trusted_proxy
    end

    # Installs the trusted-proxy flag. Called by Application#boot with
    # Config#trusted_proxy; a test may call it directly.
    # @param flag [Boolean]
    # @return [nil]
    # @api public
    def self.trusted_proxy=(flag)
      @trusted_proxy = flag == true
      nil
    end

    # The longest address #client_ip takes from X-Forwarded-For: an IPv6
    # address with an embedded IPv4 one is at most 45 characters.
    MAX_FORWARDED_HOP_BYTES = 45

    # Whether the connection comes from this machine: {#remote_addr} is in
    # 127.0.0.0/8, `::1` or an IPv4-mapped `::ffff:127.x.x.x`. For pages only
    # an operator on the server should reach (a first-run setup page, an
    # admin endpoint). X-Forwarded-For is never consulted, so behind a proxy
    # on the same host every request is loopback: check {#client_ip} as well
    # when one is in front.
    # @example
    #   before_action(only: [:setup]) { |c| c.head :forbidden unless c.request.loopback? }
    # @return [Boolean]
    # @api public
    def loopback?
      Request.loopback_address?(@remote_addr)
    end

    # The client's address: {#remote_addr}, unless {Request.trusted_proxy} is on
    # (Config#trusted_proxy, `CYBERTRAIN_TRUSTED_PROXY=1`) and the
    # connection comes from loopback ({#loopback?}: the proxy runs on this
    # host), in which case the last hop of X-Forwarded-For, the address the
    # proxy appended. Earlier hops are whatever the client wrote and are
    # never used. A last hop that is empty, longer than 45 bytes or not
    # printable ASCII (or no header at all) gives {#remote_addr}. What
    # {Controller.rate_limit} counts by default.
    # @example
    #   Session.create!(user_id: user.id, ip_address: request.client_ip)
    # @return [String]
    # @api public
    def client_ip
      addr = @remote_addr
      return addr unless Request.trusted_proxy
      return addr unless Request.loopback_address?(addr)

      forwarded = header("x-forwarded-for")
      return addr if forwarded.nil?

      hop = Request.last_forwarded_hop(forwarded)
      hop.empty? ? addr : hop
    end

    # The last comma-separated element of an X-Forwarded-For value, spaces
    # and tabs around it removed, or "" when it is empty, longer than
    # MAX_FORWARDED_HOP_BYTES or holds a byte outside 0x21..0x7E. Byte scans
    # only: the header may hold any bytes, including invalid UTF-8, which
    # CRuby's split/strip would raise on (NOTES rule 52); read through a new
    # local for rule 62 (header values can be boxed).
    def self.last_forwarded_hop(value)
      s = value.to_s
      stop = s.bytesize
      start = stop
      while start > 0 && s.getbyte(start - 1) != 44
        start -= 1
      end
      while start < stop && Request.blank_byte?(s.getbyte(start))
        start += 1
      end
      while stop > start && Request.blank_byte?(s.getbyte(stop - 1))
        stop -= 1
      end
      length = stop - start
      return "" if length < 1 || length > MAX_FORWARDED_HOP_BYTES

      i = start
      while i < stop
        b = s.getbyte(i)
        return "" if b < 0x21 || b > 0x7e

        i += 1
      end
      s.byteslice(start, length).to_s
    end

    def self.blank_byte?(b)
      b == 32 || b == 9
    end

    # Whether an address as the server reports it (Socket#peeraddr) is a
    # loopback one: "::1", or a dotted quad in 127.0.0.0/8, bare or
    # IPv4-mapped ("::ffff:127.0.0.1", either case). A byte scan; "" (a
    # request built without an address) is not loopback.
    def self.loopback_address?(addr)
      s = addr.to_s
      return true if s == "::1"

      from = Request.mapped_prefix?(s) ? 7 : 0
      return false unless s.byteslice(from, 4).to_s == "127."

      Request.dotted_quad?(s, from)
    end

    # Whether `s` starts with "::ffff:" in either case (bytes compared, so
    # no downcase of a String that may not be valid UTF-8).
    def self.mapped_prefix?(s)
      return false if s.bytesize < 8
      return false unless s.getbyte(0) == 58 && s.getbyte(1) == 58 && s.getbyte(6) == 58

      i = 2
      while i < 6
        b = s.getbyte(i)
        return false unless b == 102 || b == 70

        i += 1
      end
      true
    end

    # Four decimal parts of one to three digits, each at most 255,
    # separated by dots, from byte `from` to the end of `s`.
    def self.dotted_quad?(s, from)
      parts = 0
      digits = 0
      value = 0
      i = from
      n = s.bytesize
      while i < n
        b = s.getbyte(i)
        if b == 46
          return false if digits == 0

          parts += 1
          digits = 0
          value = 0
        elsif b >= 48 && b <= 57
          digits += 1
          value = value * 10 + (b - 48)
          return false if digits > 3 || value > 255
        else
          return false
        end
        i += 1
      end
      digits > 0 && parts == 3
    end

    # The raw Cookie header; parse it with {Cookies.parse}.
    # @return [String] `""` when absent
    # @api public
    def cookie_header
      header("cookie") || ""
    end
  end
end
