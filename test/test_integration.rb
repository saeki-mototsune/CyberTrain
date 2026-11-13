# ActionDispatch::IntegrationTest (spec section 5.1, plan decision 6):
# get, post, patch, put, delete and head with nested params:, the cookie
# jar per test, follow_redirect!, the instance assert_response /
# assert_redirected_to beside the top-level forms (one shared check each,
# pre-flight R17), *_url targets on the test host reduced to their
# path (another host refused), Rails' header names and status Symbols,
# Cybertrain::Test.flatten_params, with_forgery_protection (put back when
# an assertion in it fails), and the bundle's boot silencing the request
# log. A small application (articles kept in memory, routes in
# the shape gen/routes.rb emits for `resources :articles` plus
# `get "/remember"`) booted the way gen/tests.rb boots one. Application#boot
# links SQLite through FFI, so this runs compiled only (NOTES rule 23).
require "cybertrain"
require "cybertrain/test_help"
require "cybertrain/test/bundle"

# The articles' titles and bodies; an article's id is its index + 1.
TITLES = Array.new(0) { "" }
BODIES = Array.new(0) { "" }
TAGS = Array.new(0) { "" }

class ArticlesController < Cybertrain::Controller
  def index
    render plain: TITLES.join(",")
  end

  def show
    id = params[:id].to_i
    return head(:not_found) if id < 1 || id > TITLES.length

    render plain: "#{TITLES[id - 1]}: #{BODIES[id - 1]}"
  end

  def create
    article = params.require(:article)
    TITLES << article[:title].to_s
    BODIES << article[:body].to_s
    TAGS << article.nested(:tags)[:a].to_s
    redirect_to "/articles/#{TITLES.length}", status: :see_other
  end

  def update
    id = params[:id].to_i
    TITLES[id - 1] = params.require(:article)[:title].to_s
    render plain: "updated #{id} #{request.method}"
  end

  def destroy
    render plain: "destroyed #{params[:id]}"
  end

  def remember
    cookies[:n] = params[:n].to_s
    render plain: "remembered #{params[:n]}"
  end

  # An absolute redirect on the test host, and one to another host.
  def go_here
    redirect_to "http://www.example.com/articles"
  end

  def go_away
    redirect_to "https://elsewhere.example/x"
  end

  def accept
    render plain: "#{request.header("Accept")} #{request.header("X-Token")}"
  end

  # Each typed param read back through the casts a model's writers use
  # (models_emitter's cast_for): what create and update would store.
  def casts
    v = params.require(:value)
    on = Cybertrain::Cast.date_or_nil(v[:on].to_s)
    at = Cybertrain::Cast.time_or_nil(v[:at].to_s)
    parts = Array.new(0) { "" }
    parts << request.method
    parts << on.to_s
    parts << (at.nil? ? "nil" : Cybertrain::Cast.sql_datetime(at))
    parts << Cybertrain::Cast.float(v[:f].to_s).to_s
    parts << Cybertrain::Cast.int(v[:n].to_s).to_s
    parts << Cybertrain::Cast.bool(v[:yes].to_s).to_s
    parts << Cybertrain::Cast.bool(v[:no].to_s).to_s
    parts << v[:none].to_s.empty?.to_s
    render plain: parts.join("|")
  end

  # A multipart form: the text field, then the file's name, declared type
  # and size (and the bytes' checksum), as the action sees them.
  def upload
    doc = params.nested(:doc)
    file = doc.upload(:file)
    if file.nil?
      render plain: "#{request.method} #{doc[:title]} no file"
    else
      render plain: "#{request.method} #{doc[:title]} #{file.original_filename} #{file.declared_content_type} #{file.byte_size} #{file.sha256_hex[0, 8]}"
    end
  end
end

