# ActionDispatch::IntegrationTest: requests against the application
# `cybertrain test` booted, from a class-form test (spec section 5.1, plan
# decision 6). Each test is a new instance with its own
# Cybertrain::Test::Client, so cookies (the session among them) persist
# from one request to the next within a test and start empty in the next.
# The bundle (gen/tests.rb) includes the application's Gen::UrlHelpers, so
# `article_path(article)` works in a test as in a controller.
require "date"
require "cybertrain/cast"
require "cybertrain/zoned_time"
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
    # number, true / false, nil (sent empty, as Rails sends it) or a nested
    # Hash. A key already written with brackets (`"article[title]" => "x"`)
    # is kept as it is. Each value is written as the text the model's cast
    # reads back to the same value (what a record's readers answer can be
    # sent as it is, as Rails' scaffold tests send them): a Date as
    # `YYYY-MM-DD`, a Time (or ZonedTime) in the storage format, UTC with
    # microseconds (`2026-11-11 12:00:00.000000`, {Cast.sql_datetime}),
    # true / false as `"true"` / `"false"`, a Float by its shortest text.
    # @example
    #   Cybertrain::Test.flatten_params({ article: { title: "New" } })   # => { "article[title]" => "New" }
    # @param params [Hash]
    # @return [Hash{String => String}]
    # @raise [ArgumentError] for any other value (an Array, a model), and for
    #   a file ({ActionDispatch::IntegrationTest#fixture_file_upload}), which only a form
    #   body carries (post, patch, put)
    # @api public
    def self.flatten_params(params)
      uploads = no_uploads
      out = flatten_form(params, uploads)
      unless uploads.empty?
        message = "params: a file (fixture_file_upload) is sent by post, patch or put as a form, not in a query string (at #{uploads[0].field})"
        raise ArgumentError, message
      end
      out
    end

    # Like {flatten_params} for a form body: each file value
    # ({ActionDispatch::IntegrationTest#fixture_file_upload}) is appended to `uploads` as an
    # Upload named by its bracketed key (`"article[cover]"`), and left out
    # of the text fields answered.
    # @param params [Hash]
    # @param uploads [Array<Upload>] appended to
    # @return [Hash{String => String}]
    # @api private
    def self.flatten_form(params, uploads)
      out = { "" => "" }
      out.delete("")
      flatten_into(out, uploads, "", params)
      out
    end

    # An empty, typed list of uploads (rule 9).
    # @return [Array<Upload>]
    # @api private
    def self.no_uploads
      Array.new(0) { Upload.new("", "", "", "") }
    end

    # Writes params' pairs into out (files into uploads) under prefix
    # (`""` at the top).
    # @return [nil]
    # @api private
    def self.flatten_into(out, uploads, prefix, params)
      params.each do |k, v|
        key = prefix.empty? ? k.to_s : "#{prefix}[#{k}]"
        case v
        when Hash
          flatten_into(out, uploads, key, v)
        when String, Symbol, Integer, Float, TrueClass, FalseClass
          out[key] = v.to_s
        when nil
          out[key] = ""
        when Time
          out[key] = Cybertrain::Cast.sql_datetime(v)
        when Cybertrain::ZonedTime
          out[key] = Cybertrain::Cast.sql_datetime(v.to_time)
        when Date
          out[key] = v.to_s
        when Upload
          uploads << Upload.new(key, v.filename, v.content_type, v.data)
        else
          message = "params: values must be Strings or Hashes (got #{v.class.name} at #{key})"
          raise ArgumentError, message
        end
      end
      nil
    end

    # Where {ActionDispatch::IntegrationTest#fixture_file_upload} reads files (Rails'
    # file_fixture_path).
    FIXTURE_FILES = "test/fixtures/files".freeze

    # The file part {ActionDispatch::IntegrationTest#fixture_file_upload} answers: the bytes
    # of test/fixtures/files/<path> (or of path itself), its last component
    # as the filename, `mime_type` or the type of its extension. The field
    # is named when the params are flattened.
    # @param path [String]
    # @param mime_type [String] "" to guess from the extension
    # @return [Upload]
    # @raise [ArgumentError] when no such file exists
    # @api private
    def self.fixture_upload(path, mime_type)
      full = "#{FIXTURE_FILES}/#{path}"
      full = path unless File.file?(full)
      unless File.file?(full)
        message = "fixture_file_upload: no file #{FIXTURE_FILES}/#{path} (nor #{path})"
        raise ArgumentError, message
      end
      type = mime_type.to_s.empty? ? extension_type(full) : mime_type.to_s
      Upload.new("", File.basename(full), type, File.binread(full))
    end

    # The content type of a file name's extension, application/octet-stream
    # when it is not one of the common ones.
    # @param name [String]
    # @return [String]
    # @api private
    def self.extension_type(name)
      base = File.basename(name)
      dot = base.rindex(".")
      extension = dot.nil? ? "" : base[dot, base.size - dot].to_s.downcase
      case extension
      when ".png" then "image/png"
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".gif" then "image/gif"
      when ".webp" then "image/webp"
      when ".svg" then "image/svg+xml"
      when ".txt" then "text/plain"
      when ".html" then "text/html"
      when ".pdf" then "application/pdf"
      when ".json" then "application/json"
      when ".csv" then "text/csv"
      else "application/octet-stream"
      end
    end

    # A `headers:` name as a request carries it: Rails' CGI-style names
    # (`"HTTP_ACCEPT"`, `"HTTP_X_TOKEN"`, `"CONTENT_TYPE"`,
    # `"CONTENT_LENGTH"`) become `accept`, `x-token`, `content-type` and
    # `content-length`; any other name is kept (the Client lowercases it).
    # @param name [String]
    # @return [String]
    # @api private
    def self.request_header_name(name)
      return "content-type" if name == "CONTENT_TYPE"
      return "content-length" if name == "CONTENT_LENGTH"
      return name unless name.start_with?("HTTP_")

      name[5, name.length - 5].to_s.downcase.tr("_", "-")
    end

    # Runs the block with forgery protection on: `config.csrf` true and a
    # second Application booted on Test.app's router (its middleware is
    # chosen at boot) made Test.app and the client's application; both,
    # and `config.csrf`, are put back in `ensure` when the block ends,
    # also when it raises, and once more after the test as a backstop
    # (Test.after_this_case). Rule 103's save-yield-ensure shape. What
    # IntegrationTest#with_forgery_protection calls.
    # @param client [Client] the test's client
    # @yield the requests that must carry the token
    # @return [nil]
    # @api private
    def self.forgery_protection_during(client)
      saved_app = app
      c = Cybertrain.config
      saved_csrf = c.csrf
      saved_given = c.csrf_given?
      after_this_case(forgery_restore(saved_app, saved_csrf, saved_given)) if in_case?
      c.csrf = true
      strict = Cybertrain::Application.new(router: saved_app.router, url_resolver: saved_app.url_resolver)
      strict.boot
      self.app = strict
      client.client_app = strict
      _value = yield
      nil
    ensure
      self.app = saved_app
      client.client_app = saved_app
      c.restore_csrf(saved_csrf, saved_given)
    end

    # The backstop {forgery_protection_during} registers: a lambda made in
    # a method (rule 82).
    def self.forgery_restore(saved_app, saved_csrf, saved_given)
      -> {
        Cybertrain::Test.app = saved_app
        Cybertrain.config.restore_csrf(saved_csrf, saved_given)
        nil
      }
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
  # status) and becomes {#response}. A path or a URL on the application's
  # host (what the `*_url` helpers write) is requested; a URL on another
  # host is refused. Forgery protection is off in `cybertrain test` unless
  # config/app.rb sets `csrf` (as in Rails' test environment); a test turns
  # it on for some requests with {#with_forgery_protection}.
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
      integration_response(@integration_client.get(with_query(integration_target(path), params), header_names(headers)))
    end

    # POST; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def post(path, params: {}, headers: {})
      integration_response(form_request("POST", integration_target(path), params, header_names(headers)))
    end

    # PATCH; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def patch(path, params: {}, headers: {})
      integration_response(form_request("PATCH", integration_target(path), params, header_names(headers)))
    end

    # PUT; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def put(path, params: {}, headers: {})
      integration_response(form_request("PUT", integration_target(path), params, header_names(headers)))
    end

    # DELETE; `params:` go in the body as a form.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def delete(path, params: {}, headers: {})
      integration_response(@integration_client.delete(integration_target(path), Cybertrain::Test.flatten_params(params), header_names(headers)))
    end

    # HEAD: the GET route answers and the body is dropped, as the server
    # drops it; `params:` go in the query string.
    # @param path [String]
    # @param params [Hash]
    # @param headers [Hash{String => String}]
    # @return [Cybertrain::Response]
    # @api public
    def head(path, params: {}, headers: {})
      res = @integration_client.request("HEAD", with_query(integration_target(path), params), "", header_names(headers))
      res.body = ""
      integration_response(res)
    end

    # GETs the last response's Location (a URL on the application's host
    # by its path).
    # @return [Cybertrain::Response]
    # @raise [RuntimeError] when the last response was not a redirect
    # @raise [ArgumentError] when the Location is on another host
    # @api public
    def follow_redirect!
      location = @integration_client.response.header("Location")
      integration_target(location) unless location.nil?
      integration_response(@integration_client.follow_redirect!)
    end

    # Runs the block with forgery protection on, as Rails'
    # `ActionController::Base.allow_forgery_protection = true` does: its
    # non-GET requests must carry the token from a page the test rendered
    # (else 403). Everything is put back when the block ends, also when an
    # assertion in it fails.
    # @example
    #   with_forgery_protection do
    #     post articles_path, params: { article: { title: "x" } }
    #     assert_response :forbidden
    #   end
    # @yield the requests to check
    # @return [nil]
    # @api public
    def with_forgery_protection
      Cybertrain::Test.forgery_protection_during(@integration_client) { yield }
      nil
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

    # A file to send in `params:` of post, patch or put, as Rails'
    # `fixture_file_upload` gives one: the request then goes as
    # multipart/form-data, the file under its bracketed key
    # (`params: { post: { cover: fixture_file_upload("cover.png", "image/png") } }`
    # is the part `post[cover]`) and the other params as text parts.
    # `path` is read from test/fixtures/files/ (Rails' file_fixture_path),
    # or as given when it exists there; the filename sent is its last
    # component. Without `mime_type` the type is guessed from the
    # extension (png, jpg/jpeg, gif, webp, svg, txt, html, pdf, json, csv),
    # else application/octet-stream.
    # @example
    #   post posts_url, params: { post: { title: "Hi", cover: fixture_file_upload("cover.png", "image/png") } }
    # @param path [String]
    # @param mime_type [String]
    # @return [Cybertrain::Test::Upload]
    # @raise [ArgumentError] when neither test/fixtures/files/<path> nor path is a file
    # @api public
    def fixture_file_upload(path, mime_type = "")
      Cybertrain::Test.fixture_upload(path, mime_type)
    end

    private

    # The request of post, patch and put: a form, or multipart/form-data
    # when a params value is a file (the Client's encoder; a PUT goes as a
    # POST carrying `_method=put`, as a browser's form does).
    def form_request(method, target, params, headers)
      uploads = Cybertrain::Test.no_uploads
      fields = Cybertrain::Test.flatten_form(params, uploads)
      if uploads.empty?
        return @integration_client.patch(target, fields, headers) if method == "PATCH"
        return @integration_client.put(target, fields, headers) if method == "PUT"

        return @integration_client.post(target, fields, headers)
      end
      return @integration_client.patch_multipart(target, fields, uploads, headers) if method == "PATCH"

      fields["_method"] = "put" if method == "PUT"
      @integration_client.post_multipart(target, fields, uploads, headers)
    end

    # The response, its body kept as Cybertrain::Test.last_html (for
    # assert_select) with its Content-Type (for assert_turbo_stream).
    def integration_response(res)
      Cybertrain::Test.record_last_response(res.body, res.header("Content-Type").to_s)
      res
    end

    def with_query(path, params)
      query = Cybertrain::Test.flatten_params(params)
      return path if query.empty?

      joiner = path.include?("?") ? "&" : "?"
      "#{path}#{joiner}#{Cybertrain::Query.encode(query)}"
    end

    # The path to request: a URL on this application's host by its path
    # (Client.local_target), without a fragment (a browser never sends
    # one); a URL on another host is refused.
    def integration_target(target)
      local = Cybertrain::Test::Client.local_target(target)
      unless local.index("://").nil?
        message = "#{target} is on another host: an integration test requests the booted application " \
                  "(#{Cybertrain::Test::Client::TEST_HOST}, or the host of Cybertrain.url_root)"
        raise ArgumentError, message
      end
      fragment = local.index("#")
      fragment.nil? ? local : local[0, fragment].to_s
    end

    def header_names(headers)
      out = { "" => "" }
      out.delete("")
      headers.each { |k, v| out[Cybertrain::Test.request_header_name(k.to_s)] = v }
      out
    end
  end
end
