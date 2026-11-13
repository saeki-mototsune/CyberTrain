require "cybertrain/test"
require "cybertrain/context"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/query"
require "cybertrain/generator/url_support"

module Cybertrain
  module Test
    # One file for {Client#post_multipart}: the name of its form field, the
    # filename and content type a browser would send, and its bytes.
    # @example
    #   png = Cybertrain::Test.binary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 255])
    #   client.post_multipart("/posts", { "authenticity_token" => token },
    #                         [Cybertrain::Test::Upload.new("post[cover]", "cover.png", "image/png", png)])
    #
    # As a value in an integration test's `params:` (what
    # {ActionDispatch::IntegrationTest#fixture_file_upload} answers) its key
    # there names the field, so `field` may be `""`:
    # @example
    #   post posts_url, params: { post: { cover: Cybertrain::Test::Upload.new("", "../evil.png", "image/png", png) } }
    # @api public
    class Upload
      # @return [String] the form field name, as in `post[cover]`
      # @api public
      attr_reader :field

      # @return [String] the filename the browser reports
      # @api public
      attr_reader :filename

      # @return [String] the declared Content-Type of the part
      # @api public
      attr_reader :content_type

      # @return [String] the file's bytes (binary)
      # @api public
      attr_reader :data

      # @param field [String]
      # @param filename [String]
      # @param content_type [String]
      # @param data [String] binary bytes; see {Test.binary}
      # @api public
      def initialize(field, filename, content_type, data)
        @field = field
        @filename = filename
        @content_type = content_type
        @data = data
      end
    end

    # All 256 byte values in order, the source {Test.binary} slices from.
    # Bytes are made by slicing a table, never by appending `n.chr` to a
    # UTF-8 buffer (the buffer would grow a character, not a byte, past
    # 0x7F, and a NUL would end it under Spinel, NOTES rule 60).
    BYTE_TABLE = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2A\x2B\x2C\x2D\x2E\x2F\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3A\x3B\x3C\x3D\x3E\x3F\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4A\x4B\x4C\x4D\x4E\x4F\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5A\x5B\x5C\x5D\x5E\x5F\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6A\x6B\x6C\x6D\x6E\x6F\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7A\x7B\x7C\x7D\x7E\x7F\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8D\x8E\x8F\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9A\x9B\x9C\x9D\x9E\x9F\xA0\xA1\xA2\xA3\xA4\xA5\xA6\xA7\xA8\xA9\xAA\xAB\xAC\xAD\xAE\xAF\xB0\xB1\xB2\xB3\xB4\xB5\xB6\xB7\xB8\xB9\xBA\xBB\xBC\xBD\xBE\xBF\xC0\xC1\xC2\xC3\xC4\xC5\xC6\xC7\xC8\xC9\xCA\xCB\xCC\xCD\xCE\xCF\xD0\xD1\xD2\xD3\xD4\xD5\xD6\xD7\xD8\xD9\xDA\xDB\xDC\xDD\xDE\xDF\xE0\xE1\xE2\xE3\xE4\xE5\xE6\xE7\xE8\xE9\xEA\xEB\xEC\xED\xEE\xEF\xF0\xF1\xF2\xF3\xF4\xF5\xF6\xF7\xF8\xF9\xFA\xFB\xFC\xFD\xFE\xFF".b

    # A binary String from a list of byte values, for file contents in a
    # test: NUL and 0x80..0xFF come out as exactly those bytes on CRuby and
    # under Spinel.
    # @example
    #   Cybertrain::Test.binary([0x89, 0x50, 0x4E, 0x47, 0, 255]).bytesize   # => 6
    # @param ints [Array<Integer>] each 0..255
    # @return [String] binary
    # @raise [ArgumentError] for a value outside 0..255
    # @api public
    def self.binary(ints)
      out = +""
      i = 0
      while i < ints.length
        n = ints[i]
        raise ArgumentError, "byte value out of range: #{n}" if n < 0 || n > 255

        out << BYTE_TABLE.byteslice(n, 1)
        i += 1
      end
      out.b
    end

    # The Sink {Client#get_stream} hands a writer: it keeps what is written
    # and reports itself closed once `events` events were written or the
    # timeout passed, so the writer's loop ends.
    class MemorySink < Cybertrain::Sink
      def initialize(events, timeout)
        @closed = false
        @chunked = false
        @broken = false
        @write_timeout = 0
        @memory = +""
        @memory_events = 0
        @memory_wanted = events
        @memory_deadline = Clock.monotonic + timeout.to_f
      end

      def write(bytes)
        return nil if closed?

        data = bytes.to_s
        @memory << data
        @memory_events += 1 unless data.start_with?(":")
        @closed = true if @memory_events >= @memory_wanted
        nil
      end

      def closed?
        @closed = true if Clock.monotonic >= @memory_deadline
        @closed
      end

      def wait_closed(seconds)
        return true if closed?

        left = @memory_deadline - Clock.monotonic
        wait = seconds.to_f
        wait = left if left < wait
        sleep wait if wait > 0
        closed?
      end

      # What was written.
      def memory_text
        @memory
      end
    end

    # A {Client}'s cookie jar: each cookie's raw (still percent-encoded)
    # value by name, as the Set-Cookie headers so far left it. A name may be
    # given as a String or a Symbol (`cookies[:user]` is `cookies["user"]`,
    # as in Rails' integration tests). A cookie whose `Max-Age` or
    # `Expires` has passed under {Cybertrain::Clock} (so also after
    # `travel_to` past it) is gone: not read, not listed, not sent, as a
    # browser (and Rack::Test) would. A cookie a test writes with `[]=`
    # has no lifetime.
    # @example
    #   client.get("/login")
    #   client.cookies[:user]            # => "alice+smith"
    #   client.cookies["theme"] = "dark"
    # @api public
    class ClientCookies
      def initialize
        @jar_values = { "" => "" }
        @jar_values.delete("")
        # Epoch second from which each cookie is expired, -1 for none.
        @jar_expires = { "" => 0 }
        @jar_expires.delete("")
      end

      # The cookie's raw value, nil when there is none (or it expired).
      # @param name [String, Symbol]
      # @return [String, nil]
      # @api public
      def [](name)
        key = name.to_s
        return nil unless jar_live?(key)

        @jar_values[key]
      end

      # Sets a cookie for the next requests (raw: percent-encode it as a
      # server would), with no lifetime.
      # @param name [String, Symbol]
      # @param value [String]
      # @return [String]
      # @api public
      def []=(name, value)
        jar_store(name.to_s, value.to_s, -1)
      end

      # Whether the cookie is there (and not expired).
      # @param name [String, Symbol]
      # @return [Boolean]
      # @api public
      def key?(name)
        jar_live?(name.to_s)
      end

      # Removes the cookie; answers the value it had (nil when none).
      # @param name [String, Symbol]
      # @return [String, nil]
      # @api public
      def delete(name)
        key = name.to_s
        live = jar_live?(key)
        @jar_expires.delete(key)
        value = @jar_values.delete(key)
        live ? value : nil
      end

      # The names of the cookies there, in the order they were first set.
      # @return [Array<String>]
      # @api public
      def keys
        names = Array.new(0) { "" }
        @jar_values.each_key { |key| names << key if jar_live?(key) }
        names
      end

      # How many cookies are there.
      # @return [Integer]
      # @api public
      def size
        keys.length
      end

      # Whether no cookie is there.
      # @return [Boolean]
      # @api public
      def empty?
        keys.empty?
      end

      # The cookies as a Hash, name to raw value.
      # @return [Hash{String => String}]
      # @api public
      def to_h
        out = { "" => "" }
        out.delete("")
        keys.each { |key| out[key] = @jar_values[key].to_s }
        out
      end

      # The Cookie header a request carries: `a=1; b=2`.
      # @return [String]
      # @api private
      def jar_header
        keys.map { |key| "#{key}=#{@jar_values[key]}" }.join("; ")
      end

      # Keeps `value` under `name`, expired from `expires_at` (an epoch
      # second; -1 for never).
      # @return [String] value
      # @api private
      def jar_store(name, value, expires_at)
        @jar_values[name] = value
        @jar_expires[name] = expires_at
        value
      end

      # Whether `name` is there and not past its expiry under the Clock.
      # @api private
      def jar_live?(name)
        return false unless @jar_values.key?(name)

        at = @jar_expires[name]
        return true if at.nil? || at < 0

        Cybertrain::Clock.now.to_i < at
      end
    end

    # Drives an App (or a bare Router) in-process, the way Rails integration
    # tests do: no socket, one Context per request, and a cookie jar that
    # carries Set-Cookie values into the next request's Cookie header.
    #
    # Sessions, flash and CSRF behave as behind a browser: a form POST needs
    # the `authenticity_token` from a page the client rendered. Redirects
    # are not followed unless you call {#follow_redirect!}. Requires
    # `require "cybertrain/test/client"` (which also loads {Test}).
    # @example
    #   # Cybertrain::Test.app is the application `cybertrain test` booted;
    #   # BlogTestHelper is examples/blog/test/support/blog_test_helper.rb
    #   client = Cybertrain::Test::Client.new(Cybertrain::Test.app)
    #   client.get("/articles/new")
    #   res = client.post("/articles", { "authenticity_token" => BlogTestHelper.form_token(client.response.body),
    #                                    "article[title]" => "Hello Rails",
    #                                    "article[body]" => "I am on Rails! This is my first article." })
    #   assert_response res, :see_other
    #   client.follow_redirect!
    #   assert_includes client.response.body, "Hello Rails"
    # @api public
    class Client
      FORM_TYPE = "application/x-www-form-urlencoded"
      REMOTE_ADDR = "127.0.0.1"
      # The Host every request carries unless a test sends another.
      TEST_HOST = "www.example.com"

      # The last response.
      # @return [Response]
      # @api public
      attr_reader :response

      # The cookie jar: name (a String or a Symbol) to raw (still
      # percent-encoded) value; expired cookies are gone ({ClientCookies}).
      # @return [ClientCookies]
      # @api public
      attr_reader :cookies

      # The address the requests come from, `request.remote_addr` in the app:
      # "127.0.0.1" (REMOTE_ADDR) unless a test sets another, to see what a
      # page does for a client on another machine (`request.loopback?`).
      # @example
      #   client.peer_address = "203.0.113.7"
      #   assert_response client.get("/setup"), :not_found
      # @return [String]
      # @api public
      attr_accessor :peer_address

      # @param app [Application] a booted application (anything with
      #   `call(ctx)`)
      # @api public
      def initialize(app)
        @app = app
        @response = Response.new
        @cookies = ClientCookies.new
        @boundary_counter = 0
        @peer_address = REMOTE_ADDR
      end

      # Points this client (and its cookie jar) at another application:
      # ActionDispatch::IntegrationTest#with_forgery_protection's.
      # @param app [Application]
      # @api private
      def client_app=(app)
        @app = app
      end

      # @param path [String] with its query string, if any (`"/articles?page=2"`)
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def get(path, headers = {})
        request("GET", path, "", headers)
      end

      # Sends `params` as a urlencoded form. Keys are written as a browser
      # would (`"article[title]"`); for PATCH/DELETE from a form, add
      # `"_method" => "patch"` or call {#patch} / {#delete}.
      # @param path [String]
      # @param params [Hash{String => String}]
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def post(path, params = {}, headers = {})
        form_request("POST", path, params, headers)
      end

      # @param path [String]
      # @param params [Hash{String => String}]
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def patch(path, params = {}, headers = {})
        form_request("PATCH", path, params, headers)
      end

      # @param path [String]
      # @param params [Hash{String => String}]
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def put(path, params = {}, headers = {})
        form_request("PUT", path, params, headers)
      end

      # @param path [String]
      # @param params [Hash{String => String}]
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def delete(path, params = {}, headers = {})
        form_request("DELETE", path, params, headers)
      end

      # Sends a `multipart/form-data` POST, the way a browser sends a form with
      # file fields: `fields` as text parts (put the `authenticity_token` there
      # like any form), then each Upload as a file part. The boundary is chosen
      # so that no part contains it.
      # @example
      #   client.post_multipart("/posts", { "authenticity_token" => token, "post[title]" => "Hi" },
      #                         [Cybertrain::Test::Upload.new("post[cover]", "cover.png", "image/png", png)])
      # @param path [String]
      # @param fields [Hash{String => String}] text parts
      # @param uploads [Array<Upload>] file parts
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def post_multipart(path, fields = {}, uploads = [], headers = {})
        multipart_request(path, fields, uploads, headers)
      end

      # Like {#post_multipart} for an edit form: a POST that carries the text
      # part `_method=patch`, which MethodOverride turns into a PATCH (as a
      # browser form does).
      # @param path [String]
      # @param fields [Hash{String => String}] text parts
      # @param uploads [Array<Upload>] file parts
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def patch_multipart(path, fields = {}, uploads = [], headers = {})
        with_method = {}
        fields.each { |k, v| with_method[k] = v }
        with_method["_method"] = "patch"
        multipart_request(path, with_method, uploads, headers)
      end

      # GETs a streaming path (the stream endpoint, an action that calls
      # {Controller#stream}) and runs its writer against an in-memory sink
      # until `events` events (SSE comments such as `: ping` do not count)
      # have been written or `timeout` seconds have passed. The Response's
      # body is then what was written. A response that does not stream is
      # returned as {#get} returns it.
      # @example
      #   Cybertrain::Stream.broadcast("alerts", "hi")
      #   res = client.get_stream("/cybertrain/stream?s=#{token}", events: 1, headers: { "last-event-id" => "0" })
      #   assert_includes res.body, "data: hi"
      # @param path [String]
      # @param events [Integer]
      # @param timeout [Numeric] seconds
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def get_stream(path, events:, timeout: 2, headers: {})
        response = request("GET", path, "", headers)
        writer = response.body_writer
        return response if writer.nil?

        sink = MemorySink.new(events, timeout)
        writer.write_body(sink)
        response.body = sink.memory_text
        response
      end

      # Runs one request through the app and returns (and remembers) its
      # Response. Header names are lowercased as HttpParser would.
      # Any method and body, e.g. a JSON request.
      # @example
      #   client.request("POST", "/api/notes", '{"title":"x"}', { "content-type" => "application/json" })
      # @param method [String]
      # @param path [String]
      # @param body [String]
      # @param headers [Hash{String => String}]
      # @return [Response]
      # @api public
      def request(method, path, body = "", headers = {})
        head = {}
        headers.each { |k, v| head[k.downcase] = v }
        head["host"] = TEST_HOST unless head.key?("host")
        head["content-length"] = body.bytesize.to_s unless body.empty?
        unless head.key?("cookie")
          sent = @cookies.jar_header
          head["cookie"] = sent unless sent.empty?
        end
        ctx = Context.new(Request.new(method, path, head, body, @peer_address))
        @app.call(ctx)
        @response = ctx.response
        store_cookies(@response)
        @response
      end

      # GETs the Location of the last response; an absolute URL is reduced
      # to its path and query so it stays inside the app, and the fragment
      # (`#comments`) is never sent, as a browser never sends one.
      # @return [Response]
      # @raise [AssertionFailed] when the last response was not a redirect
      #   (a 3xx with a Location)
      # @api public
      def follow_redirect!
        get(Client.local_path(Client.redirect_location(@response)))
      end

      # The Location of a redirect response; fails the test (AssertionFailed)
      # for any other response: what both forms of follow_redirect! check.
      # @param response [Response]
      # @return [String]
      # @api private
      def self.redirect_location(response)
        location = response.header("Location")
        status = response.status
        if location.nil? || status < 300 || status > 399
          message = "follow_redirect!: the last response was #{status}, not a redirect (3xx with a Location)"
          raise AssertionFailed, message
        end
        location.to_s
      end

      # The target a request sends for a path or a URL: its path and query,
      # never its fragment. "http://example.com/posts?x=1#c" -> "/posts?x=1",
      # "http://example.com?x=1" -> "/?x=1", "/a#c" -> "/a".
      # @param location [String]
      # @return [String]
      # @api private
      def self.local_path(location)
        text = location.to_s
        hash = text.index("#")
        text = text[0, hash].to_s unless hash.nil?
        scheme = text.index("://")
        return text if scheme.nil?

        from = scheme + 3
        slash = text.index("/", from)
        query = text.index("?", from)
        return text[slash, text.length - slash].to_s if !slash.nil? && (query.nil? || slash < query)
        return "/" if query.nil?

        "/#{text[query, text.length - query]}"
      end

      # The local path of a request or redirect target this application
      # answers: a path as it is; an absolute URL on the test host
      # (TEST_HOST) or on Cybertrain.url_root's host (what the `*_url`
      # helpers write) reduced to its path; a URL on any other host
      # unchanged (it still has its `://`).
      # @example
      #   Client.local_target("http://localhost:3000/articles/1")   # => "/articles/1"
      #   Client.local_target("https://elsewhere.example/x")        # => "https://elsewhere.example/x"
      # @param target [String]
      # @return [String]
      # @api private
      def self.local_target(target)
        return target if target.index("://").nil?

        host = url_host_of(target)
        return target unless host == TEST_HOST || host == url_host_of(Cybertrain.url_root)

        local_path(target)
      end

      # The epoch second from which a Set-Cookie's cookie is expired, -1
      # for a session cookie: `Max-Age` (a number of seconds; 0 or less is
      # already expired) from `now`, else `Expires` (an HTTP date; one
      # that does not parse is ignored).
      # @param parts [Array<String>] the Set-Cookie split at `;`
      # @param now [Integer] epoch seconds
      # @return [Integer]
      # @api private
      def self.cookie_expiry(parts, now)
        expires = -1
        i = 1
        while i < parts.length
          attr = parts[i].to_s.strip
          eq = attr.index("=")
          unless eq.nil?
            key = attr[0, eq].to_s.strip.downcase
            value = attr[eq + 1, attr.length - eq - 1].to_s.strip
            # RFC 6265 5.2.2: digits, or `-` and digits (expired at once);
            # anything else and the attribute is ignored.
            if key == "max-age"
              digits = value.start_with?("-") ? value[1, value.length - 1].to_s : value
              if Client.all_digits?(digits)
                return now if value.start_with?("-")

                return now + digits.to_i
              end
            end
            if key == "expires"
              at = Request.parse_http_date(value)
              expires = at if at >= 0
            end
          end
          i += 1
        end
        expires
      end

      # Whether `text` is one or more ASCII digits (read through a fresh
      # local, NOTES rule 62).
      # @api private
      def self.all_digits?(text)
        s = text.to_s
        return false if s.empty?

        i = 0
        while i < s.bytesize
          b = s.getbyte(i)
          return false if b < 48 || b > 57

          i += 1
        end
        true
      end

      # "https://Example.com:3000/x?y" -> "example.com:3000"; "" without a scheme.
      def self.url_host_of(url)
        scheme = url.index("://")
        return "" if scheme.nil?

        from = scheme + 3
        stop = url.length
        ["/", "?", "#"].each do |mark|
          at = url.index(mark, from)
          stop = at if !at.nil? && at < stop
        end
        url[from, stop - from].to_s.downcase
      end

      # The status a Rails-style symbol stands for, as [low, high]; [0, 0]
      # when the symbol is unknown. Every Symbol of
      # Controller::STATUS_SYMBOLS is here with its one code (the same list,
      # kept by hand: the test layer loads without the Controller;
      # test/test_integration.rb compares the two), plus :success (2xx),
      # :redirect (3xx), :missing (404, Rails' name) and :error (exactly
      # 500, as the earlier plan fixed it, test/client.rb; Rails takes any
      # 5xx). A case, not a Hash, so a Symbol the program never mentions
      # elsewhere still compiles to a comparison.
      def self.status_range(symbol)
        case symbol
        when :success then [200, 299]
        when :redirect then [300, 399]
        when :missing then [404, 404]
        when :error then [500, 500]
        when :continue then [100, 100]
        when :switching_protocols then [101, 101]
        when :processing then [102, 102]
        when :early_hints then [103, 103]
        when :ok then [200, 200]
        when :created then [201, 201]
        when :accepted then [202, 202]
        when :non_authoritative_information then [203, 203]
        when :no_content then [204, 204]
        when :reset_content then [205, 205]
        when :partial_content then [206, 206]
        when :multi_status then [207, 207]
        when :already_reported then [208, 208]
        when :im_used then [226, 226]
        when :multiple_choices then [300, 300]
        when :moved_permanently then [301, 301]
        when :found then [302, 302]
        when :see_other then [303, 303]
        when :not_modified then [304, 304]
        when :use_proxy then [305, 305]
        when :temporary_redirect then [307, 307]
        when :permanent_redirect then [308, 308]
        when :bad_request then [400, 400]
        when :unauthorized then [401, 401]
        when :payment_required then [402, 402]
        when :forbidden then [403, 403]
        when :not_found then [404, 404]
        when :method_not_allowed then [405, 405]
        when :not_acceptable then [406, 406]
        when :proxy_authentication_required then [407, 407]
        when :request_timeout then [408, 408]
        when :conflict then [409, 409]
        when :gone then [410, 410]
        when :length_required then [411, 411]
        when :precondition_failed then [412, 412]
        when :content_too_large then [413, 413]
        when :uri_too_long then [414, 414]
        when :unsupported_media_type then [415, 415]
        when :range_not_satisfiable then [416, 416]
        when :expectation_failed then [417, 417]
        when :misdirected_request then [421, 421]
        when :unprocessable_content then [422, 422]
        when :locked then [423, 423]
        when :failed_dependency then [424, 424]
        when :too_early then [425, 425]
        when :upgrade_required then [426, 426]
        when :precondition_required then [428, 428]
        when :too_many_requests then [429, 429]
        when :request_header_fields_too_large then [431, 431]
        when :unavailable_for_legal_reasons then [451, 451]
        when :internal_server_error then [500, 500]
        when :not_implemented then [501, 501]
        when :bad_gateway then [502, 502]
        when :service_unavailable then [503, 503]
        when :gateway_timeout then [504, 504]
        when :http_version_not_supported then [505, 505]
        when :variant_also_negotiates then [506, 506]
        when :insufficient_storage then [507, 507]
        when :loop_detected then [508, 508]
        when :not_extended then [510, 510]
        when :network_authentication_required then [511, 511]
        when :payload_too_large then [413, 413]
        when :request_entity_too_large then [413, 413]
        when :unprocessable_entity then [422, 422]
        when :request_uri_too_long then [414, 414]
        when :requested_range_not_satisfiable then [416, 416]
        else [0, 0]
        end
      end

      private

      def form_request(method, path, params, headers)
        return request(method, path, "", headers) if params.empty?

        with_type = { "content-type" => FORM_TYPE }
        headers.each { |k, v| with_type[k.downcase] = v }
        request(method, path, Query.encode(params), with_type)
      end

      # Builds the body with `<<` only, every piece as binary (".b"): a text
      # field with an accent next to a file with bytes >= 0x80 would otherwise
      # be an encoding conflict on CRuby. The boundary is bumped until no part
      # contains it (a file that holds the default one is the case).
      def multipart_request(path, fields, uploads, headers)
        boundary = next_boundary
        until boundary_free?(boundary, fields, uploads)
          boundary = next_boundary
        end
        body = "".b
        fields.each do |name, value|
          body << "--".b << boundary.b << "\r\nContent-Disposition: form-data; name=\"".b << name.b
          body << "\"\r\n\r\n".b << value.b << "\r\n".b
        end
        uploads.each do |up|
          body << "--".b << boundary.b << "\r\nContent-Disposition: form-data; name=\"".b << up.field.b
          body << "\"; filename=\"".b << up.filename.b << "\"\r\nContent-Type: ".b << up.content_type.b
          body << "\r\n\r\n".b << up.data.b << "\r\n".b
        end
        body << "--".b << boundary.b << "--\r\n".b
        with_type = { "content-type" => "multipart/form-data; boundary=#{boundary}" }
        headers.each { |k, v| with_type[k.downcase] = v }
        request("POST", path, body, with_type)
      end

      def next_boundary
        @boundary_counter += 1
        "----CybertrainTestBoundary#{@boundary_counter}"
      end

      def boundary_free?(boundary, fields, uploads)
        fields.each do |name, value|
          return false unless value.b.byteindex(boundary).nil?
        end
        uploads.each do |up|
          return false unless up.data.b.byteindex(boundary).nil?
        end
        true
      end

      # Keeps each Set-Cookie's raw name=value (still percent-encoded, as a
      # browser would) with its expiry: `Max-Age` seconds from the Clock's
      # now (it wins over `Expires`, as RFC 6265 says), else the `Expires`
      # date; a cookie already expired (`Max-Age=0`, a past date) is
      # dropped.
      def store_cookies(response)
        now = Cybertrain::Clock.now.to_i
        response.cookies.each do |set_cookie|
          parts = set_cookie.split(";")
          pair = parts[0].to_s.strip
          eq = pair.index("=")
          next if eq.nil? || eq == 0

          name = pair[0, eq]
          expires_at = Client.cookie_expiry(parts, now)
          if expires_at >= 0 && expires_at <= now
            @cookies.delete(name)
          else
            @cookies.jar_store(name, pair[(eq + 1)..-1].to_s, expires_at)
          end
        end
      end
    end

    # `assert_response`, both forms (the top-level
    # `assert_response(response, expected)` and
    # ActionDispatch::IntegrationTest#assert_response(expected)): passes
    # when the status is `expected` (an Integer) or in the range a Symbol
    # stands for ({Client.status_range}).
    # @param response [Cybertrain::Response]
    # @param expected [Integer, Symbol]
    # @return [nil]
    # @api private
    def self.check_response(response, expected)
      count_assertion
      status = response.status
      case expected
      when Integer
        return nil if status == expected

        text = "expected response #{expected}, got #{status}"
        fail_with(text)
      when Symbol
        range = Client.status_range(expected)
        if range[0] == 0
          unknown = "unknown status symbol #{expected.inspect}"
          fail_with(unknown)
        end
        return nil if status >= range[0] && status <= range[1]

        text = "expected response #{expected.inspect}, got #{status}"
        fail_with(text)
      else
        text = "expected an Integer or Symbol status, got #{expected.inspect}"
        fail_with(text)
      end
      nil
    end

    # `assert_redirected_to`, both forms: passes when the response is a 3xx
    # whose Location is `path`, after reducing either side that is an
    # absolute URL on this application's host to its path
    # ({Client.local_target}); a URL on another host must match exactly.
    # @param response [Cybertrain::Response]
    # @param path [String]
    # @return [nil]
    # @api private
    def self.check_redirect(response, path)
      count_assertion
      status = response.status
      if status < 300 || status > 399
        text = "expected a redirect to #{path.inspect}, got #{status}"
        fail_with(text)
      end
      location = response.header("Location")
      # An absolute URL on this application's host and its path are the
      # same target (`redirect_to article_path(a)` against
      # `assert_redirected_to article_url(a)`, and the other way round).
      return nil if !location.nil? && Client.local_target(location) == Client.local_target(path)

      moved = "expected a redirect to #{path.inspect}, got #{location.inspect}"
      fail_with(moved)
      nil
    end
  end
