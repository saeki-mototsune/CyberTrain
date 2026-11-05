# Cybertrain::SSE.event: the text/event-stream format. Pure Ruby.
require "cybertrain/http/sse"
require "cybertrain/test"

SSE = Cybertrain::SSE

test "every field, and one data line per line" do
  assert_equal "event: x\nid: 7\nretry: 3000\ndata: a\ndata: b\n\n",
               SSE.event("a\nb", event: "x", id: "7", retry_ms: 3000)
end

test "the defaults leave the fields out" do
  assert_equal "data: hello\n\n", SSE.event("hello")
  assert_equal "data: \n\n", SSE.event("")
end

test "CR and CRLF in the data start new data lines" do
  assert_equal "data: a\ndata: b\ndata: c\ndata: \n\n", SSE.event("a\r\nb\rc\n")
end

test "an event or id with a newline raises" do
  assert_raises("ArgumentError") { SSE.event("x", event: "a\nb") }
  assert_raises("ArgumentError") { SSE.event("x", id: "1\r") }
end

test "a comment line" do
  assert_equal ": ping\n\n", SSE.comment("ping")
end

Cybertrain::Test.run!
