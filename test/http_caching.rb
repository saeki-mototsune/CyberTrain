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
router.post("/text", "text_post") { |ctx| PagesController.new(ctx).process(:text) { |c| c.text } }

CLIENT = Cybertrain::Test::Client.new(router)

def tag_of(key)
  "W/\"#{Digest::SHA256.hexdigest(key).byteslice(0, 32)}\""
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