def build_router
  router = Cybertrain::Router.new
  router.add("GET", "/articles", "articles") { |ctx| ArticlesController.new(ctx).process(:index) { |c| c.index } }
  router.add("POST", "/articles", "articles") { |ctx| ArticlesController.new(ctx).process(:create) { |c| c.create } }
  router.add("GET", "/articles/:id", "article") { |ctx| ArticlesController.new(ctx).process(:show) { |c| c.show } }
  router.add("PATCH", "/articles/:id", "article") { |ctx| ArticlesController.new(ctx).process(:update) { |c| c.update } }
  router.add("PUT", "/articles/:id", "article") { |ctx| ArticlesController.new(ctx).process(:update) { |c| c.update } }
  router.add("DELETE", "/articles/:id", "article") { |ctx| ArticlesController.new(ctx).process(:destroy) { |c| c.destroy } }
  router.add("GET", "/remember", "remember") { |ctx| ArticlesController.new(ctx).process(:remember) { |c| c.remember } }
  router.add("GET", "/go_here", "go_here") { |ctx| ArticlesController.new(ctx).process(:go_here) { |c| c.go_here } }
  router.add("GET", "/go_away", "go_away") { |ctx| ArticlesController.new(ctx).process(:go_away) { |c| c.go_away } }
  router.add("GET", "/accept", "accept") { |ctx| ArticlesController.new(ctx).process(:accept) { |c| c.accept } }
  router.add("POST", "/casts", "casts") { |ctx| ArticlesController.new(ctx).process(:casts) { |c| c.casts } }
  router.add("PATCH", "/casts/:id", "cast") { |ctx| ArticlesController.new(ctx).process(:casts) { |c| c.casts } }
  router.add("POST", "/uploads", "uploads") { |ctx| ArticlesController.new(ctx).process(:upload) { |c| c.upload } }
  router.add("PATCH", "/uploads/:id", "upload") { |ctx| ArticlesController.new(ctx).process(:upload) { |c| c.upload } }
  router.add("PUT", "/uploads/:id", "upload") { |ctx| ArticlesController.new(ctx).process(:upload) { |c| c.upload } }
  router
end

def resolver
  ->(name, args, options) { "/" }
end

# gen/routes.rb's helper module, and gen/tests.rb's reopening of the class.
module Gen
  module UrlHelpers
    def article_path(id, options = {})
      "/articles/#{id}"
    end

    def article_url(id, options = {})
      Cybertrain.url_root + article_path(id, options)
    end

    def articles_url(options = {})
      "#{Cybertrain.url_root}/articles"
    end
  end
end

class ActionDispatch::IntegrationTest
  include ::Gen::UrlHelpers
end

# Class-form tests as gen's rewrite writes them (each method ends in nil).
class ArticlesTest < ActionDispatch::IntegrationTest
  def test_requests
    begin
      assert_difference(-> { TITLES.length }, 1) do
        post "/articles", params: { article: { title: "New", body: "A body long enough", tags: { a: "1" } } }
      end
      assert_equal "1", TAGS[0]
      assert_response :redirect
      assert_response :see_other
      assert_redirected_to "/articles/1"
      assert_redirected_to article_path(1)
      follow_redirect!
      assert_response :success
      assert_equal "New: A body long enough", response.body
      assert_equal "New: A body long enough", Cybertrain::Test.last_html
      res = get "/articles"
      assert_equal "New", res.body
      assert_equal res, response
      assert_equal "updated 1 PATCH", patch(article_path(1), params: { article: { title: "Newer" } }).body
      assert_equal "updated 1 PUT", put("/articles/1", params: { article: { title: "Newest" } }).body
      assert_equal "destroyed 1", delete("/articles/1").body
      res = head "/articles"
      assert_equal 200, res.status
      assert_equal "", res.body
      assert_equal "", Cybertrain::Test.last_html
    end
    nil
  end

  def test_query_params
    begin
      get "/remember", params: { n: "7" }
      assert_equal "remembered 7", response.body
      get "/remember?x=1", params: { n: 8 }
      assert_equal "remembered 8", response.body
    end
    nil
  end

  def test_remember
    begin
      assert cookies.empty?
      get "/remember?n=1"
      assert_equal "1", cookies["n"]
      get "/articles"
      assert_equal "1", cookies["n"]
    end
    nil
  end

  def test_statuses
    begin
      get "/articles/99"
      assert_response :not_found
      assert_response 404
      message = assert_raises("AssertionFailed") { assert_response :success }
      assert_equal "expected response :success, got 404", message
      message = assert_raises("AssertionFailed") { assert_response 200 }
      assert_equal "expected response 200, got 404", message
      message = assert_raises("AssertionFailed") { assert_redirected_to "/articles" }
      assert_equal "expected a redirect to \"/articles\", got 404", message
      message = assert_raises(RuntimeError) { follow_redirect! }
      assert_equal "not a redirect: last response was 404", message
    end
    nil
  end
end

