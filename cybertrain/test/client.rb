require "cybertrain/test"
require "cybertrain/context"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/query"

module Cybertrain
  module Test
    # One file for {Client#post_multipart}: the name of its form field, the
    # filename and content type a browser would send, and its bytes.
    # @example
    #   png = Cybertrain::Test.binary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 255])
    #   client.post_multipart("/posts", { "authenticity_token" => token },
    #                         [Cybertrain::Test::Upload.new("post[cover]", "cover.png", "image/png", png)])
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

    # Drives an App (or a bare Router) in-process, the way Rails integration
    # tests do: no socket, one Context per request, and a cookie jar that
    # carries Set-Cookie values into the next request's Cookie header.
    #
    # Sessions, flash and CSRF behave as behind a browser: a form POST needs
    # the `authenticity_token` from a page the client rendered. Redirects
    # are not followed unless you call {#follow_redirect!}. Requires
    # `require "cybertrain/test/client"` (which also loads {Test}).
    # @example
    #   # BLOG and BlogTest come from examples/blog/test/support/blog_test.rb
    #   client = Cybertrain::Test::Client.new(BLOG)
    #   client.get("/articles/new")
    #   res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
    #                                    "article[title]" => "Hello Rails",
    #                                    "article[body]" => "I am on Rails! This is my first article." })
    #   assert_response res, :see_other
    #   client.follow_redirect!
    #   assert_includes client.response.body, "Hello Rails"
    # @api public
    class Client
      FORM_TYPE = "application/x-www-form-urlencoded"
      REMOTE_ADDR = "127.0.0.1"

      # The last response.
      # @return [Response]
      # @api public
      attr_reader :response

      # The cookie jar: name to raw (still percent-encoded) value.
      # @return [Hash{String => String}]
      # @api public
      attr_reader :cookies

      # @param app [Application] a booted application (anything with
      #   `call(ctx)`)
      # @api public
      def initialize(app)
        @app = app
        @response = Response.new
        @cookies = {}
        @boundary_counter = 0
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
        head["host"] = "www.example.com" unless head.key?("host")
        head["content-length"] = body.bytesize.to_s unless body.empty?
        head["cookie"] = cookie_header unless @cookies.empty? || head.key?("cookie")
        ctx = Context.new(Request.new(method, path, head, body, REMOTE_ADDR))
        @app.call(ctx)
        @response = ctx.response
        store_cookies(@response)
        @response
      end

      # GETs the Location of the last response; an absolute URL is reduced
      # to its path so it stays inside the app.
      # @return [Response]
      # @raise [RuntimeError] when the last response was not a redirect
      # @api public
      def follow_redirect!
        location = @response.header("Location")
        if location.nil? || @response.status < 300 || @response.status > 399
          raise "not a redirect: last response was #{@response.status}"
        end

        get(Client.local_path(location))
      end

      # "http://example.com/posts?x=1" -> "/posts?x=1"; a path is returned as is.
      def self.local_path(location)
        scheme = location.index("://")
        return location if scheme.nil?

        slash = location.index("/", scheme + 3)
        slash.nil? ? "/" : location[slash..-1].to_s
      end

      # The status a Rails-style symbol stands for, as [low, high]; [0, 0]
      # when the symbol is unknown.
      def self.status_range(symbol)
        case symbol
        when :ok then [200, 200]
        when :success then [200, 299]
        when :created then [201, 201]
        when :no_content then [204, 204]
        when :redirect then [300, 399]
        when :see_other then [303, 303]
        when :bad_request then [400, 400]
        when :forbidden then [403, 403]
        when :not_found then [404, 404]
        when :payload_too_large then [413, 413]
        when :unsupported_media_type then [415, 415]
        when :unprocessable_entity then [422, 422]
        when :too_many_requests then [429, 429]
        when :error then [500, 500]
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

      def cookie_header
        @cookies.map { |name, value| "#{name}=#{value}" }.join("; ")
      end

      # Keeps each Set-Cookie's raw name=value (still percent-encoded, as a
      # browser would) and drops cookies expired with Max-Age=0.
      def store_cookies(response)
        response.cookies.each do |set_cookie|
          parts = set_cookie.split(";")
          pair = parts[0].to_s.strip
          eq = pair.index("=")
          next if eq.nil? || eq == 0

          name = pair[0, eq]
          expired = parts.any? { |attr| attr.strip.downcase == "max-age=0" }
          if expired
            @cookies.delete(name)
          else
            @cookies[name] = pair[(eq + 1)..-1].to_s
          end
        end
      end
    end
  end
end

# assert_response res, :ok / :not_found / 201 ...; :redirect accepts any 3xx.
#
# Symbols: `:ok`, `:success` (2xx), `:created`, `:no_content`, `:redirect`
# (3xx), `:see_other`, `:bad_request`, `:forbidden`, `:not_found`,
# `:payload_too_large` (413), `:unsupported_media_type` (415),
# `:unprocessable_entity`, `:error` (500). Needs `cybertrain/test/client`.
# @param response [Cybertrain::Response]
# @param expected [Integer, Symbol]
# @return [void]
# @api public
def assert_response(response, expected)
  Cybertrain::Test.count_assertion
  status = response.status
  case expected
  when Integer
    flunk("expected response #{expected}, got #{status}") unless status == expected
  when Symbol
    range = Cybertrain::Test::Client.status_range(expected)
    flunk("unknown status symbol #{expected.inspect}") if range[0] == 0
    unless status >= range[0] && status <= range[1]
      flunk("expected response #{expected.inspect}, got #{status}")
    end
  else
    flunk("expected an Integer or Symbol status, got #{expected.inspect}")
  end
end

# Passes when the response is a 3xx whose Location is exactly `path`.
# @example
#   assert_redirected_to res, "/articles/#{Article.last.id}"
# @param response [Cybertrain::Response]
# @param path [String]
# @return [void]
# @api public
def assert_redirected_to(response, path)
  Cybertrain::Test.count_assertion
  status = response.status
  flunk("expected a redirect to #{path.inspect}, got #{status}") if status < 300 || status > 399
  location = response.header("Location")
  flunk("expected a redirect to #{path.inspect}, got #{location.inspect}") unless location == path
end
