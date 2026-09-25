# Requires the whole framework entry point at once: cross-file compile
# problems (require order, duplicated names) surface here, not in the
# per-feature tests that require only their own files.
require "cybertrain"
require "cybertrain/test"

test "the entry point exposes every M1 feature" do
  head = Cybertrain::HttpParser.parse_head("GET /posts?id=1 HTTP/1.1\r\nHost: x\r\nCookie: a=1")
  req = Cybertrain::Request.new(head.method, head.target, head.headers, "", "127.0.0.1", head.http_version)
  ctx = Cybertrain::Context.new(req)
  ctx.params = Cybertrain::Query.parse(req.query_string)
  assert_equal "1", ctx.params[:id]
  assert_equal({ "a" => "1" }, Cybertrain::Cookies.parse(req.cookie_header))
  ctx.response.body = Cybertrain::Html.escape("<b>")
  assert_includes ctx.response.to_http, "&lt;b&gt;"
  Cybertrain.logger.info("m1 ok")
  assert_equal "0.1.0", Cybertrain::VERSION
end

Cybertrain::Test.run!