class UrlTest < ActionDispatch::IntegrationTest
  def test_urls
    begin
      post "/articles", params: { article: { title: "New" } }
      # redirect_to a path, asserted with the *_url helper, and the other way round.
      assert_redirected_to article_url(1)
      assert_redirected_to "http://www.example.com/articles/1"
      get articles_url
      assert_response :success
      assert_equal "New", response.body
      get "http://www.example.com/articles/1"
      assert_equal "New: ", response.body
      get "/go_here"
      assert_redirected_to "/articles"
      assert_redirected_to articles_url
      follow_redirect!
      assert_equal "New", response.body
      get "/go_away"
      assert_redirected_to "https://elsewhere.example/x"
      message = assert_raises("AssertionFailed") { assert_redirected_to "/x" }
      assert_equal "expected a redirect to \"/x\", got \"https://elsewhere.example/x\"", message
      message = assert_raises(ArgumentError) { follow_redirect! }
      assert_equal "https://elsewhere.example/x is on another host: an integration test requests the booted application " \
                   "(www.example.com, or the host of Cybertrain.url_root)", message
      message = assert_raises(ArgumentError) { get "https://elsewhere.example/articles" }
      assert_includes message, "https://elsewhere.example/articles is on another host"
      get "/remember#top", params: { n: 3 }
      assert_equal "remembered 3", response.body
      get "/accept", headers: { "HTTP_ACCEPT" => "application/json", "HTTP_X_TOKEN" => "t" }
      assert_equal "application/json t", response.body
    end
    nil
  end

  def test_failing_inside_forgery_protection
    begin
      with_forgery_protection do
        post "/articles", params: { article: { title: "Refused" } }
        assert_response :success
      end
    end
    nil
  end

  def test_forgery_protection
    begin
      with_forgery_protection do
        post "/articles", params: { article: { title: "Refused" } }
        assert_response :forbidden
        get "/articles"
        assert_response :success
      end
      assert_equal 0, TITLES.length
      post "/articles", params: { article: { title: "Kept" } }
      assert_response :see_other
      assert_equal ["Kept"], TITLES
    end
    nil
  end
end

# A record's readers answer Dates, Times, Floats, Integers, booleans and nil;
# a scaffold's test sends them as they are (params: { event: { on: @event.on } }),
# and what the model casts them back to is what was sent.
class TypedParamsTest < ActionDispatch::IntegrationTest
  def test_typed_params
    begin
      on = Date.new(2028, 2, 29)
      at = Time.utc(2026, 11, 11, 12, 0, 0, 123456)
      post "/casts", params: { value: { on: on, at: at, f: 1.5, n: 42, yes: true, no: false, none: nil } }
      assert_equal "POST|2028-02-29|2026-11-11 12:00:00.123456|1.5|42|true|false|true", response.body
      patch "/casts/1", params: { value: { on: on, at: at, f: 0.1, n: -7, yes: true, no: false, none: nil } }
      assert_equal "PATCH|2028-02-29|2026-11-11 12:00:00.123456|0.1|-7|true|false|true", response.body
      flat = Cybertrain::Test.flatten_params({ value: { on: on, at: at, f: 1.5 } })
      assert_equal "2028-02-29", flat["value[on]"]
      assert_equal "2026-11-11 12:00:00.123456", flat["value[at]"]
      assert_equal "1.5", flat["value[f]"]
      assert_equal at, Cybertrain::Cast.time_or_nil(flat["value[at]"])
      assert_equal on, Cybertrain::Cast.date_or_nil(flat["value[on]"])
    end
    nil
  end
end

# fixture_file_upload in params: (Rails' shape): a File value in a nested
# Hash beside Strings makes post / patch / put send multipart/form-data.
class UploadTest < ActionDispatch::IntegrationTest
  def test_uploads
    begin
      png = File.binread("tmp/test_integration/files/pixel.png")
      sum = Cybertrain::UploadedFile.new("x", "", png).sha256_hex[0, 8]
      file = fixture_file_upload("pixel.png", "image/png")
      assert_equal "pixel.png", file.filename
      assert_equal "image/png", file.content_type
      assert_equal png, file.data
      post "/uploads", params: { doc: { title: "Hi", file: file } }
      assert_response :success
      assert_equal "POST Hi pixel.png image/png #{png.bytesize} #{sum}", response.body
      patch "/uploads/1", params: { doc: { title: "Again", file: fixture_file_upload("pixel.png") } }
      assert_equal "PATCH Again pixel.png image/png #{png.bytesize} #{sum}", response.body
      put "/uploads/1", params: { doc: { title: "Put", file: fixture_file_upload("tmp/test_integration/files/notes.txt") } }
      assert_equal "PUT Put notes.txt text/plain 3 #{Cybertrain::UploadedFile.new("x", "", "abc").sha256_hex[0, 8]}", response.body
      # Without a file the same params go as a form.
      post "/uploads", params: { doc: { title: "Plain" } }
      assert_equal "POST Plain no file", response.body
      message = assert_raises(ArgumentError) { fixture_file_upload("missing.png") }
      assert_equal "fixture_file_upload: no file test/fixtures/files/missing.png (nor missing.png)", message
      message = assert_raises(ArgumentError) { get "/uploads", params: { doc: { file: file } } }
      assert_equal "params: a file (fixture_file_upload) is sent by post, patch or put as a form, not in a query string (at doc[file])", message
    end
    nil
  end
