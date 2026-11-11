require "digest"
require "stringio"
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/router"
require "cybertrain/controller"

# Controller#fresh_when, #stale? and #expires_in, and Request.http_date /
# parse_http_date, through a real controller action, a Router and
# Test::Client. cybertrain/controller pulls in the SQLite FFI bindings, so
# take the snapshot from the compiled binary (script/regen-snapshot), not
# from CRuby (spikes/NOTES.md rule 23).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

STAMP = 1_700_000_000

# A record with no table behind it: the id and updated_at that make its key.
class Post < Cybertrain::Model
  def model_name = "Post"

  def read_attribute(name)
    name == :updated_at ? Time.at(STAMP).utc : nil
  end
end

def sample_post
  post = Post.new
  post.set_id(7)
  post
end

def stamp_date(offset)
  Cybertrain::Request.http_date(Time.at(STAMP + offset).utc)
end

class PagesController < Cybertrain::Controller
  def text
    fresh_when etag: "v1"
    render plain: "body" unless performed?
  end

  def shared
    fresh_when etag: "v1", public: true
    render plain: "body" unless performed?
  end

  def record
    fresh_when etag: sample_post
    render plain: "body" unless performed?
  end

  def dated
    fresh_when last_modified: Time.at(STAMP).utc
    render plain: "body" unless performed?
  end

  def both
    fresh_when etag: "v1", last_modified: Time.at(STAMP).utc
    render plain: "body" unless performed?
  end

  def badetag
    fresh_when etag: 42
  end

  def check
    render plain: "rendered" if stale?(last_modified: Time.at(STAMP).utc)
  end

  def timed
    expires_in 300
    render plain: "body"
  end

  def timed_public
    expires_in 300, public: true
    render plain: "body"
  end

  def timed_then_fresh
    expires_in 300
    fresh_when etag: "v1"
    render plain: "body" unless performed?
  end

  def bodied_304
    render plain: "x", status: :not_modified
  end

  # Validates first, then offers HTML only: a request whose Accept lists
  # JSON before HTML is answered with the page.
  def offered
    fresh_when etag: "v1"
    return if performed?

    respond_to do |format|
      format.html { render plain: "page" }
    end
  end
end

router = Cybertrain::Router.new
router.get("/text", "text") { |ctx| PagesController.new(ctx).process(:text) { |c| c.text } }
router.get("/shared", "shared") { |ctx| PagesController.new(ctx).process(:shared) { |c| c.shared } }
router.get("/record", "record") { |ctx| PagesController.new(ctx).process(:record) { |c| c.record } }
router.get("/dated", "dated") { |ctx| PagesController.new(ctx).process(:dated) { |c| c.dated } }
router.get("/both", "both") { |ctx| PagesController.new(ctx).process(:both) { |c| c.both } }
router.get("/check", "check") { |ctx| PagesController.new(ctx).process(:check) { |c| c.check } }
router.get("/timed", "timed") { |ctx| PagesController.new(ctx).process(:timed) { |c| c.timed } }
router.get("/timed_public", "timed_public") { |ctx| PagesController.new(ctx).process(:timed_public) { |c| c.timed_public } }
router.get("/then", "then") { |ctx| PagesController.new(ctx).process(:timed_then_fresh) { |c| c.timed_then_fresh } }
router.get("/bodied", "bodied") { |ctx| PagesController.new(ctx).process(:bodied_304) { |c| c.bodied_304 } }
router.get("/offered", "offered") { |ctx| PagesController.new(ctx).process(:offered) { |c| c.offered } }
router.post("/text", "text_post") { |ctx| PagesController.new(ctx).process(:text) { |c| c.text } }
router.post("/dated", "dated_post") { |ctx| PagesController.new(ctx).process(:dated) { |c| c.dated } }

CLIENT = Cybertrain::Test::Client.new(router)

