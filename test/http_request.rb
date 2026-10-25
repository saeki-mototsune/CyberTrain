require "zlib"
require "cybertrain/http/request"
require "cybertrain/http/client_error"
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

test "content_length of an overlong all-digit value is Int64 max, not a RangeError" do
  # More than 18 digits is not parsed (Spinel's to_i raises past 2**63-1,
  # NOTES rule 25); 18 digits still are. Either way it exceeds any 413 limit.
  assert_equal 9223372036854775807, request_with({ "content-length" => "99999999999999999999" }).content_length
  assert_equal 9223372036854775807, request_with({ "content-length" => "9223372036854775808" }).content_length
  assert_equal 999999999999999999, request_with({ "content-length" => "999999999999999999" }).content_length
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

test "form_or_query_value: the form body wins, the query string is the fallback, absent is empty" do
  form = { "content-type" => "application/x-www-form-urlencoded" }
  req = Request.new("POST", "/p?m=q&only=q", form, "m=f&x=1")
  assert_equal "f", req.form_or_query_value("m")
  assert_equal "q", req.form_or_query_value("only")
  assert_equal "1", req.form_or_query_value("x")
  assert_equal "", req.form_or_query_value("absent")
  # a body that is not a form is never read
  assert_equal "q", Request.new("POST", "/p?m=q", {}, "m=f").form_or_query_value("m")
  assert_equal "", Request.new("POST", "/p", {}, "m=f").form_or_query_value("m")
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

# ---- decoded_body: identity bodies, the limit, and the inflater contract --
# The gzip inflater (Cybertrain::GzipFFI, system zlib through Spinel FFI)
# cannot load under CRuby, so this program sees Request's default: every gzip
# body is undecodable until `require "cybertrain"` installs one. The real
# inflate is tested in test/http_gunzip.rb (a compiled-binary snapshot).

def encoded_request(body, encoding)
  Request.new("POST", "/api", { "content-encoding" => encoding }, body)
end

# The bare class name of what decoded_body raises, "" when nothing does
# (Class#name has no namespace under Spinel, NOTES rule 46).
def decode_error(req, limit)
  req.decoded_body(limit)
  ""
rescue Cybertrain::QueryInvalid => e
  Cybertrain::ClientError.bare_name(e.class.name.to_s)
end

test "content_encoding is the lowercased header, empty when absent" do
  assert_equal "", Request.new("POST", "/", {}, "x").content_encoding
  assert_equal "gzip", Request.new("POST", "/", { "content-encoding" => " GZIP " }, "x").content_encoding
end

test "decoded_body is the body itself without a Content-Encoding or with identity, the same String every time" do
  plain = Request.new("POST", "/", {}, "{\"a\":1}")
  assert_equal "{\"a\":1}", plain.decoded_body
  assert plain.decoded_body.equal?(plain.decoded_body)
  identity = Request.new("POST", "/", { "content-encoding" => "identity" }, "raw")
  assert_equal "raw", identity.decoded_body
end

test "a plain body over the limit is BodyTooLarge, at the limit it passes" do
  req = Request.new("POST", "/", {}, "a" * 100)
  assert_equal "BodyTooLarge", decode_error(req, 99)
  assert_equal "", decode_error(req, 100)
end

test "a cached body is checked against a smaller limit asked for later" do
  req = Request.new("POST", "/", {}, "a" * 100)
  assert_equal 100, req.decoded_body(100).bytesize
  assert_equal "BodyTooLarge", decode_error(req, 50)
  assert_equal "", decode_error(req, 100)
end

test "decoded_body refuses an encoding it does not decode" do
  assert_equal "BodyUndecodable", decode_error(encoded_request("x", "deflate"), 1000)
  assert_equal "BodyUndecodable", decode_error(encoded_request("x", "br"), 1000)
end

test "a gzip body that is not gzip, or too short to be, is undecodable before the inflater is asked" do
  assert_equal "BodyUndecodable", decode_error(encoded_request("not gzip at all, but long enough to try", "gzip"), 1000)
  assert_equal "BodyUndecodable", decode_error(encoded_request("short", "gzip"), 1000)
  assert_equal "BodyUndecodable", decode_error(encoded_request("x" * 18, "x-gzip"), 1000)
end

test "a well-formed gzip body is undecodable while no inflater is installed, and the error is not cached" do
  gz = Zlib.gzip("hello")
  req = encoded_request(gz, "gzip")
  assert_equal "BodyUndecodable", decode_error(req, 1000)
  assert_equal "BodyUndecodable", decode_error(req, 1000)
  assert_equal "BodyUndecodable", decode_error(encoded_request(gz, "x-gzip"), 1000)
end

