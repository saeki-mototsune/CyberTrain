require "cybertrain/http/request"
require "cybertrain/params"
require "cybertrain/test"

Request = Cybertrain::Request

def request_with(headers, version = "HTTP/1.1")
  Request.new("GET", "/", headers, "", "127.0.0.1", version)
end

test "target splits into path and query_string" do
  req = Request.new("GET", "/a/b?x=1&y=2", {}, "")
  assert_equal "/a/b", req.path
  assert_equal "x=1&y=2", req.query_string
  assert_equal "", req.remote_addr
  assert_equal "HTTP/1.1", req.http_version
end

test "query_string is empty when absent" do
  req = Request.new("GET", "/a/b", {}, "")
  assert_equal "/a/b", req.path
  assert_equal "", req.query_string
  req = Request.new("GET", "/a?", {}, "")
  assert_equal "/a", req.path
  assert_equal "", req.query_string
end

test "header lookup is case-insensitive" do
  req = request_with({ "host" => "example.com" })
  assert_equal "example.com", req.header("HOST")
  assert_equal "example.com", req.header("Host")
  assert_nil req.header("X-Missing")
end

test "header lookup works for headers given in mixed case" do
  req = request_with({ "Content-Type" => "text/plain" })
  assert_equal "text/plain", req.header("content-type")
end

test "content_length parses the header and defaults to 0" do
  assert_equal 42, request_with({ "content-length" => "42" }).content_length
  assert_equal 0, request_with({}).content_length
  assert_equal 0, request_with({ "content-length" => "abc" }).content_length
  assert_equal 0, request_with({ "content-length" => "-5" }).content_length
  assert_equal 0, request_with({ "content-length" => "" }).content_length
end

test "content_type keeps only the media type" do
  req = request_with({ "content-type" => "application/x-www-form-urlencoded; charset=utf-8" })
  assert_equal "application/x-www-form-urlencoded", req.content_type
  assert req.form?
  refute req.json?
  assert_equal "", request_with({}).content_type
  assert request_with({ "content-type" => "Application/JSON" }).json?
end

test "keep_alive? for HTTP/1.1" do
  assert request_with({}).keep_alive?
  refute request_with({ "connection" => "close" }).keep_alive?
  refute request_with({ "connection" => "Close" }).keep_alive?
  assert request_with({ "connection" => "keep-alive" }).keep_alive?
end

test "keep_alive? for HTTP/1.0" do
  refute request_with({}, "HTTP/1.0").keep_alive?
  assert request_with({ "connection" => "keep-alive" }, "HTTP/1.0").keep_alive?
  assert request_with({ "connection" => "Keep-Alive" }, "HTTP/1.0").keep_alive?
  refute request_with({ "connection" => "close" }, "HTTP/1.0").keep_alive?
end

test "keep_alive? matches Connection tokens exactly, not substrings" do
  assert request_with({ "connection" => "upgrade, closed-captions" }).keep_alive?
  refute request_with({ "connection" => "Upgrade, Close" }).keep_alive?
  refute request_with({ "connection" => "not-keep-alive" }, "HTTP/1.0").keep_alive?
  assert request_with({ "connection" => " Keep-Alive , upgrade" }, "HTTP/1.0").keep_alive?
  refute request_with({ "connection" => "keep-alive, close" }, "HTTP/1.0").keep_alive?
  refute request_with({ "connection" => "keep-alive, close" }).keep_alive?
end

test "content_length of an overlong all-digit value is at least Int64 max" do
  # Spinel saturates to 9223372036854775807; CRuby (which --regen uses)
  # returns the Bignum. Either way it exceeds any 413 limit the Server uses.
  assert request_with({ "content-length" => "99999999999999999999" }).content_length >= 9223372036854775807
end

test "method predicates" do
  assert Request.new("GET", "/", {}, "").get?
  assert Request.new("POST", "/", {}, "").post?
  assert Request.new("HEAD", "/", {}, "").head?
  assert Request.new("PATCH", "/", {}, "").patch?
  assert Request.new("PUT", "/", {}, "").put?
  assert Request.new("DELETE", "/", {}, "").delete?
  refute Request.new("GET", "/", {}, "").post?
end

test "override_method! upper-cases the new method" do
  req = Request.new("POST", "/posts/1", {}, "_method=delete")
  req.override_method!("delete")
  assert_equal "DELETE", req.method
  assert req.delete?
  refute req.post?
end

test "cookie_header returns the Cookie header or empty string" do
  assert_equal "a=1; b=2", request_with({ "cookie" => "a=1; b=2" }).cookie_header
  assert_equal "", request_with({}).cookie_header
