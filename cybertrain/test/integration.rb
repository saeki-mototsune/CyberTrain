# ActionDispatch::IntegrationTest: requests against the application
# `cybertrain test` booted, from a class-form test (spec section 5.1, plan
# decision 6). Each test is a new instance with its own
# Cybertrain::Test::Client, so cookies (the session among them) persist
# from one request to the next within a test and start empty in the next.
# The bundle (gen/tests.rb) includes the application's Gen::UrlHelpers, so
# `article_path(article)` works in a test as in a controller.
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/test/test_case"

module Cybertrain
  module Test
    # What IntegrationTest.new raises when no application was booted.
    NO_APP = "no application booted: IntegrationTest runs in the bundle (cybertrain test)".freeze

    # Nested `params:` as the bracketed keys a browser's form sends:
    # `{ article: { title: "x", tags: { a: "1" } } }` gives
    # `"article[title]" => "x"` and `"article[tags][a]" => "1"`. Keys and
    # values are written with `to_s`; a value may be a String, Symbol,
    # number, true / false or a nested Hash. A key already written with
    # brackets (`"article[title]" => "x"`) is kept as it is.
    # @example
    #   Cybertrain::Test.flatten_params({ article: { title: "New" } })   # => { "article[title]" => "New" }
    # @param params [Hash]
    # @return [Hash{String => String}]
    # @raise [ArgumentError] for any other value (an Array, nil, a model)
    # @api public
    def self.flatten_params(params)
      out = { "" => "" }
      out.delete("")
      flatten_into(out, "", params)
      out
    end

    # Writes params' pairs into out under prefix (`""` at the top).
    # @return [nil]
    # @api private
    def self.flatten_into(out, prefix, params)
      params.each do |k, v|
        key = prefix.empty? ? k.to_s : "#{prefix}[#{k}]"
        case v
        when Hash
          flatten_into(out, key, v)
        when String, Symbol, Integer, Float, TrueClass, FalseClass
          out[key] = v.to_s
        else
          message = "params: values must be Strings or Hashes (got #{v.class.name} at #{key})"
          raise ArgumentError, message
        end
      end
      nil
    end
  end
end

# Rails' namespace for request tests: {ActionDispatch::IntegrationTest}.
# @api public
module ActionDispatch
  # Rails' base class for request tests: `get`, `post`, `patch`, `put`,
  # `delete` and `head` against the booted application, in process (no
  # socket), and assertions on the last response.
  #
  # Each request answers the Cybertrain::Response (Rails answers the
  # status) and becomes {#response}. Forgery protection is off in
  # `cybertrain test` unless config/app.rb sets `csrf` (as in Rails' test
  # environment). A test that wants it on sets
  # `Cybertrain.config.csrf = true`, boots its own Application and makes it
  # Cybertrain::Test.app for the requests of a new instance, then puts the
  # old one back (the middleware is chosen at boot).
  # @example test/controllers/articles_controller_test.rb
  #   require "test_helper"
  #
  #   class ArticlesControllerTest < ActionDispatch::IntegrationTest
  #     test "creates an article" do
  #       assert_difference -> { Article.count }, 1 do
  #         post articles_path, params: { article: { title: "New", body: "A body long enough" } }
  #       end
  #       assert_redirected_to article_path(Article.last)
  #       follow_redirect!
  #       assert_response :success
  #     end
  #   end
  # @api public
  class IntegrationTest < ActiveSupport::TestCase
    # A new client on Cybertrain::Test.app: an empty cookie jar.
    # @raise [RuntimeError] when no application was booted
    # @api public
    def initialize
      app = Cybertrain::Test.app
      if app.nil?
        message = Cybertrain::Test::NO_APP
        raise message
      end
      @integration_client = Cybertrain::Test::Client.new(app)
    end

    # GET; `params:` go in the query string.
    # @param path [String]
    # @param params [Hash] Strings or nested Hashes ({Cybertrain::Test.flatten_params})
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def get(path, params: {}, headers: {})
      integration_response(@integration_client.get(with_query(path, params), headers))
    end

    # POST; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def post(path, params: {}, headers: {})
      integration_response(@integration_client.post(path, Cybertrain::Test.flatten_params(params), headers))
    end

    # PATCH; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def patch(path, params: {}, headers: {})
      integration_response(@integration_client.patch(path, Cybertrain::Test.flatten_params(params), headers))
    end

    # PUT; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def put(path, params: {}, headers: {})
      integration_response(@integration_client.put(path, Cybertrain::Test.flatten_params(params), headers))
    end

    # DELETE; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def delete(path, params: {}, headers: {})
      integration_response(@integration_client.delete(path, Cybertrain::Test.flatten_params(params), headers))
    end

    # HEAD: the GET route answers and the body is dropped, as the server
    # drops it; `params:` go in the query string.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def head(path, params: {}, headers: {})
      res = @integration_client.request("HEAD", with_query(path, params), "", headers)
      res.body = ""
      integration_response(res)
    end

    # GETs the last response's Location.
    # @return [Cybertrain::Response]
    # @raise [RuntimeError] when the last response was not a redirect
    # @api public
    def follow_redirect!
      integration_response(@integration_client.follow_redirect!)
    end

    # The last response (an empty 200 before the first request).
    # @return [Cybertrain::Response]
    # @api public
    def response
      @integration_client.response
    end

    # This test's cookie jar: name to raw (still percent-encoded) value,
    # from every Set-Cookie so far in this test.
    # @return [Hash{String => String}]
    # @api public
    def cookies
      @integration_client.cookies
    end

    # Passes when the last response's status is `expected`: an Integer, or
    # a Symbol (`:success` 2xx, `:redirect` 3xx, `:not_found`, ...).
    # @param expected [Integer, Symbol]
    # @return [nil]
    # @api public
    def assert_response(expected)
      Cybertrain::Test.check_response(@integration_client.response, expected)
    end

    # Passes when the last response is a 3xx whose Location is exactly `path`.
    # @param path [String]
    # @return [nil]
    # @api public
    def assert_redirected_to(path)
      Cybertrain::Test.check_redirect(@integration_client.response, path)
    end

    private

    # The response, its body kept as Cybertrain::Test.last_html (for
    # assert_select).
    def integration_response(res)
      Cybertrain::Test.last_html = res.body
      res
    end

    def with_query(path, params)
      query = Cybertrain::Test.flatten_params(params)
      return path if query.empty?

      joiner = path.include?("?") ? "&" : "?"
      "#{path}#{joiner}#{Cybertrain::Query.encode(query)}"
    end
  end
end