end

# ---- the boot, as gen/tests.rb does it ----

def make_dir(dir)
  Dir.mkdir(dir) unless File.directory?(dir)
  nil
end

DATABASE = "tmp/test_integration/test.sqlite3"
make_dir("tmp")
make_dir("tmp/test_integration")
# fixture_file_upload reads test/fixtures/files/ (relative to the current
# directory, the app's root in the bundle; this program runs from the
# repository root, whose test/fixtures/files/pixel.png is committed), and a
# path that is not there as given.
make_dir("tmp/test_integration/files")
File.binwrite("tmp/test_integration/files/pixel.png", Cybertrain::Test.binary([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF]))
File.write("tmp/test_integration/files/notes.txt", "abc")
ENV["CYBERTRAIN_TEST_DATABASE"] = DATABASE

def integration_config
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = DATABASE
  c.secret_key_base = "test-integration-secret"
  c.views_root = "tmp/test_integration/views"
  c.public_root = "tmp/test_integration/public"
  Cybertrain.config = c
  c
end

def no_app_message
  ArticlesTest.new
  ""
rescue RuntimeError => e
  e.message
end

CONFIG = integration_config
NO_APP_BEFORE_BOOT = Cybertrain::Test.app.nil?
NO_APP_MESSAGE = no_app_message
APP = Cybertrain::Test::Bundle.boot(build_router, resolver)
at_exit do
  [DATABASE, "#{DATABASE}-wal", "#{DATABASE}-shm"].each { |f| File.delete(f) if File.exist?(f) }
end

setup do
  TITLES.clear
  BODIES.clear
  TAGS.clear
end

test "without a booted application an integration test says where it runs" do
  assert NO_APP_BEFORE_BOOT
  assert_equal "no application booted: IntegrationTest runs in the bundle (cybertrain test)", NO_APP_MESSAGE
end

test "get, post with nested params, patch, put, delete, head answer the response" do
  ArticlesTest.new.test_requests
end

test "get puts params: in the query string, after any already there" do
  ArticlesTest.new.test_query_params
end

test "cookies persist across requests in one test and not into the next" do
  ArticlesTest.new.test_remember
  assert ArticlesTest.new.cookies.empty?
end

test "assert_response with a symbol, an Integer and the wrong status" do
  ArticlesTest.new.test_statuses
end

test "the top-level forms share the instance forms' checks" do
  t = ArticlesTest.new
  res = t.get("/articles/99")
  assert_response res, :not_found
  message = assert_raises("AssertionFailed") { assert_response res, :success }
  assert_equal "expected response :success, got 404", message
  message = assert_raises("AssertionFailed") { assert_redirected_to res, "/articles" }
  assert_equal "expected a redirect to \"/articles\", got 404", message
  message = assert_raises("AssertionFailed") { assert_response res, :teapot }
  assert_equal "unknown status symbol :teapot", message
end

test "flatten_params encodes brackets and refuses arrays" do
  flat = Cybertrain::Test.flatten_params({ article: { title: "x", tags: { a: "1" } } })
  assert_equal({ "article[title]" => "x", "article[tags][a]" => "1" }, flat)
  assert_equal({ "n" => "1", "s" => "sym", "f" => "1.5", "t" => "true", "no" => "false" },
               Cybertrain::Test.flatten_params({ n: 1, s: :sym, f: 1.5, t: true, no: false }))
  # The narrower form: keys already written with brackets are kept.
  assert_equal({ "article[title]" => "x" }, Cybertrain::Test.flatten_params({ "article[title]" => "x" }))
  assert Cybertrain::Test.flatten_params({}).empty?
  assert_equal({ "q" => "" }, Cybertrain::Test.flatten_params({ q: nil }))
  message = assert_raises(ArgumentError) { Cybertrain::Test.flatten_params({ article: { ids: [1, 2] } }) }
  assert_equal "params: values must be Strings or Hashes (got Array at article[ids])", message