# The ETag of `key` for a request of `format`: the key, the format and
# the build digest (Assets.build_digest), "\0"-separated. The format of a
# request that also takes HTML (its Accept lists text/html or */* after
# another type) is "<format>+html".
def tag_of(key, format = "html")
  keyed = "#{key}\0#{format}\0#{Cybertrain::Assets.build_digest}"
  "W/\"#{Digest::SHA256.hexdigest(keyed).byteslice(0, 32)}\""
end

test "fresh_when answers 304 to a matching If-None-Match" do
  res = CLIENT.get("/text")
  want = tag_of("v1")
  puts "etag #{res.header("ETag")}"
  assert_equal want, res.header("ETag")
  assert_equal 200, res.status
  assert_equal "body", res.body

  again = CLIENT.get("/text", { "If-None-Match" => want })
  assert_equal 304, again.status
  assert_equal "", again.body
  assert_equal want, again.header("ETag")

  other = CLIENT.get("/text", { "If-None-Match" => tag_of("v0") })
  assert_equal 200, other.status
end

test "etag: a record is keyed by table, id and updated_at" do
  want = tag_of("posts/7-#{STAMP}")
  res = CLIENT.get("/record")
  assert_equal want, res.header("ETag")
  assert_equal 304, CLIENT.get("/record", { "If-None-Match" => want }).status
end

test "If-None-Match takes a list, a strong form and *" do
  want = tag_of("v1")
  strong = want.byteslice(2, want.bytesize - 2)
  assert_equal 304, CLIENT.get("/text", { "If-None-Match" => "\"x\", #{want}" }).status
  assert_equal 304, CLIENT.get("/text", { "If-None-Match" => "\"x\", W/\"y\", " + strong }).status
  assert_equal 304, CLIENT.get("/text", { "If-None-Match" => strong }).status
  assert_equal 304, CLIENT.get("/text", { "If-None-Match" => "*" }).status
  assert_equal 200, CLIENT.get("/text", { "If-None-Match" => "\"x\", W/\"y\"" }).status
end

test "If-None-Match: * is fresh for a response validated by date only" do
  # RFC 9110 13.1.2: * matches any current representation, whether or not
  # the response carries an ETag.
  res = CLIENT.get("/dated", { "If-None-Match" => "*" })
  assert_equal 304, res.status
  assert_equal "", res.body
  assert_nil res.header("ETag")
  assert_equal stamp_date(0), res.header("Last-Modified")
  assert_equal 304, CLIENT.get("/dated", { "If-None-Match" => "\"x\", *" }).status
  # it decides alone, like any If-None-Match
  assert_equal 304, CLIENT.get("/dated", { "If-None-Match" => "*", "If-Modified-Since" => stamp_date(-60) }).status
  # an ordinary tag has nothing to match on a response without an ETag
  assert_equal 200, CLIENT.get("/dated", { "If-None-Match" => "\"x\"" }).status
  assert_equal 200, CLIENT.get("/dated", { "If-None-Match" => "\"x\"", "If-Modified-Since" => stamp_date(0) }).status
  # and only GET and HEAD are answered 304
  assert_equal 200, CLIENT.post("/dated", {}, { "If-None-Match" => "*" }).status
end

test "only GET and HEAD are answered 304" do
  res = CLIENT.post("/text", {}, { "If-None-Match" => tag_of("v1") })
  assert_equal 200, res.status
  assert_equal 304, CLIENT.request("HEAD", "/text", "", { "If-None-Match" => tag_of("v1") }).status
end