end

# assert_response res, :ok / :not_found / 201 ...; :redirect accepts any 3xx.
#
# Symbols: every one `Controller::STATUS_SYMBOLS` accepts (`:ok`,
# `:created`, `:accepted`, `:no_content`, `:see_other`, `:bad_request`,
# `:unauthorized`, `:forbidden`, `:not_found`, `:conflict`,
# `:payload_too_large`, `:unsupported_media_type`, `:unprocessable_entity`,
# `:too_many_requests`, `:service_unavailable`, ...), each standing for its
# one code, plus `:success` (2xx), `:redirect` (3xx), `:missing` (404)
# and `:error` (exactly 500; Rails takes any 5xx). Needs `cybertrain/test/client`.
# @param response [Cybertrain::Response]
# @param expected [Integer, Symbol]
# @return [void]
# @api public
def assert_response(response, expected)
  Cybertrain::Test.check_response(response, expected)
end

# Passes when the response is a 3xx whose Location is `path`; an absolute
# URL on the application's host (www.example.com, or Cybertrain.url_root's,
# as the `*_url` helpers write) counts as its path, on either side.
# @example
#   assert_redirected_to res, "/articles/#{Article.last.id}"
# @param response [Cybertrain::Response]
# @param path [String]
# @return [void]
# @api public
def assert_redirected_to(response, path)
  Cybertrain::Test.check_redirect(response, path)
end
