require "cybertrain/http/query"

module Cybertrain
  # One incoming HTTP request. Header names are expected lowercased (as
  # HttpParser produces them), but #header also finds mixed-case keys so
  # hand-built requests in tests behave the same.
  class Request
    attr_reader :method, :path, :query_string, :headers, :body, :remote_addr, :http_version

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
      @query_params_cache = nil
      @form_params_cache = nil
      @path_segments_cache = nil
    end

    # Used by MethodOverride to turn a POST form into PATCH/PUT/DELETE.
    def override_method!(m)
      @method = m.upcase
    end

    def header(name)
      key = name.downcase
      value = @headers[key]
      return value unless value.nil?

      @headers.each do |k, v|
        return v if k.downcase == key
      end
      nil
    end

    # 0 when the header is absent or not a plain non-negative integer.
    # An overlong all-digit value saturates to 9223372036854775807 under
    # Spinel (CRuby would return a Bignum); the Server's 413 limit rejects it.
    def content_length
      value = header("content-length")
      return 0 if value.nil? || value.empty?
      return 0 unless value.bytes.all? { |b| b >= 48 && b <= 57 }

      value.to_i
    end

    # Media type only: "text/html; charset=utf-8" -> "text/html".
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

    def get?
      @method == "GET"
    end

    def post?
      @method == "POST"
    end

    def head?
      @method == "HEAD"
    end

    def patch?
      @method == "PATCH"
    end

    def put?
      @method == "PUT"
    end

    def delete?
      @method == "DELETE"
    end

    def form?
      content_type == "application/x-www-form-urlencoded"
    end

    def json?
      content_type == "application/json"
    end

    # The query string parsed into Params, once per request. MethodOverride,
    # CsrfProtection and the Router all read it, and every parse decodes each
    # pair and builds a tree, so the cost the Query limits bound is paid once,
    # not three times. A parse that raises (QueryTooMany, QueryMalformed, ...)
    # is not cached: it propagates and the request ends as a 400.
    #
    # The cached tree is shared by MethodOverride, CsrfProtection and the
    # Router (and any middleware that keeps it, say to rebuild a pagination
    # URL after `super`), so a holder that mutated it would silently change
    # what the others see. It is therefore marked read_only! before it is
    # cached: set_value, set_path, child!, merge! and the rest raise
    # RuntimeError instead (a holder that needs to change params builds its
    # own: Params.new.merge!(request.query_params)). The Router's per-request
    # `Params.new` + merge! (Router#assemble_params) is the MERGE of three
    # sources (query, form, path captures) into the controller's own mutable
    # params, not a defensive copy of this tree, so it stays: merge! copies
    # from a read-only source into a fresh writable tree. The same goes for
    # #form_params. The cache ivars start as nil and are assigned from a
    # method's result, as a nullable ivar must be (NOTES rule 7).
    def query_params
      cached = @query_params_cache
      return cached unless cached.nil?

      parsed = Query.parse(@query_string).read_only!
      @query_params_cache = parsed
      parsed
    end

    # The body parsed into Params, once per request (see #query_params; the
    # tree is read_only! for every holder). Only meaningful for a form body:
    # callers check #form? first, as they always did, and any other body is
    # not parsed at all.
    def form_params
      cached = @form_params_cache
      return cached unless cached.nil?

      parsed = Query.parse(@body).read_only!
      @form_params_cache = parsed
      parsed
    end

    # The path split into percent-decoded segments, once per request:
    # "/posts/1/" -> ["posts", "1"]. Static (every GET/HEAD) and the Router
    # both need them, and decoding a segment containing a "%" costs four byte
    # scans plus allocations (check_valid!, valid_escapes?, decode_valid and
    # its own check_valid! on the output), so it is done once, like
    # #query_params. The decision to answer 400 for an invalid UTF-8 byte
    # sequence in a decoded segment (QueryMalformed) is therefore made in one
    # place, by whichever reader comes first (Static for GET/HEAD, the Router
    # otherwise); a raise is not cached, so every later call raises again and
    # the request still ends as that 400. The returned Array is the cached
    # one, shared by both readers: callers must not mutate it (neither does,
    # they only read, compare and join); one that needs to change it dups it.
    # The ivar starts as nil and is assigned from a method's result (NOTES
    # rule 7).
    def path_segments
      cached = @path_segments_cache
      return cached unless cached.nil?

      parsed = Request.split_path(@path)
      @path_segments_cache = parsed
      parsed
    end

    # "/posts/1/" -> ["posts", "1"]; each segment is percent-decoded, but a
    # "+" stays a plus (it only means space in query strings and forms).
    # A segment with a malformed escape ("%ZZ", a trailing "%" or "%2") is
    # kept literal: CRuby's decoder raises ArgumentError on it while Spinel's
    # silently yields a NUL byte, so neither runtime ever sees it. That
    # policy is why the escapes are scanned twice here (Query.valid_escapes?,
    # then the decoding loop): the loop raises QueryMalformed on a malformed
    # escape, which is right for a query string (Query.decode no longer
    # pre-scans) but would turn a path like "/50%off" into a 400 instead of
    # a 404 by non-match. The decoding is the byte-chunked loop of query
    # strings with "+" left alone: URI.decode_www_form_component on a whole
    # segment is quadratic on non-ASCII text under Spinel (NOTES rule 49), and
    # Static routes every GET/HEAD through the segments, anonymous requests
    # included, so a ~60 KB segment (inside the 64 KB head limit) holding one
    # non-ASCII byte and one "%41" cost ~0.5 s of CPU per request. The same
    # call replaces the old `gsub("+", "%2B")` pass over the segment.
    #
    # An invalid UTF-8 byte sequence in a segment that is decoded ("%81", or a
    # raw "\x81" next to a "%") is QueryMalformed, answered 400 through
    # ErrorPages (Rails answers 400 for an invalid path encoding too). The
    # segment is validated BEFORE valid_escapes? asks, because that scan's
    # byte offsets are only character boundaries in a valid String (CRuby's
    # byteindex raises IndexError otherwise, NOTES rule 52). A segment
    # without any "%" is never handed to the decoder, so a raw invalid byte
    # there stays literal (404 by non-match), as before.
    #
    # Lives here, not in Router: Router requires Middleware -> Context ->
    # Request, so Request requiring Router would be a require cycle (and
    # CRuby 3.3 only warns about it, half-loading one of the two). Router
    # keeps `Router.split_path` as a one-line delegate for its callers.
    def self.split_path(path)
      segments = []
      path.split("/").each do |seg|
        next if seg.empty?

        if seg.byteindex("%").nil?
          segments << seg
        else
          Query.check_valid!(seg)
          segments << (Query.valid_escapes?(seg) ? Query.decode_valid(seg, false) : seg)
        end
      end
      segments
    end

    def cookie_header
      header("cookie") || ""
    end
  end
end
