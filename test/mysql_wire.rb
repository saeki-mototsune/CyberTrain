# The MySQL wire encodings (length-encoded integers and strings, little-endian
# integers, NUL-terminated strings) and the packet framing over a Net stream:
# 16 MB splitting and its empty terminator, the sequence number, and a stream
# that ends or skips mid-packet. The fake stream implements the Net::Stream
# methods PacketIO calls, so the real framing code runs; no sockets.
require "cybertrain/net/socket"
require "cybertrain/db/error"
require "cybertrain/db/mysql/wire"
require "cybertrain/db/mysql/packet"
require "cybertrain/test"

Wire = Cybertrain::DB::MySQL::Wire
MAX_PACKET = 0xFFFFFF

# What a Net::Stream gives PacketIO: stream_write appends to one buffer,
# stream_read hands that buffer back, at most `max` bytes a call, "" at the
# end. One buffer for both directions, so a write followed by a read is the
# round trip.
class WireStream < Cybertrain::Net::Stream
  def initialize
    @wire_buf = String.new
    @wire_pos = 0
  end

  def stream_write(data, timer)
    @wire_buf << data
    nil
  end

  def stream_read(max, timer)
    left = @wire_buf.bytesize - @wire_pos
    return "" if left <= 0

    n = left < max ? left : max
    out = @wire_buf.byteslice(@wire_pos, n)
    @wire_pos += n
    out
  end

  def stream_label
    "fake:3306"
  end

  def wire_bytes
    @wire_buf
  end

  # Replaces what is buffered (a hand-made peer), read from the start.
  def wire_load(bytes)
    @wire_buf = String.new
    @wire_buf << bytes
    @wire_pos = 0
    nil
  end
end

# All 256 byte values, NUL and 0x80..0xFF included; binary-tagged, as
# bytes from a socket are (PacketIO answers binary Strings, and `==`
# compares the encoding too under CRuby).
def byte_table
  out = "0" * 256
  out.force_encoding("BINARY")
  i = 0
  while i < 256
    out.setbyte(i, i)
    i += 1
  end
  out
end

# `n` bytes of the repeating byte table: binary, with NULs, so a copy that
# stops at a NUL or counts characters fails.
def pattern(n)
  s = byte_table
  s = s + s while s.bytesize < n
  s.byteslice(0, n)
end

def hex(s)
  out = String.new
  i = 0
  while i < s.bytesize
    out << (s.getbyte(i) + 256).to_s(16).byteslice(1, 2)
    i += 1
  end
  out
end

def header_of(bytes, at)
  [bytes.getbyte(at) + (bytes.getbyte(at + 1) << 8) + (bytes.getbyte(at + 2) << 16), bytes.getbyte(at + 3)]
end

test "lenenc_int encodes each size class" do
  assert_equal "00", hex(Wire.lenenc_int(0))
  assert_equal "fa", hex(Wire.lenenc_int(250))
  assert_equal "fcfb00", hex(Wire.lenenc_int(251))
  assert_equal "fcffff", hex(Wire.lenenc_int(0xFFFF))
  assert_equal "fd000001", hex(Wire.lenenc_int(0x10000))
  assert_equal "fdffffff", hex(Wire.lenenc_int(0xFFFFFF))
  assert_equal "fe0000000100000000", hex(Wire.lenenc_int(0x1000000))
  assert_equal "feffffffffffffff7f", hex(Wire.lenenc_int(0x7FFFFFFFFFFFFFFF))
end

test "lenenc_int round trips at the boundaries" do
  [0, 1, 250, 251, 252, 0xFFFF, 0x10000, 0xFFFFFF, 0x1000000, 0x7FFFFFFF, 0x100000000, 0x7FFFFFFFFFFFFFFF].each do |n|
    enc = Wire.lenenc_int(n)
    got = Wire.read_lenenc_int(enc, 0)
    assert_equal n, got[0]
    assert_equal enc.bytesize, got[1]
  end
