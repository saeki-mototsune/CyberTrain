require "cybertrain/http/request"
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

test "query_params and form_params parse once and return the same Params every time" do
  req = Request.new("POST", "/p?a=1&b[]=2", { "content-type" => "application/x-www-form-urlencoded" }, "c=3&d[e]=4")
  q = req.query_params
  assert_equal "1", q["a"]
  assert_equal ["2"], q.list("b")
  assert q.equal?(req.query_params)
  f = req.form_params
  assert_equal "3", f["c"]
  assert_equal "4", f.nested("d")["e"]
  assert f.equal?(req.form_params)
  assert !q.equal?(f)
end

test "query_params and form_params of an empty query and body are cached empty Params" do
  req = Request.new("GET", "/", {}, "")
  assert req.query_params.empty?
  assert req.query_params.equal?(req.query_params)
  assert req.form_params.empty?
  assert req.form_params.equal?(req.form_params)
end

test "a parse that raises is not cached: every call raises again" do
  req = Request.new("POST", "/p?x=%zz", {}, "a=%zz")
  assert_raises("QueryMalformed") { req.query_params }
  assert_raises("QueryMalformed") { req.query_params }
  assert_raises("QueryMalformed") { req.form_params }
  assert_raises("QueryMalformed") { req.form_params }
end

Cybertrain::Test.run!