end

test "body and headers are exposed" do
  req = Request.new("POST", "/echo", { "x-a" => "1" }, "payload", "10.0.0.1")
  assert_equal "payload", req.body
  assert_equal "1", req.headers["x-a"]
  assert_equal "10.0.0.1", req.remote_addr
end

test "utf8_query_string and utf8_body are the validated text, the same object on every call" do
  req = Request.new("POST", "/p?a=1&caf%C3%A9=2&\u00e9=x", { "content-type" => "application/x-www-form-urlencoded" }, "c=3&d[e]=\u3042")
  q = req.utf8_query_string
  assert_equal "a=1&caf%C3%A9=2&\u00e9=x", q
  assert q.equal?(req.utf8_query_string)
  b = req.utf8_body
  assert_equal "c=3&d[e]=\u3042", b
  assert b.equal?(req.utf8_body)
  # A String that is already UTF-8 is not copied (and under Spinel every String is).
  assert q.equal?(req.query_string)
  assert b.equal?(req.body)
  # The readers take the same text: one validation per field.
  assert_equal "3", req.form_value("c")
  assert_equal "1", req.query_value("a")
  assert b.equal?(req.utf8_body)
  assert q.equal?(req.utf8_query_string)
  # An empty field is valid text too.
  empty = Request.new("GET", "/", {}, "")
  assert_equal "", empty.utf8_query_string
  assert_equal "", empty.utf8_body
  assert empty.utf8_body.equal?(empty.utf8_body)
end

test "utf8_query_string and utf8_body: a raw invalid byte raises QueryMalformed on every call" do
  req = Request.new("POST", "/p?a=\x81", {}, "b=\x81")
  assert_raises("QueryMalformed") { req.utf8_query_string }
  assert_raises("QueryMalformed") { req.utf8_query_string }
  assert_raises("QueryMalformed") { req.utf8_body }
  assert_raises("QueryMalformed") { req.utf8_body }
  # so do the readers built on them, also for a key that is not asked for
  assert_raises("QueryMalformed") { req.query_value("x") }
  assert_raises("QueryMalformed") { req.form_value("x") }
  # half a character raw plus its other half escaped is not valid text
  half = Request.new("POST", "/p?a=\xC3%A9", {}, "a=\xC3%A9")
  assert_raises("QueryMalformed") { half.utf8_query_string }
  assert_raises("QueryMalformed") { half.utf8_body }
end

test "path_segments decodes once and returns the same Array every time" do
  req = Request.new("GET", "/caf%C3%A9/a+b/%41/?x=1", {}, "")
  segs = req.path_segments
  assert_equal ["caf\u00e9", "a+b", "A"], segs
  assert segs.equal?(req.path_segments)
  assert_equal [], Request.new("GET", "/", {}, "").path_segments
  assert_equal ["%ZZ", "a%2"], Request.new("GET", "/%ZZ/a%2", {}, "").path_segments
end

test "path_segments: an invalid decoded byte sequence is QueryMalformed and is not cached" do
  req = Request.new("GET", "/a/%81", {}, "")
  assert_raises("QueryMalformed") { req.path_segments }
  assert_raises("QueryMalformed") { req.path_segments }
end

test "path_segments: a raw invalid byte anywhere in the path is QueryMalformed, as is half a character raw" do
  ["/\x81", "/a/\x81b/c", "/\x81%zz", "/\x81%41", "/\xC3%A9"].each do |path|
    req = Request.new("GET", path, {}, "")
    assert_raises("QueryMalformed") { req.path_segments }
    assert_raises("QueryMalformed") { req.path_segments }
  end
  # a malformed escape alone stays literal
  assert_equal ["%zz"], Request.new("GET", "/%zz", {}, "").path_segments
end

# form_value / query_value raising inside a helper method, not in the
# assert_raises block (NOTES rule 32): the class name of what was raised.
def value_error(req, which, name)
  which == "form" ? req.form_value(name) : req.query_value(name)
  "none"
rescue Cybertrain::QueryTooMany
  "QueryTooMany"
rescue Cybertrain::QueryMalformed
  "QueryMalformed"
end

test "form_value and query_value: the last pair wins, absent is empty" do
  req = Request.new("POST", "/p?m=q1&m=q2&bare&z=", { "content-type" => "application/x-www-form-urlencoded" }, "m=f1&m=f2&&x=1")
  assert_equal "f2", req.form_value("m")
  assert_equal "q2", req.query_value("m")
  assert_equal "1", req.form_value("x")
  assert_equal "", req.query_value("x")
  assert_equal "", req.form_value("absent")
  assert_equal "", req.query_value("bare")
  assert_equal "", req.query_value("z")
  assert_equal "", Request.new("POST", "/p", {}, "").form_value("m")
  assert_equal "", Request.new("GET", "/p", {}, "").query_value("m")