test "If-Modified-Since and stale?" do
  res = CLIENT.get("/dated")
  assert_equal stamp_date(0), res.header("Last-Modified")
  puts "last-modified #{res.header("Last-Modified")}"
  assert_equal 304, CLIENT.get("/dated", { "If-Modified-Since" => stamp_date(0) }).status
  assert_equal 304, CLIENT.get("/dated", { "If-Modified-Since" => stamp_date(60) }).status
  assert_equal 200, CLIENT.get("/dated", { "If-Modified-Since" => stamp_date(-60) }).status
  assert_equal 200, CLIENT.get("/dated", { "If-Modified-Since" => "last tuesday" }).status

  fresh = CLIENT.get("/check", { "If-Modified-Since" => stamp_date(0) })
  assert_equal 304, fresh.status
  assert_equal "", fresh.body
  old = CLIENT.get("/check", { "If-Modified-Since" => stamp_date(-1) })
  assert_equal 200, old.status
  assert_equal "rendered", old.body
  assert_equal 200, CLIENT.get("/check").status
end

test "If-None-Match decides alone when the request sends both validators" do
  assert_equal 304, CLIENT.get("/both", { "If-None-Match" => tag_of("v1"), "If-Modified-Since" => stamp_date(0) }).status
  assert_equal 200, CLIENT.get("/both", { "If-None-Match" => tag_of("v0"), "If-Modified-Since" => stamp_date(0) }).status
  assert_equal 304, CLIENT.get("/both", { "If-None-Match" => tag_of("v1"), "If-Modified-Since" => stamp_date(-5) }).status
  assert_equal 304, CLIENT.get("/both", { "If-Modified-Since" => stamp_date(0) }).status
end

test "a 304 carries no Content-Type and no Content-Length" do
  raw = CLIENT.get("/text", { "If-None-Match" => tag_of("v1") }).to_http
  assert_includes raw, "HTTP/1.1 304 Not Modified\r\n"
  assert_includes raw, "ETag: "
  refute raw.downcase.include?("content-type:")
  refute raw.downcase.include?("content-length:")
  ok = CLIENT.get("/text").to_http
  assert_includes ok.downcase, "content-type:"
  assert_includes ok, "Content-Length: 4\r\n"
end

test "the ETag depends on the request's format: a Turbo or JSON fetch never revalidates the HTML" do
  html = CLIENT.get("/record", { "Accept" => "text/html" }).header("ETag")
  stream = CLIENT.get("/record", { "Accept" => "text/vnd.turbo-stream.html, text/html" }).header("ETag")
  json = CLIENT.get("/record", { "Accept" => "application/json" }).header("ETag")
  assert_equal tag_of("posts/7-#{STAMP}"), html
  assert_equal tag_of("posts/7-#{STAMP}", "turbo_stream+html"), stream
  assert_equal tag_of("posts/7-#{STAMP}", "json"), json
  refute html == stream
  refute html == json
  # the browser revalidating its cached HTML for a stream fetch gets a 200
  res = CLIENT.get("/record", { "Accept" => "text/vnd.turbo-stream.html, text/html", "If-None-Match" => html })
  assert_equal 200, res.status
  assert_equal "Accept", res.header("Vary")
  assert_equal 304, CLIENT.get("/record", { "Accept" => "text/html", "If-None-Match" => html }).status
end

test "a request that falls back to HTML does not share its ETag with one for the format alone" do
  both = { "Accept" => "application/json, text/html" }
  page = CLIENT.get("/offered", both)
  assert_equal 200, page.status
  assert_equal "page", page.body
  tag = page.header("ETag")
  assert_equal tag_of("v1", "json+html"), tag
  refute tag == tag_of("v1", "json")
  refute tag == tag_of("v1")
  # the same request revalidates its page
  assert_equal 304, CLIENT.get("/offered", { "Accept" => "application/json, text/html", "If-None-Match" => tag }).status
  # a JSON-only request holding that ETag reaches respond_to, which has no
  # JSON to offer
  only = CLIENT.get("/offered", { "Accept" => "application/json", "If-None-Match" => tag })
  assert_equal 406, only.status
  assert_equal "Not Acceptable", only.body
  assert_equal tag_of("v1", "json"), only.header("ETag")
  # an extension asks for its format alone, whatever Accept says
  assert_equal tag_of("v1", "json"), CLIENT.get("/offered.json", both).header("ETag")
  # HTML refused with q=0 is no fallback
  assert_equal tag_of("v1", "json"), CLIENT.get("/offered", { "Accept" => "application/json, text/html;q=0" }).header("ETag")
  # */* counts as taking HTML (axios)
  assert_equal tag_of("v1", "json+html"), CLIENT.get("/offered", { "Accept" => "application/json, text/plain, */*" }).header("ETag")
  # HTML first is the html format, as before
  assert_equal tag_of("v1"), CLIENT.get("/offered", { "Accept" => "text/html, application/json" }).header("ETag")