end

test "read_lenenc_int reads at an offset and reports the next position" do
  buf = String.new
  buf << "ab"
  buf << Wire.lenenc_int(300)
  buf << "z"
  got = Wire.read_lenenc_int(buf, 2)
  assert_equal 300, got[0]
  assert_equal 5, got[1]
  assert_equal 122, buf.getbyte(got[1])
end

test "read_lenenc_int refuses NULL, the error marker and short input" do
  assert_raises("Cybertrain::DB::Error") { Wire.read_lenenc_int("\xFB".b, 0) }
  assert_raises("Cybertrain::DB::Error") { Wire.read_lenenc_int("\xFF".b, 0) }
  assert_raises("Cybertrain::DB::Error") { Wire.read_lenenc_int("\xFC\x01".b, 0) }
  assert_raises("Cybertrain::DB::Error") { Wire.read_lenenc_int("\xFE\x01\x00\x00\x00\x00\x00\x00".b, 0) }
  assert_raises("Cybertrain::DB::Error") { Wire.read_lenenc_int("", 0) }
  assert_raises("Cybertrain::DB::Error") { Wire.lenenc_int(-1) }
end

test "lenenc_str round trips, with NUL and 4-byte UTF-8" do
  [byte_table, "", "plain", "\u{1F600} あ", "a\0b\0"].each do |text|
    enc = Wire.lenenc_str(text)
    got = Wire.read_lenenc_str(enc, 0)
    assert_equal text.bytesize, got[0].bytesize
    assert_equal text.b, got[0].b
    assert_equal enc.bytesize, got[1]
  end
  assert_equal "03616263", hex(Wire.lenenc_str("abc"))
  assert_equal "00", hex(Wire.lenenc_str(""))
end

test "a long lenenc_str uses the 3-byte length" do
  text = pattern(70_000)
  enc = Wire.lenenc_str(text)
  assert_equal "fd701101", hex(enc.byteslice(0, 4))
  got = Wire.read_lenenc_str(enc, 0)
  assert_equal text.bytesize, got[0].bytesize
  assert_equal true, got[0].b == text.b
  assert_equal 70_004, got[1]
end

test "read_lenenc_str fails when the string is cut short" do
  assert_raises("Cybertrain::DB::Error") { Wire.read_lenenc_str("\x05ab".b, 0) }
  assert_raises("Cybertrain::DB::Error") { Wire.read_lenenc_str("\xFB".b, 0) }
end

test "read_lenenc_str_or_nil gives nil for 0xFB and the string otherwise" do
  buf = String.new
  buf << Wire.lenenc_str("a")
  buf << "\xFB".b
  buf << Wire.lenenc_str("")
  first = Wire.read_lenenc_str_or_nil(buf, 0)
  assert_equal "a", first[0]
  assert_equal 2, first[1]
  second = Wire.read_lenenc_str_or_nil(buf, 2)
  assert_nil second[0]
  assert_equal 3, second[1]
  third = Wire.read_lenenc_str_or_nil(buf, 3)
  assert_equal "", third[0]
  assert_equal 4, third[1]
end

test "int_le and read_int_le agree for 1 to 8 bytes" do
  assert_equal "0102", hex(Wire.int_le(0x0201, 2))
  assert_equal "010203", hex(Wire.int_le(0x030201, 3))
  assert_equal "01020304", hex(Wire.int_le(0x04030201, 4))
  assert_equal "0100000000000000", hex(Wire.int_le(1, 8))
  assert_equal "ff", hex(Wire.int_le(255, 1))
  assert_equal "ffffffff", hex(Wire.int_le(-1, 4))
  assert_equal "00", hex(Wire.int_le(0, 1))
  [[0, 1], [255, 1], [0xFFFF, 2], [0xABCDEF, 3], [0xFFFFFFFF, 4], [0x123456789A, 5], [0x7FFFFFFFFFFFFFFF, 8]].each do |pair|
    enc = Wire.int_le(pair[0], pair[1])
    assert_equal pair[1], enc.bytesize
    assert_equal pair[0], Wire.read_int_le(enc, 0, pair[1])
  end
  assert_equal 0x0201, Wire.read_int_le("xx\x01\x02".b, 2, 2)
  assert_raises("Cybertrain::DB::Error") { Wire.read_int_le("\x01\x02".b, 1, 2) }
