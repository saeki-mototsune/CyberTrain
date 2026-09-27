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
    class Client
      FORM_TYPE = "application/x-www-form-urlencoded"
      REMOTE_ADDR = "127.0.0.1"

      attr_reader :response, :cookies

      def initialize(app)
        @app = app
        @response = Response.new
        @cookies = {}
      end

      def get(path, headers = {})
        request("GET", path, "", headers)
      end

      def post(path, params = {}, headers = {})
        form_request("POST", path, params, headers)
      end

      def patch(path, params = {}, headers = {})
        form_request("PATCH", path, params, headers)
      end

      def put(path, params = {}, headers = {})
        form_request("PUT", path, params, headers)
      end

      def delete(path, params = {}, headers = {})
        form_request("DELETE", path, params, headers)
      end

      # Runs one request through the app and returns (and remembers) its
      # Response. Header names are lowercased as HttpParser would.
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

def assert_redirected_to(response, path)
  Cybertrain::Test.count_assertion
  status = response.status
  flunk("expected a redirect to #{path.inspect}, got #{status}") if status < 300 || status > 399
  location = response.header("Location")
  flunk("expected a redirect to #{path.inspect}, got #{location.inspect}") unless location == path
end
