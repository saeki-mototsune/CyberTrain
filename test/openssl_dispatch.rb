# The framework in a program that also requires Spinel's openssl package
# (spikes/NOTES.md rule 62). That package defines OpenSSL::Buffering#getbyte
# (and puts, read, gets, close, write, <<), so once it is in the program
# every `getbyte` on a boxed receiver dispatches over the user classes that
# define the name, with NoMethodError as the default: String#getbyte is no
# longer reached. Each case below goes through a framework method whose
# String parameter is boxed in some program (an unseeded Hash's key, a
# value read out of JSON or out of a Hash, the String Cast.str hands back)
# and that reads it byte by byte; before those methods narrowed their
# parameters with `to_s`, every one of them raised "undefined method
# 'getbyte'" here. The program requires single files, not the whole
# framework, and builds no SafeString itself: that is the shape in which
# SafeString#to_s was untyped (and every `v.to_s` with it) until html.rb
# built SafeString::EMPTY. The gzip inflater is FFI and openssl needs
# libssl, so this program cannot run under CRuby: its snapshot comes from the
# compiled binary (NOTES rule 23).
require "openssl"
require "json"
require "zlib"
require "cybertrain/html"
require "cybertrain/cast"
require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/http/query"
require "cybertrain/http/gzip_ffi"
require "cybertrain/http/client_error"
require "cybertrain/test"

Cybertrain::GzipFFI.install!

test "the program has the openssl package in it" do
  assert_equal 64, OpenSSL::HMAC.hexdigest("SHA256", "key", "data").size
end

test "a response with headers serializes" do
  res = Cybertrain::Response.new
  res.set_header("X-Request-Id", "abc")
  res.set_header("Cache-Control", "no-store")
  res.set_header("cache-control", "no-cache")
  res.body = "hello"
  http = res.to_http
  assert_includes http, "HTTP/1.1 200 OK\r\n"
  assert_includes http, "X-Request-Id: abc\r\n"
  assert_includes http, "cache-control: no-cache\r\n"
  assert_includes http, "Content-Length: 5\r\n"
  assert_equal "abc", res.header("x-request-id")
  res.drop_header("X-REQUEST-ID")
  assert_nil res.header("x-request-id")
end

test "header names compare case-insensitively" do
  assert Cybertrain::HeaderName.same?("Content-Type", "content-type")
  assert !Cybertrain::HeaderName.same?("Content-Type", "content-length")
  assert Cybertrain::HeaderName.same?("X-Café", "x-café")
  assert Cybertrain::HeaderName.ascii?("Accept")
  assert !Cybertrain::HeaderName.ascii?("café")
  assert_equal "accept", Cybertrain::HeaderName.lower("Accept")
end

test "a UTF-8 query string and form body parse" do
  req = Cybertrain::Request.new("POST", "/search?q=caf%C3%A9&lang=\u65e5\u672c", { "content-type" => "application/x-www-form-urlencoded" }, "name=%E6%97%A5&note=caf\u00e9")
  assert_equal "caf\u00e9", req.query_value("q")
  assert_equal "\u65e5\u672c", req.query_value("lang")
  assert_equal "\u65e5", req.form_value("name")
  assert_equal "caf\u00e9", req.form_or_query_value("note")
  assert_equal "caf\u00e9", Cybertrain::Query.parse(req.utf8_query_string)[:q]
  assert_equal "caf\u00e9", Cybertrain::Query.decode("caf%C3%A9")
end

test "a gzip request body is inflated" do
  json = "{\"name\":\"café\"}"
  req = Cybertrain::Request.new("POST", "/api", { "content-encoding" => "gzip" }, Zlib.gzip(json))
  assert_equal json, req.decoded_body
end

test "a request whose body and headers were read out of a Hash of mixed values" do
  json = "{\"name\":\"caf\u00e9\"}"
  wire = { "body" => Zlib.gzip(json), "length" => "2", "attempts" => 1 }
  req = Cybertrain::Request.new("POST", "/api", { "content-encoding" => "gzip", "content-length" => wire["length"] }, wire["body"])
  assert_equal json, req.decoded_body
  assert_equal 2, req.content_length
  form = { "body" => "note=caf%C3%A9&lang=\u65e5", "attempts" => 1 }
  req = Cybertrain::Request.new("POST", "/f", { "content-type" => "application/x-www-form-urlencoded" }, form["body"])
  assert_equal "caf\u00e9", req.form_value("note")
  assert_equal "\u65e5", req.form_value("lang")
end

test "a value read out of parsed JSON escapes" do
  doc = JSON.parse("{\"title\":\"<b>caf\u00e9</b>\"}")
  assert_equal "&lt;b&gt;caf\u00e9&lt;/b&gt;", Cybertrain::Html.escape(doc["title"])
end

test "a time read out of parsed JSON casts" do
  doc = JSON.parse("{\"at\":\"2026-10-22 09:30:15\",\"bad\":\"2026-13-01 00:00:00\"}")
  at = Cybertrain::Cast.time_or_nil(doc["at"])
  assert_equal "2026-10-22T09:30:15Z", Cybertrain::Cast.iso8601(at)
  assert_nil Cybertrain::Cast.time_or_nil(doc["bad"])
  text = Cybertrain::Cast.str(doc["at"])
  assert_equal 2026, Cybertrain::Cast.parse_time(text).year
  assert Cybertrain::Cast.digits?(Cybertrain::Cast.str({ "n" => "42" }["n"]))
end

test "a time out of a Hash of mixed values casts" do
  row = { "id" => 1, "at" => "2026-01-31T23:59:59Z", "note" => nil }
  assert_equal 31, Cybertrain::Cast.parse_time(Cybertrain::Cast.str(row["at"])).day
  assert_nil Cybertrain::Cast.parse_time(Cybertrain::Cast.str(row["note"]))
end

Cybertrain::Test.run!