end

test "form_value and query_value decode keys and values like a parse" do
  req = Request.new("POST", "/p?%5Fmethod=pu%74&a+b=1+2", {}, "%5fmethod=de%6Cete&caf%C3%A9=%E3%81%82&k=v%20w+x")
  assert_equal "delete", req.form_value("_method")
  assert_equal "put", req.query_value("_method")
  assert_equal "1 2", req.query_value("a b")
  assert_equal "\u3042", req.form_value("caf\u00e9")
  assert_equal "v w x", req.form_value("k")
  # an encoded key is matched as decoded text, not as raw bytes
  assert_equal "", req.query_value("%5Fmethod")
end

test "form_value and query_value: name[]= and name[x]= evict an earlier scalar, a later name= writes it again" do
  assert_equal "", Request.new("POST", "/p", {}, "_method=put&_method[]=x").form_value("_method")
  assert_equal "", Request.new("POST", "/p", {}, "_method=put&_method[a]=x").form_value("_method")
  assert_equal "", Request.new("POST", "/p", {}, "_method=put&%5Fmethod%5B%5D=x").form_value("_method")
  assert_equal "delete", Request.new("POST", "/p", {}, "_method[]=x&_method=delete").form_value("_method")
  assert_equal "", Request.new("POST", "/p", {}, "_method[]=x&_method[]=y").form_value("_method")
  # a malformed bracket run is a plain, different key and evicts nothing
  assert_equal "put", Request.new("POST", "/p", {}, "_method=put&_method[x=1").form_value("_method")
  # a key that merely starts with the name is another key
  assert_equal "put", Request.new("POST", "/p", {}, "_method=put&_methods=x&_method_y[]=z").form_value("_method")
  # the same answers as Params#[] after a parse
  body = "_method=put&_method[]=x&a=1&a[b]=2&a=3"
  assert_equal "", Cybertrain::Query.parse(body)["_method"].to_s
  assert_equal "3", Cybertrain::Query.parse(body)["a"].to_s
  assert_equal "3", Request.new("POST", "/p", {}, body).form_value("a")
end

test "form_value and query_value: MAX_PAIRS segments are counted, one more is QueryTooMany; invalid bytes are QueryMalformed" do
  # 4095 empty segments (counted, skipped) and the 4096th
  ok = ("&" * 4095) + "_method=put"
  assert_equal "put", Request.new("POST", "/p", {}, ok).form_value("_method")
  assert_equal "put", Request.new("POST", "/p?" + ok, {}, "").query_value("_method")
  assert_equal "QueryTooMany", value_error(Request.new("POST", "/p", {}, ok + "&x=1"), "form", "_method")
  assert_equal "QueryTooMany", value_error(Request.new("POST", "/p?" + ok + "&x=1", {}, ""), "query", "_method")
  assert_equal "QueryTooMany", value_error(Request.new("POST", "/p", {}, "\u00e9" + ("&" * 200000)), "form", "_method")
  # a raw invalid byte, wherever it is, even in a key that is not asked for
  assert_equal "QueryMalformed", value_error(Request.new("POST", "/p", {}, "a=1&\x81b=2&_method=put"), "form", "_method")
  assert_equal "QueryMalformed", value_error(Request.new("POST", "/p?_method=pu\x81", {}, ""), "query", "_method")
  # a percent-encoded one, in the matching value, and a malformed escape in the matching value
  assert_equal "QueryMalformed", value_error(Request.new("POST", "/p", {}, "_method=%81"), "form", "_method")
  assert_equal "QueryMalformed", value_error(Request.new("POST", "/p", {}, "_method=%zz"), "form", "_method")
  assert_equal "QueryMalformed", value_error(Request.new("POST", "/p", {}, "%zz=1&_method=put"), "form", "_method")
end

test "form_value on the 4096 x 32 body answers like the parse" do
  deep = "a" + ("[b]" * 32)
  body = (0...4095).map { |i| "#{deep}#{i}=1" }.join("&") + "&_method=put"
  assert_equal 4096, body.split("&").length
  assert_equal "put", Request.new("POST", "/p", {}, body).form_value("_method")
  assert_equal "", Request.new("POST", "/p", {}, body).form_value("a")
end

Cybertrain::Test.run!