end

test "the ETag changes with the build digest gen installs" do
  before = CLIENT.get("/text").header("ETag")
  Cybertrain::Assets.install(Cybertrain::Assets.empty_resolver, "{\"imports\":{}}", Array.new(0) { "" }, "0123456789abcdef")
  after = CLIENT.get("/text").header("ETag")
  assert_equal tag_of("v1"), after
  Cybertrain::Assets.install(Cybertrain::Assets.empty_resolver, "{\"imports\":{}}", Array.new(0) { "" })
  refute before == after
  assert_equal "", Cybertrain::Assets.build_digest
  assert_equal before, CLIENT.get("/text").header("ETag")
end

test "a 304 the action rendered with a body sends no body" do
  res = CLIENT.get("/bodied")
  assert_equal 304, res.status
  raw = res.to_http
  assert raw.end_with?("\r\n\r\n"), raw
  refute raw.downcase.include?("content-length:")
end

test "an etag that is neither a String nor a record is an ArgumentError" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/badetag", { "host" => "example.test" }, ""))
  msg = assert_raises("ArgumentError") { PagesController.new(ctx).process(:badetag) { |c| c.badetag } }
  assert_includes msg, "etag: must be a String or a record"
end

test "Cache-Control from fresh_when and expires_in" do
  assert_equal "max-age=0, private, must-revalidate", CLIENT.get("/text").header("Cache-Control")
  assert_equal "max-age=0, public, must-revalidate", CLIENT.get("/shared").header("Cache-Control")
  assert_equal "max-age=300, private", CLIENT.get("/timed").header("Cache-Control")
  assert_equal "max-age=300, public", CLIENT.get("/timed_public").header("Cache-Control")
  assert_equal "max-age=300, private", CLIENT.get("/then").header("Cache-Control")
end

test "http_date and parse_http_date" do
  assert_equal "Sun, 06 Nov 1994 08:49:37 GMT", Cybertrain::Request.http_date(Time.at(784_111_777).utc)
  assert_equal 784_111_777, Cybertrain::Request.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
  assert_equal STAMP, Cybertrain::Request.parse_http_date(stamp_date(0))
  assert_equal 0, Cybertrain::Request.parse_http_date("Thu, 01 Jan 1970 00:00:00 GMT")
  assert_equal 1_709_164_800, Cybertrain::Request.parse_http_date("Thu, 29 Feb 2024 00:00:00 GMT")
  assert_equal(-1, Cybertrain::Request.parse_http_date("Sun, 06 Foo 1994 08:49:37 GMT"))
  assert_equal(-1, Cybertrain::Request.parse_http_date("Sun, 06 Nov 1994 0x:49:37 GMT"))
  assert_equal(-1, Cybertrain::Request.parse_http_date("Sun, 06 Nov 1994 25:49:37 GMT"))
  assert_equal(-1, Cybertrain::Request.parse_http_date(""))
  assert_equal(-1, Cybertrain::Request.parse_http_date("yesterday"))
  assert_equal(-1, Cybertrain::Request.parse_http_date("2026-11-10T00:00:00Z"))
  assert_equal(-1, Cybertrain::Request.parse_http_date("Sun, 06 Nov 1994 08:49:37 +0100"))
end

Cybertrain::Test.run!
