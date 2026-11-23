# `require "cybertrain/http/request"` alone still gives Request's format
# family, as it did before the HTTP layer moved to spinel-http
# (docs/design.md D91): the shim loads cybertrain/request_format, which
# requires the shim back. This program requires nothing else of the
# framework but the test harness, so it fails to compile if the shim stops
# loading it.
require "cybertrain/http/request"
require "cybertrain/test"

test "the request shim alone gives format, format_extension and the MIME table" do
  req = Cybertrain::Request.new("GET", "/articles/3.json", { "accept" => "text/html" }, "")
  assert_equal "", req.format_extension
  assert_equal :html, req.format
  json = Cybertrain::Request.new("GET", "/articles/3.json", { "accept" => "text/html" }, "")
  json.format_extension = "json"
  assert_equal :json, json.format
  assert_equal :csv, Cybertrain::Request.format_for_extension("csv")
  assert_equal "application/json; charset=utf-8", Cybertrain::Request.mime_type(:json)
end

Cybertrain::Test.run!
