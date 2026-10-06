require "cybertrain/test"
require "cybertrain/context"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/query"

module Cybertrain
  module Test
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
        when :unprocessable_entity then [422, 422]
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
