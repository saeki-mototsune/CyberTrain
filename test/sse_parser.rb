require "cybertrain/sse"
require "cybertrain/test"

# Cybertrain::Sse::Parser: the WHATWG server-sent-events line rules over
# chunks cut anywhere (mid-line, between CR and LF, inside a multi-byte
# character). Pure Ruby, so it also runs under CRuby.

P = Cybertrain::Sse::Parser

def feed_all(chunks)
  parser = P.new
  out = []
  chunks.each do |chunk|
    parser.feed(chunk) { |ev| out << ev }
  end
  out
end

def collect(text)
  feed_all([text])
end

test "two events in one chunk" do
  evs = collect("data: one\n\ndata: two\n\n")
  assert_equal(2, evs.size)
  assert_equal("one", evs[0].event_data)
  assert_equal("two", evs[1].event_data)
  assert_equal("message", evs[0].event_name)
  assert_equal("", evs[0].event_id)
  assert_equal(0, evs[0].event_retry_ms)
end

test "an event split across three chunks mid-line" do
  evs = feed_all(["da", "ta: hel", "lo\n\n"])
  assert_equal(1, evs.size)
  assert_equal("hello", evs[0].event_data)
end

test "CRLF and CR line ends" do
  evs = collect("data: a\r\n\r\ndata: b\r\rdata: c\n\n")
  assert_equal(3, evs.size)
  assert_equal("a", evs[0].event_data)
  assert_equal("b", evs[1].event_data)
  assert_equal("c", evs[2].event_data)
end

test "a CRLF split between CR and LF makes no extra blank line" do
  evs = feed_all(["data: a\r", "\ndata: b\r", "\n\r", "\n"])
  assert_equal(1, evs.size)
  assert_equal("a\nb", evs[0].event_data)
end

test "data lines are joined with LF and one space after the colon is dropped" do
  evs = collect("data: x\ndata:  y\ndata:z\ndata\n\n")
  assert_equal("x\n y\nz\n", evs[0].event_data)
end

test "comments and unknown fields are ignored" do
  evs = collect(": hi\nfoo: bar\ndata: ok\n: again\n\n")
  assert_equal(1, evs.size)
  assert_equal("ok", evs[0].event_data)
end

test "event: and id: and retry: are read" do
  evs = collect("event: tick\nid: 7\nretry: 2500\ndata: x\n\n")
  assert_equal("tick", evs[0].event_name)
  assert_equal("7", evs[0].event_id)
  assert_equal(2500, evs[0].event_retry_ms)
end

test "retry: with anything but digits is ignored" do
  evs = collect("retry: 12a\ndata: x\n\nretry: -5\ndata: y\n\nretry:\ndata: z\n\nretry: 1 2\ndata: w\n\n")
  assert_equal(4, evs.size)
  evs.each { |ev| assert_equal(0, ev.event_retry_ms) }
end

test "a very long retry is bounded, not an overflow" do
  evs = collect("retry: 99999999999999999999999999\ndata: x\n\n")
  assert(evs[0].event_retry_ms > 0)
end

test "an id with a NUL is ignored" do
  evs = collect("id: a\0b\ndata: x\n\n")
  assert_equal("", evs[0].event_id)
end

test "the last event id persists to later events" do
  evs = collect("id: 5\ndata: a\n\ndata: b\n\nid: 6\ndata: c\n\n")
  assert_equal("5", evs[0].event_id)
  assert_equal("5", evs[1].event_id)
  assert_equal("6", evs[2].event_id)
end

test "the event name resets after each event" do
  evs = collect("event: x\ndata: a\n\ndata: b\n\n")
  assert_equal("x", evs[0].event_name)
  assert_equal("message", evs[1].event_name)
end

test "a blank line with no data dispatches nothing" do
  assert_equal(0, collect("\n\n: c\n\nevent: x\n\n").size)
end

test "a field line with no colon is a field with an empty value" do
  evs = collect("data\n\n")
  assert_equal(1, evs.size)
  assert_equal("", evs[0].event_data)
  evs = collect("event\ndata: x\n\n")
  assert_equal("message", evs[0].event_name)
end

test "a BOM at the very start is ignored" do
  evs = collect("\xEF\xBB\xBFdata: a\n\n")
  assert_equal("a", evs[0].event_data)
  evs = feed_all(["\xEF\xBB".b, "\xBFdata: a\n\n".b])
  assert_equal("a", evs[0].event_data)
end

test "finish flushes a trailing event" do
  parser = P.new
  out = []
  parser.feed("data: a\n\ndata: b\ndata: c") { |ev| out << ev }
  assert_equal(1, out.size)
  parser.finish { |ev| out << ev }
  assert_equal(2, out.size)
  assert_equal("b\nc", out[1].event_data)
  parser.finish { |ev| out << ev }
  assert_equal(2, out.size)
end

test "a multi-byte character split across chunks survives" do
  text = "data: héllo こんにちは\n\n"
  chunks = []
  i = 0
  while i < text.bytesize
    chunks << text.byteslice(i, 1)
    i += 1
  end
  evs = feed_all(chunks)
  assert_equal(1, evs.size)
  assert_equal("héllo こんにちは", evs[0].event_data)
  assert_equal(true, evs[0].event_data.valid_encoding?)
end

test "a very long line fed in many small chunks" do
  parser = P.new
  out = []
  parser.feed("data: ") { |ev| out << ev }
  i = 0
  while i < 20000
    parser.feed("abcdefghij") { |ev| out << ev }
    i += 1
  end
  parser.feed("\n\n") { |ev| out << ev }
  assert_equal(1, out.size)
  assert_equal(200000, out[0].event_data.bytesize)
end

Cybertrain::Test.run!
