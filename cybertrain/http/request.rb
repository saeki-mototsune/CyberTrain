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
    # The cached tree is READ-ONLY for every holder, this one included: it is
    # the same object for every reader, so a middleware that keeps it (to
    # rebuild a canonical or pagination URL after `super`, say) must find the
    # query keys and nothing else, however much the Router assembled after it.
    # The Router therefore builds ctx.params as a fresh Params and merges this
    # tree into it (Router#assemble_params) rather than taking it over: round
    # 17 dropped that copy for speed, round 18 took the tree instead, which
    # kept readers AFTER routing correct but left a reader that fetched the
    # tree BEFORE routing holding the Router's own mutated object (form
    # fields, `_method`, `authenticity_token`, captures). The copy costs one
    # more tree build, bounded by the Query limits (at most MAX_PAIRS pairs
    # of MAX_DEPTH levels), and nothing else can corrupt a cache. The same
    # goes for #form_params. The cache ivars start as nil and are assigned
    # from a method's result, as a nullable ivar must be (NOTES rule 7).
    def query_params
      cached = @query_params_cache
      return cached unless cached.nil?

      parsed = Query.parse(@query_string)
      @query_params_cache = parsed
      parsed
    end

    # The body parsed into Params, once per request (see #query_params; the
    # tree is read-only for every holder). Only meaningful for a form body:
    # callers check #form? first, as they always did, and any other body is
    # not parsed at all.
    def form_params
      cached = @form_params_cache
      return cached unless cached.nil?

      parsed = Query.parse(@body)
      @form_params_cache = parsed
      parsed
    end

    def cookie_header
      header("cookie") || ""
    end
  end
end