end

test "null_str reads up to the NUL and steps past it" do
  buf = "mysql_native_password\0rest\0".b
  got = Wire.null_str(buf, 0)
  assert_equal "mysql_native_password", got[0]
  assert_equal 22, got[1]
  again = Wire.null_str(buf, got[1])
  assert_equal "rest", again[0]
  assert_equal 27, again[1]
  empty = Wire.null_str("\0".b, 0)
  assert_equal "", empty[0]
  assert_equal 1, empty[1]
  assert_raises("Cybertrain::DB::Error") { Wire.null_str("abc".b, 0) }
end

test "a small packet has a 4-byte header and the sequence advances" do
  stream = WireStream.new
  io = Cybertrain::DB::MySQL::PacketIO.new(stream)
  io.write_packet("ping")
  io.write_packet("")
  io.write_packet(pattern(300))
  bytes = stream.wire_bytes
  assert_equal [4, 0], header_of(bytes, 0)
  assert_equal "ping", bytes.byteslice(4, 4)
  assert_equal [0, 1], header_of(bytes, 8)
  assert_equal [300, 2], header_of(bytes, 12)
  assert_equal 316, bytes.bytesize
end

test "reset_sequence starts the next exchange at 0" do
  stream = WireStream.new
  io = Cybertrain::DB::MySQL::PacketIO.new(stream)
  io.write_packet("a")
  io.write_packet("b")
  io.reset_sequence
  io.write_packet("c")
  bytes = stream.wire_bytes
  assert_equal [1, 0], header_of(bytes, 0)
  assert_equal [1, 1], header_of(bytes, 5)
  assert_equal [1, 0], header_of(bytes, 10)
end

test "the sequence wraps at 256" do
  stream = WireStream.new
  io = Cybertrain::DB::MySQL::PacketIO.new(stream)
  300.times { io.write_packet("x") }
  bytes = stream.wire_bytes
  assert_equal [1, 255], header_of(bytes, 255 * 5)
  assert_equal [1, 0], header_of(bytes, 256 * 5)
  assert_equal [1, 43], header_of(bytes, 299 * 5)
end

test "a packet written by the client is read back" do
  stream = WireStream.new
  writer = Cybertrain::DB::MySQL::PacketIO.new(stream)
  writer.write_packet("hello")
  writer.write_packet("")
  reader = Cybertrain::DB::MySQL::PacketIO.new(stream)
  assert_equal "hello", reader.read_packet
  assert_equal "", reader.read_packet
end

test "split_packet_roundtrip: 0xFFFFFF" do
  payload = pattern(MAX_PACKET)
  stream = WireStream.new
  Cybertrain::DB::MySQL::PacketIO.new(stream).write_packet(payload)
  bytes = stream.wire_bytes
  # One full packet, then the empty one that says it is over.
  assert_equal MAX_PACKET + 8, bytes.bytesize
  assert_equal [MAX_PACKET, 0], header_of(bytes, 0)
  assert_equal [0, 1], header_of(bytes, MAX_PACKET + 4)
  back = Cybertrain::DB::MySQL::PacketIO.new(stream).read_packet
  assert_equal MAX_PACKET, back.bytesize
  assert_equal true, back == payload
end