end

test "the bundle's boot silences the request log and turns forgery protection off unless config gives them" do
  assert_equal :none, CONFIG.log_level
  refute CONFIG.log_level_given?
  refute CONFIG.csrf
  c = Cybertrain::Config.new
  c.log_level = :debug
  c.log_level_unless_given(:none)
  assert_equal :debug, c.log_level
  assert c.log_level_given?
  d = Cybertrain::Config.new
  d.log_level_unless_given(:none)
  assert_equal :none, d.log_level
  refute d.log_level_given?
end

test "with_forgery_protection turns it on for its block only" do
  UrlTest.new.test_forgery_protection
  assert_equal APP, Cybertrain::Test.app
  refute CONFIG.csrf
  refute CONFIG.csrf_given?
end

test "an assertion failing inside with_forgery_protection puts everything back" do
  message = assert_raises("AssertionFailed") { UrlTest.new.test_failing_inside_forgery_protection }
  assert_equal "expected response :success, got 403", message
  assert_equal APP, Cybertrain::Test.app
  refute CONFIG.csrf
end

test "and the next test's post is accepted" do
  t = ArticlesTest.new
  t.post("/articles", params: { article: { title: "After" } })
  t.assert_response :see_other
  assert_equal ["After"], TITLES
end

test "the backstop after the test restores the application and csrf" do
  strict = Cybertrain::Application.new(router: build_router, url_resolver: resolver).boot
  Cybertrain::Test.app = strict
  CONFIG.csrf = true
  Cybertrain::Test.forgery_restore(APP, false, false).call
  assert_equal APP, Cybertrain::Test.app
  refute CONFIG.csrf
  refute CONFIG.csrf_given?
end

test "*_url helpers are requested and asserted by their path; another host is refused" do
  UrlTest.new.test_urls
end

test "the top-level assert_redirected_to reduces a URL on the test host too" do
  t = ArticlesTest.new
  res = t.get("/go_here")
  assert_redirected_to res, "/articles"
  assert_redirected_to res, "http://localhost:3000/articles"
  res = t.get("/go_away")
  message = assert_raises("AssertionFailed") { assert_redirected_to res, "/x" }
  assert_equal "expected a redirect to \"/x\", got \"https://elsewhere.example/x\"", message
  assert_equal "/a?b", Cybertrain::Test::Client.local_target("http://WWW.example.com/a?b")
  assert_equal "http://www.example.com.evil/a", Cybertrain::Test::Client.local_target("http://www.example.com.evil/a")
  assert_equal "/", Cybertrain::Test::Client.local_target("http://localhost:3000")
end

test "every status Symbol the controller knows, and Rails' :missing" do
  # The two lists are kept by hand (the test layer loads without the
  # Controller): this is where a drift shows.
  Cybertrain::Controller::STATUS_SYMBOLS.each do |sym, code|
    assert_equal [code, code], Cybertrain::Test::Client.status_range(sym)
  end
  assert_equal 66, Cybertrain::Controller::STATUS_SYMBOLS.size
  assert_equal [404, 404], Cybertrain::Test::Client.status_range(:missing)
  t = ArticlesTest.new
  t.get("/articles/99")
  t.assert_response :missing
end

test "Rails' CGI-style header names" do
  assert_equal "accept", Cybertrain::Test.request_header_name("HTTP_ACCEPT")
  assert_equal "x-token", Cybertrain::Test.request_header_name("HTTP_X_TOKEN")
  assert_equal "content-type", Cybertrain::Test.request_header_name("CONTENT_TYPE")
  assert_equal "content-length", Cybertrain::Test.request_header_name("CONTENT_LENGTH")
  assert_equal "X-Token", Cybertrain::Test.request_header_name("X-Token")
end

test "Date, Time, Float, Integer, booleans and nil in params: are sent as the casts read them back" do
  TypedParamsTest.new.test_typed_params
end

test "fixture_file_upload in params: sends post, patch and put as multipart/form-data" do
  UploadTest.new.test_uploads
end

Cybertrain::Test.run!
