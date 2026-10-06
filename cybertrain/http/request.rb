require "cybertrain/http/query"

module Cybertrain
  # One incoming HTTP request. Header names are expected lowercased (as
  # HttpParser produces them), but #header also finds mixed-case keys so
  # hand-built requests in tests behave the same.
  #
  # {Controller#request} in an action. Read parameters through
  # {Controller#params}; the request holds the raw parts. There is no
  # `remote_ip` (no X-Forwarded-For handling), `xhr?`, `format` or `url`.
  # @example
  #   request.header("user-agent")
  #   JSON.parse(request.body) if request.json?   # JSON bodies are not parsed into params
  # @api public
  class Request
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
      key = name.downcase
      value = @headers[key]
      return value unless value.nil?

      @headers.each do |k, v|
        return v if k.downcase == key
      end
      nil
    end

    # The Content-Length header as an Integer.
    #
    # 0 when the header is absent or not a plain non-negative integer.
    # An overlong all-digit value saturates to 9223372036854775807 under
    # Spinel (CRuby would return a Bignum); the Server's 413 limit rejects it.
    # @return [Integer]
    # @api public
    def content_length
      value = header("content-length")
      return 0 if value.nil? || value.empty?
      return 0 unless value.bytes.all? { |b| b >= 48 && b <= 57 }

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

    # What the request exposes of its parameters, each validated once:
    # utf8_query_string and utf8_body (the validated UTF-8 text of the
    # fields, see below), form_value / query_value (one key), and
    # path_segments. There is no cached parameter tree: nobody in the
    # framework asks for one (the Router builds the controller's own with
    # Query.parse_valid, MethodOverride and CsrfProtection read one key). An
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

    # The raw Cookie header; parse it with {Cookies.parse}.
    # @return [String] `""` when absent
    # @api public
    def cookie_header
      header("cookie") || ""
    end
  end
end
