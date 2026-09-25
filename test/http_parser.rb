require "cybertrain/http/parser"
require "cybertrain/test"

HttpParser = Cybertrain::HttpParser

test "parses a complete GET head with mixed-case headers and extra spaces" do
  head = HttpParser.parse_head("GET /posts?page=2 HTTP/1.1\r\nHost:   example.com  \r\nUSER-agent: curl/8\r\nAccept:  */*\r\n")
  assert_equal "GET", head.method
  assert_equal "/posts?page=2", head.target
  assert_equal "HTTP/1.1", head.http_version
  assert_equal "example.com", head.headers["host"]
  assert_equal "curl/8", head.headers["user-agent"]
  assert_equal "*/*", head.headers["accept"]
  assert_equal 3, head.headers.size
end

test "duplicate headers are joined with a comma" do
  head = HttpParser.parse_head("GET / HTTP/1.1\r\nAccept: text/html\r\naccept: application/json")
  assert_equal "text/html, application/json", head.headers["accept"]
end

test "a header value may contain colons" do
  head = HttpParser.parse_head("GET / HTTP/1.1\r\nHost: localhost:3000")
  assert_equal "localhost:3000", head.headers["host"]
end

test "head_end returns nil for an incomplete buffer" do
  assert_nil HttpParser.head_end("GET / HTTP/1.1\r\nHost: x\r\n")
  assert_nil HttpParser.head_end("")
end

test "head_end returns the index of the blank line" do
  buffer = "GET / HTTP/1.1\r\nHost: x\r\n\r\nbody"
  idx = HttpParser.head_end(buffer)
  assert_equal 23, idx
  assert_equal "GET / HTTP/1.1\r\nHost: x", buffer[0, idx]
  assert_equal "body", buffer[idx + HttpParser::HEAD_END.size, 4]
end

test "bad request line raises ParseError" do
  assert_raises("ParseError") { HttpParser.parse_head("GARBAGE") }
  assert_raises("ParseError") { HttpParser.parse_head("GET /\r\nHost: x") }
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1 extra") }
  assert_raises("ParseError") { HttpParser.parse_head("") }
end

test "header line without a colon raises ParseError" do
  msg = assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\nno colon here") }
  assert_includes msg, "header"
end

test "header names with whitespace before the colon or inside are rejected" do
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\nHost : x") }
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\nHost\t: x") }
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\nX Y: x") }
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\n  : x") }
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\n folded: x") }
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\n: x") }
end

test "a bare CR inside a header line is rejected" do
  assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/1.1\r\nX-A: a\rInjected: b") }
end

test "empty lines before the request line are ignored" do
  head = HttpParser.parse_head("\r\nGET / HTTP/1.1\r\nHost: x")
  assert_equal "GET", head.method
  assert_equal "x", head.headers["host"]
  head = HttpParser.parse_head("\r\n\r\nPOST /a HTTP/1.0")
  assert_equal "POST", head.method
  assert_raises("ParseError") { HttpParser.parse_head("\r\n\r\n") }
end

test "HTTP/1.0 is accepted" do
  head = HttpParser.parse_head("GET /old HTTP/1.0")
  assert_equal "HTTP/1.0", head.http_version
  assert_equal 0, head.headers.size
end

test "HTTP/2.0 raises ParseError" do
  msg = assert_raises("ParseError") { HttpParser.parse_head("GET / HTTP/2.0\r\nHost: x") }
  assert_includes msg, "HTTP/2.0"
end

Cybertrain::Test.run!