test "an installed inflater is what decodes gzip, and it is given the body and the limit" do
  seen = Array.new(0) { "" }
  previous = Request.inflater
  Request.inflater = ->(data, limit) { seen << "#{data.bytesize}:#{limit}"; "inflated" }
  gz = Zlib.gzip("hello")
  assert_equal "inflated", encoded_request(gz, "gzip").decoded_body(1000)
  assert_equal ["#{gz.bytesize}:1000"], seen
  Request.inflater = previous
  assert_equal "BodyUndecodable", decode_error(encoded_request(gz, "gzip"), 1000)
end

# ---- multipart ---------------------------------------------------------------

MP_BOUNDARY = "----ReqBoundary7"

def multipart_headers(boundary = MP_BOUNDARY)
  { "content-type" => "multipart/form-data; boundary=#{boundary}" }
end

# A body of text parts and one file part, every piece binary.
def multipart_body(token, method_override)
  out = "".b
  out << "--#{MP_BOUNDARY}\r\nContent-Disposition: form-data; name=\"authenticity_token\"\r\n\r\n#{token}\r\n".b
  out << "--#{MP_BOUNDARY}\r\nContent-Disposition: form-data; name=\"_method\"\r\n\r\n#{method_override}\r\n".b
  out << "--#{MP_BOUNDARY}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.bin\"\r\n".b
  out << "Content-Type: application/octet-stream\r\n\r\n\x00\xFF\r\n--x\r\n".b
  out << "\r\n--#{MP_BOUNDARY}--\r\n".b
  out
end

test "multipart? is true for multipart/form-data only, form? stays false" do
  req = Request.new("POST", "/p", multipart_headers, "")
  assert req.multipart?
  refute req.form?
  refute req.json?
  assert Request.new("POST", "/p", { "content-type" => "Multipart/Form-Data; boundary=x" }, "").multipart?
  refute Request.new("POST", "/p", { "content-type" => "multipart/mixed; boundary=x" }, "").multipart?
  refute Request.new("POST", "/p", { "content-type" => "application/x-www-form-urlencoded" }, "").multipart?
  refute Request.new("POST", "/p", {}, "").multipart?
end

test "multipart_boundary reads the parameter the media type drops" do
  assert_equal MP_BOUNDARY, Request.new("POST", "/p", multipart_headers, "").multipart_boundary
  quoted = { "content-type" => "multipart/form-data; boundary=\"a b\"" }
  assert_equal "a b", Request.new("POST", "/p", quoted, "").multipart_boundary
  assert_equal "", Request.new("POST", "/p", { "content-type" => "multipart/form-data" }, "").multipart_boundary
  assert_equal "", Request.new("POST", "/p", {}, "").multipart_boundary
end

test "multipart_form parses once and is the same object every time" do
  req = Request.new("POST", "/p", multipart_headers, multipart_body("tok", "patch"))
  parsed = req.multipart_form
  assert_equal 2, parsed.text_count
  assert_equal 1, parsed.file_count
  assert_equal "tok", parsed.text_value("authenticity_token")
  assert parsed.equal?(req.multipart_form)
  file = parsed.file_at(0)
  assert_equal "a.bin", file.original_filename
  assert_equal 9, file.byte_size
end

test "form_or_query_value reads a multipart text part: the body wins, a file never answers, the query is the fallback" do
  req = Request.new("POST", "/p?_method=put&only=q", multipart_headers, multipart_body("tok", "patch"))
  assert_equal "tok", req.form_or_query_value("authenticity_token")
  assert_equal "patch", req.form_or_query_value("_method")
  assert_equal "q", req.form_or_query_value("only")
  assert_equal "", req.form_or_query_value("file")
  assert_equal "", req.form_or_query_value("absent")
  # an empty text part falls back to the query string, as an empty form value does
  empty = Request.new("POST", "/p?_method=put", multipart_headers, multipart_body("tok", ""))
  assert_equal "put", empty.form_or_query_value("_method")
  # a multipart body is read only when the request says it is one
  plain = Request.new("POST", "/p", {}, multipart_body("tok", "patch"))
  assert_equal "", plain.form_or_query_value("_method")
end

def multipart_error(req)
  req.multipart_form
  ""
rescue Cybertrain::QueryInvalid => e
  Cybertrain::ClientError.bare_name(e.class.name.to_s)
end

test "multipart_form refuses an encoded body and a malformed one, and does not cache the raise" do
  gz_headers = multipart_headers
  gz_headers["content-encoding"] = "gzip"
  req = Request.new("POST", "/p", gz_headers, multipart_body("tok", "patch"))
  assert_equal "MultipartMalformed", multipart_error(req)
  assert_equal "MultipartMalformed", multipart_error(req)
  identity_headers = multipart_headers
  identity_headers["content-encoding"] = "identity"
  assert_equal "", multipart_error(Request.new("POST", "/p", identity_headers, multipart_body("tok", "patch")))
  assert_equal "MultipartMalformed", multipart_error(Request.new("POST", "/p", multipart_headers, "no delimiter here"))
  assert_equal "MultipartMalformed", multipart_error(Request.new("POST", "/p", { "content-type" => "multipart/form-data" }, "x"))
  bad = Request.new("POST", "/p?_method=put", multipart_headers, "no delimiter here")
  assert_equal "MultipartMalformed", multipart_error(bad)
  assert_equal "MultipartMalformed", multipart_error(bad)