test "split_packet_roundtrip: 0xFFFFFF + 1" do
  payload = pattern(MAX_PACKET + 1)
  stream = WireStream.new
  Cybertrain::DB::MySQL::PacketIO.new(stream).write_packet(payload)
  bytes = stream.wire_bytes
  assert_equal MAX_PACKET + 1 + 8, bytes.bytesize
  assert_equal [MAX_PACKET, 0], header_of(bytes, 0)
  assert_equal [1, 1], header_of(bytes, MAX_PACKET + 4)
  back = Cybertrain::DB::MySQL::PacketIO.new(stream).read_packet
  assert_equal MAX_PACKET + 1, back.bytesize
  assert_equal true, back == payload
end

test "split_packet_roundtrip: 2 * 0xFFFFFF + 5" do
  payload = pattern(2 * MAX_PACKET + 5)
  stream = WireStream.new
  Cybertrain::DB::MySQL::PacketIO.new(stream).write_packet(payload)
  bytes = stream.wire_bytes
  assert_equal 2 * MAX_PACKET + 5 + 12, bytes.bytesize
  assert_equal [MAX_PACKET, 0], header_of(bytes, 0)
  assert_equal [MAX_PACKET, 1], header_of(bytes, MAX_PACKET + 4)
  assert_equal [5, 2], header_of(bytes, 2 * MAX_PACKET + 8)
  io = Cybertrain::DB::MySQL::PacketIO.new(stream)
  back = io.read_packet
  assert_equal 2 * MAX_PACKET + 5, back.bytesize
  assert_equal true, back == payload
  # The reader's sequence is at 3 after the split packet: the next write of
  # the same PacketIO carries it.
  io.write_packet("next")
  assert_equal [4, 3], header_of(stream.wire_bytes, stream.wire_bytes.bytesize - 8)
end

test "a packet with the wrong sequence number is ConnectionLost" do
  stream = WireStream.new
  stream.wire_load("\x03\x00\x00\x01abc".b)
  io = Cybertrain::DB::MySQL::PacketIO.new(stream)
  message = assert_raises("Cybertrain::DB::ConnectionLost") { io.read_packet }
  assert_equal "fake:3306: MySQL packet out of sequence (expected 0, got 1)", message
end

test "a continuation packet out of sequence is ConnectionLost" do
  stream = WireStream.new
  head = Wire.int_le(MAX_PACKET, 3)
  head << "\x00".b
  stream.wire_load(head)
  stream.stream_write(pattern(MAX_PACKET), nil)
  tail = Wire.int_le(2, 3)
  tail << "\x05".b
  tail << "hi"
  stream.stream_write(tail, nil)
  io = Cybertrain::DB::MySQL::PacketIO.new(stream)
  assert_raises("Cybertrain::DB::ConnectionLost") { io.read_packet }
end

test "a stream that ends inside a packet is ConnectionLost" do
  stream = WireStream.new
  stream.wire_load("\x05\x00\x00\x00ab".b)
  io = Cybertrain::DB::MySQL::PacketIO.new(stream)
  assert_raises("Cybertrain::DB::ConnectionLost") { io.read_packet }
  gone = WireStream.new
  gone.wire_load("\x05\x00".b)
  assert_raises("Cybertrain::DB::ConnectionLost") { Cybertrain::DB::MySQL::PacketIO.new(gone).read_packet }
  empty = WireStream.new
  assert_raises("Cybertrain::DB::ConnectionLost") { Cybertrain::DB::MySQL::PacketIO.new(empty).read_packet }
end

test "a failed write is ConnectionLost" do
  io = Cybertrain::DB::MySQL::PacketIO.new(BrokenStream.new)
  assert_raises("Cybertrain::DB::ConnectionLost") { io.write_packet("x") }
end

class BrokenStream < Cybertrain::Net::Stream
  def stream_write(data, timer)
    raise Cybertrain::Net::ConnectError, "fake:3306: connection reset while writing"
  end

  def stream_label
    "fake:3306"
  end
end

Cybertrain::Test.run!
