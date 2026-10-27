# Cybertrain::Net::Reader over a fake Stream that hands out fixed chunks:
# fill_to buffers without consuming, peek_bytes looks at the buffer, and a
# TimeoutError mid-fill leaves what was already buffered in place (what lets
# a later read resume a frame split across timeouts). No sockets.
require "cybertrain/net/socket"
require "cybertrain/test"

# Returns `chunks` one per stream_read, then "" (end of stream). The call
# numbered `fail_at` (0-based; -1 for never) raises Net::TimeoutError
# instead, and the next call returns the chunk it would have.
class FakeStream < Cybertrain::Net::Stream
  def initialize(chunks, fail_at)
    @fake_chunks = chunks
    @fake_fail_at = fail_at
    @fake_calls = 0
    @fake_next = 0
  end

  def stream_read(max, timer)
    attempt = @fake_calls
    @fake_calls += 1
    raise Cybertrain::Net::TimeoutError, "fake:1: reading timed out" if attempt == @fake_fail_at
    return "" if @fake_next >= @fake_chunks.size

    @fake_next += 1
    @fake_chunks[@fake_next - 1]
  end

  def stream_label
    "fake:1"
  end
end

def fake_timer
  Cybertrain::Net::Timer.new("fake:1", 1, 5)
end

test "fill_to buffers without consuming" do
  reader = Cybertrain::Net::Reader.new(FakeStream.new(["ab", "cd"], -1), fake_timer)
  assert_equal true, reader.fill_to(3)
  assert_equal "abc", reader.peek_bytes(3)
  assert_equal "abcd", reader.read_exact(4)
end

test "fill_to is false at end of stream" do
  reader = Cybertrain::Net::Reader.new(FakeStream.new(["ab", "cd"], -1), fake_timer)
  assert_equal false, reader.fill_to(10)
  assert_equal "abcd", reader.peek_bytes(4)
end

test "a timeout leaves the buffer intact" do
  reader = Cybertrain::Net::Reader.new(FakeStream.new(["ab", "cd"], 1), fake_timer)
  message = assert_raises("TimeoutError") { reader.fill_to(4) }
  assert_equal "fake:1: reading timed out", message
  reader.reader_timer = fake_timer
  assert_equal "ab", reader.peek_bytes(2)
  assert_equal true, reader.fill_to(4)
  assert_equal "abcd", reader.read_exact(4)
end

Cybertrain::Test.run!