end

# header_params / header_scheme (issue #77). Each block's locals have names
# of their own (spikes/NOTES.md rule 63).
def auth_request(value)
  Request.new("GET", "/", { "authorization" => value }, "", "127.0.0.1")
end

test "header_params reads a Digest-style header: scheme dropped, names lowercased, quotes undone" do
  digest = auth_request("Digest username=\"Mufasa\", Realm=\"testrealm@host.com\", nonce=\"dcd98b\", uri=\"/dir/index.html\", qop=auth, nc=00000001")
  dp = digest.header_params("Authorization")
  assert_equal 6, dp.size
  assert_equal "Mufasa", dp["username"]
  assert_equal "testrealm@host.com", dp["realm"]
  assert_equal "/dir/index.html", dp["uri"]
  assert_equal "auth", dp["qop"]
  assert_equal "00000001", dp["nc"]
  assert_equal "Digest", digest.header_scheme("authorization")
end

test "header_params treats ; and , as separators (Forwarded, Prefer), first occurrence wins" do
  fwd = Request.new("GET", "/", { "forwarded" => "for=192.0.2.60;proto=http;by=203.0.113.43, for=\"[2001:db8:cafe::17]:4711\";proto=https" }, "")
  fp = fwd.header_params("Forwarded")
  assert_equal 3, fp.size
  assert_equal "192.0.2.60", fp["for"]
  assert_equal "http", fp["proto"]
  assert_equal "203.0.113.43", fp["by"]
  assert_equal "", fwd.header_scheme("forwarded")
  prefer = Request.new("GET", "/", { "prefer" => "respond-async, wait=5;  handling = lenient , WAIT=10" }, "")
  pp = prefer.header_params("prefer")
  assert_equal 3, pp.size
  assert_equal "", pp["respond-async"]
  assert_equal "5", pp["wait"]
  assert_equal "lenient", pp["handling"]
  lone = Request.new("GET", "/", { "prefer" => "respond-async" }, "")
  assert lone.header_params("prefer").key?("respond-async")
  assert_equal "", lone.header_scheme("prefer")
end

test "header_params unquotes backslash escapes and keeps separators inside quotes" do
  quoted = auth_request("Vendor sig=\"a\\\"b\\\\c\", note=\"x, y; z\", empty=\"\", open=\"no end")
  qp = quoted.header_params("authorization")
  assert_equal "a\"b\\c", qp["sig"]
  assert_equal "x, y; z", qp["note"]
  assert_equal "", qp["empty"]
  assert_equal "no end", qp["open"]
  assert_equal "Vendor", quoted.header_scheme("authorization")
end

test "header_params skips junk, keeps bare names as empty values and trims blanks" do
  junk = auth_request("  Scheme   a = b ; c,, =x, \"junk\", d=e f ,")
  jp = junk.header_params("authorization")
  assert_equal 3, jp.size
  assert_equal "b", jp["a"]
  assert_equal "", jp["c"]
  assert_equal "e f", jp["d"]
  assert_equal "Scheme", junk.header_scheme("authorization")
end

test "header_scheme reads Bearer; the credential is a bare parameter" do
  bearer = auth_request("Bearer mF_9.B5f-4.1JqM")
  assert_equal "Bearer", bearer.header_scheme("Authorization")
  bp = bearer.header_params("authorization")
  assert_equal 1, bp.size
  assert bp.key?("mf_9.b5f-4.1jqm")
  lone_scheme = auth_request("Negotiate")
  assert_equal "", lone_scheme.header_scheme("authorization")
  assert lone_scheme.header_params("authorization").key?("negotiate")
end

test "header_params is empty for a missing header and one over 8 KiB" do
  missing = Request.new("GET", "/", {}, "")
  assert_equal 0, missing.header_params("authorization").size
  assert_equal "", missing.header_scheme("authorization")
  at_limit = auth_request("k=" + "v" * 8190)
  assert_equal 8190, at_limit.header_params("authorization")["k"].to_s.bytesize
  oversize = auth_request("Digest k=" + "v" * 8190)
  assert_equal 0, oversize.header_params("authorization").size
  assert_equal "", oversize.header_scheme("authorization")
  assert_equal 0, Request.parse_header_params("").size
end

test "header_params tolerates any bytes in values" do
  binary = Request.parse_header_params("k=\xff\x00v; z=\"\x81\\\x82\", n\x80=1, ok=2")
  assert_equal [0xff, 0, 0x76], binary["k"].to_s.bytes
  assert_equal [0x81, 0x82], binary["z"].to_s.bytes
  assert_equal "2", binary["ok"]
  assert binary.key?("n"), "the name ends at the first non-token byte"
end

Cybertrain::Test.run!
