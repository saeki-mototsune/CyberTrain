require "cybertrain/http/response"
require "cybertrain/test"

Response = Cybertrain::Response

test "defaults" do
  res = Response.new
  assert_equal 200, res.status
  assert_equal "", res.body
  assert_equal 0, res.headers.size
  assert_equal 0, res.cookies.size
  refute res.performed?
  assert_equal "OK", res.status_text
end

test "status_text falls back to Unknown" do
  res = Response.new
  res.status = 404
  assert_equal "Not Found", res.status_text
  res.status = 599
  assert_equal "Unknown", res.status_text
end

test "header lookup is case-insensitive" do
  res = Response.new
  res.set_header("X-Frame-Options", "DENY")
  assert_equal "DENY", res.header("x-frame-options")
  assert_nil res.header("X-Missing")
  res.content_type = "text/plain"
  assert_equal "text/plain", res.header("content-type")
end

test "set_header replaces a header set with different case" do
  res = Response.new
  res.set_header("content-type", "text/plain")
  res.set_header("Content-Type", "application/json")
  assert_equal 1, res.headers.size
  assert_equal "application/json", res.header("Content-Type")
end

test "to_http exact bytes for a small body" do
  res = Response.new
  res.body = "hi"
  assert_equal "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 2\r\n\r\nhi", res.to_http
end

test "to_http keeps set headers and an explicit content type" do
  res = Response.new
  res.status = 201
  res.content_type = "text/plain"
  res.set_header("X-Request-Id", "abc")
  res.body = "héllo"
  expected = "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nX-Request-Id: abc\r\nContent-Length: 6\r\n\r\nhéllo"
  assert_equal expected, res.to_http
end

test "head_only omits the body but keeps Content-Length" do
  res = Response.new
  res.body = "hello"
  assert_equal "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 5\r\n\r\n", res.to_http(true)
end

test "cookies are emitted as separate Set-Cookie lines" do
  res = Response.new
  res.add_cookie("a=1; Path=/")
  res.add_cookie("b=2; Path=/; HttpOnly")
  res.status = 204
  expected = "HTTP/1.1 204 No Content\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 0\r\nSet-Cookie: a=1; Path=/\r\nSet-Cookie: b=2; Path=/; HttpOnly\r\n\r\n"
  assert_equal expected, res.to_http
  assert_equal ["a=1; Path=/", "b=2; Path=/; HttpOnly"], res.cookies
end

test "redirect sets 302, Location and performed" do
  res = Response.new
  res.redirect("/posts")
  assert_equal 302, res.status
  assert_equal "/posts", res.header("Location")
  assert res.performed?
  assert_includes res.to_http, "HTTP/1.1 302 Found\r\n"
  assert_includes res.to_http, "Location: /posts\r\n"
end

test "redirect accepts a status" do
  res = Response.new
  res.redirect("/login", 303)
  assert_equal 303, res.status
  assert_equal "See Other", res.status_text
end

test "set_header rejects CR or LF in the value" do
  res = Response.new
  msg = assert_raises("ArgumentError") { res.set_header("X-A", "a\r\nSet-Cookie: evil=1") }
  assert_includes msg, "X-A"
  assert_raises("ArgumentError") { res.set_header("X-A", "a\nb") }
  assert_raises("ArgumentError") { res.set_header("X-A", "a\rb") }
  assert_raises("ArgumentError") { res.set_header("X-A\r\nX-B", "v") }
  assert_equal 0, res.headers.size
end

test "redirect rejects a Location with CR or LF (no response splitting)" do
  res = Response.new
  assert_raises("ArgumentError") { res.redirect("/x\r\nSet-Cookie: evil=1") }
  refute res.performed?
  assert_equal 200, res.status
  refute res.to_http.include?("evil")
end

test "add_cookie rejects CR or LF" do
  res = Response.new
  assert_raises("ArgumentError") { res.add_cookie("a=1\r\nX-Evil: 1") }
  assert_equal 0, res.cookies.size
end

test "set_header replacing a header keeps its position" do
  res = Response.new
  res.set_header("X-A", "1")
  res.set_header("X-B", "2")
  res.set_header("X-C", "5")
  res.set_header("X-A", "3")
  res.set_header("x-b", "4")
  assert_equal 3, res.headers.size
  assert_equal "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nX-A: 3\r\nx-b: 4\r\nX-C: 5\r\nContent-Length: 0\r\n\r\n", res.to_http
end

test "drop_header removes a header whatever its case and leaves the rest in order" do
  res = Response.new
  res.set_header("X-A", "1")
  res.set_header("location", "/x")
  res.set_header("X-B", "2")
  assert_nil res.drop_header("Location")
  assert_nil res.header("Location")
  assert_equal 2, res.headers.size
  assert_nil res.drop_header("Location")
  assert_equal "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nX-A: 1\r\nX-B: 2\r\nContent-Length: 0\r\n\r\n", res.to_http
end

test "a headers Hash taken before drop_header, set_header or client_error! is still the live one" do
  res = Response.new
  taken = res.headers
  res.set_header("location", "/x")
  res.set_header("X-A", "1")
  res.set_header("Location", "/y")
  assert taken.equal?(res.headers)
  assert_equal "/y", taken["Location"]
  res.drop_header("LOCATION")
  assert taken.equal?(res.headers)
  assert_equal 1, taken.size
  res.set_header("location", "/z")
  assert_nil res.client_error!(400, "bad")
  assert taken.equal?(res.headers)
  taken["X-Late"] = "1"
  assert_nil taken["Location"]
  assert res.to_http.include?("X-Late: 1\r\n")
  assert res.to_http.include?("X-A: 1\r\n")
  refute res.to_http.include?("Location")
end

test "client_error! drops Location and Content-Disposition in any case, keeps the rest" do
  res = Response.new
  res.set_header("location", "/x")
  res.set_header("CONTENT-DISPOSITION", "attachment; filename=a.csv")
  res.set_header("Access-Control-Allow-Origin", "*")
  res.add_cookie("sid=abc; Path=/")
  assert_nil res.client_error!(400, "param is missing")
  assert_nil res.header("Location")
  assert_nil res.header("Content-Disposition")
  assert_equal "*", res.header("Access-Control-Allow-Origin")
  assert_equal ["sid=abc; Path=/"], res.cookies
  assert_equal 400, res.status
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type")
  assert_equal "param is missing", res.body
  assert !res.performed?
end

test "client_error! with an empty body answers the status text" do
  res = Response.new
  res.client_error!(400, "")
  assert_equal "Bad Request", res.body
  assert_equal 400, res.status
end

test "performed! marks the response" do
  res = Response.new
  res.performed!
  assert res.performed?
end

Cybertrain::Test.run!
