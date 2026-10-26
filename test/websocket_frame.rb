require "cybertrain/websocket/frame"
require "cybertrain/test"

F = Cybertrain::WebSocket::Frame

def hdr(first, second, rest = "")
  r = rest.b
  out = ("\0" * (2 + r.bytesize)).b
  out.setbyte(0, first)
  out.setbyte(1, second)
  i = 0
  while i < r.bytesize
    out.setbyte(2 + i, r.getbyte(i))
    i += 1
  end
  out
end

def check(header, assembling, from_server)
  F.check_header(header, assembling, from_server)
end

test "accept_key matches RFC 6455" do
  assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", F.accept_key("dGhlIHNhbXBsZSBub25jZQ==")
end

test "a masked Hello encodes as in RFC 6455 5.7" do
  out = F.encode(F::OP_TEXT, "Hello", "\x37\xfa\x21\x3d".b)
  assert_equal "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58".b, out
end

test "an unmasked Hello" do
  assert_equal "\x81\x05Hello".b, F.encode(F::OP_TEXT, "Hello", "")
end

test "length encodings at 125, 126, 65535 and 65536" do
  key = "abcd".b
  [[125, 2], [126, 4], [65535, 4], [65536, 10]].each do |len, size|
    plain = F.encode(F::OP_BINARY, "x" * len, "")
    assert_equal len + size, plain.bytesize
    h = F.parse_header(plain)
    assert_equal len, h.frame_length
    assert_equal size, h.frame_header_size
    assert_equal false, h.frame_masked
    assert_equal "", h.frame_mask_key

    masked = F.encode(F::OP_BINARY, "x" * len, key)
    assert_equal len + size + 4, masked.bytesize
    m = F.parse_header(masked)
    assert_equal len, m.frame_length
    assert_equal size + 4, m.frame_header_size
    assert_equal true, m.frame_masked
    assert_equal key, m.frame_mask_key
  end
  assert_equal 125, F.encode(F::OP_BINARY, "x" * 125, "").getbyte(1)
  assert_equal 126, F.encode(F::OP_BINARY, "x" * 126, "").getbyte(1)
  assert_equal 127, F.encode(F::OP_BINARY, "x" * 65536, "").getbyte(1)
  assert_equal 0xff, F.encode(F::OP_BINARY, "x" * 65535, "").getbyte(3)
  assert_equal 1, F.encode(F::OP_BINARY, "x" * 65536, "").getbyte(7)
end

test "parse_header reads the flags" do
  h = F.parse_header("\x81\x05Hello".b)
  assert_equal true, h.frame_fin
  assert_equal 0, h.frame_rsv
  assert_equal F::OP_TEXT, h.frame_opcode
  h = F.parse_header("\x4a\x00".b)
  assert_equal false, h.frame_fin
  assert_equal 4, h.frame_rsv
  assert_equal F::OP_PONG, h.frame_opcode
end

test "parse_header asks for more bytes" do
  assert_equal 0, F.parse_header("\x81".b).frame_header_size
  assert_equal 0, F.parse_header("".b).frame_header_size
  assert_equal 0, F.parse_header("\x81\x7e\x01".b).frame_header_size
  assert_equal 0, F.parse_header("\x81\x7f\x00\x00\x00\x00\x00\x00\x01".b).frame_header_size
  assert_equal 0, F.parse_header("\x81\x85\x37\xfa\x21".b).frame_header_size
  assert_equal 0, F.parse_header("\x81\xfe\x01\x00\x01\x02\x03".b).frame_header_size
end

test "a 64-bit length with the top bit set is refused" do
  assert_raises("ProtocolError") { F.parse_header("\x82\x7f\x80\x00\x00\x00\x00\x00\x00\x00".b) }
end

test "unmask restores the payload" do
  key = "\x37\xfa\x21\x3d".b
  assert_equal "Hello".b, F.unmask("\x7f\x9f\x4d\x51\x58".b, key)
  assert_equal "", F.unmask("", key)
  assert_equal "Hello".b, F.unmask("Hello".b, "")
end

test "check_header accepts a plain server text frame" do
  assert_nil check(F.parse_header(hdr(0x81, 5)), false, true)
  assert_nil check(F.parse_header(hdr(0x81, 0x85, "abcd")), false, false)
  assert_nil check(F.parse_header(hdr(0x80, 0)), true, true)
end

test "check_header refuses a masked server frame" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0x81, 0x85, "abcd")), false, true) }
end

test "check_header refuses an unmasked client frame" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0x81, 5)), false, false) }
end

test "check_header refuses RSV bits" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0xc1, 5)), false, true) }
end

test "check_header refuses an unknown opcode" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0x83, 5)), false, true) }
end

test "check_header refuses a 126-byte ping" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0x89, 126, "\x00\x7e")), false, true) }
end

test "check_header refuses a ping without FIN" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0x09, 0)), false, true) }
end

test "check_header refuses a stray continuation" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0x80, 0)), false, true) }
end

test "check_header refuses a new text frame while assembling" do
  assert_raises("ProtocolError") { check(F.parse_header(hdr(0x81, 0)), true, true) }
end

test "check_header allows a control frame while assembling" do
  assert_nil check(F.parse_header(hdr(0x89, 0)), true, true)
end

test "the assembler joins fragments" do
  a = F::Assembler.new(100)
  assert_equal false, a.assembling?
  assert_equal false, a.add(F::OP_TEXT, false, "Hel")
  assert_equal true, a.assembling?
  assert_equal true, a.add(F::OP_CONTINUATION, true, "lo")
  msg = a.take_message
  assert_equal "Hello", msg.ws_data
  assert_equal :text, msg.ws_opcode
  assert_equal false, a.assembling?
end

test "the assembler handles an unfragmented binary message" do
  a = F::Assembler.new(100)
  assert_equal true, a.add(F::OP_BINARY, true, "\x00\x01".b)
  msg = a.take_message
  assert_equal :binary, msg.ws_opcode
  assert_equal "\x00\x01".b, msg.ws_data
  assert_equal true, a.add(F::OP_BINARY, true, "\x80\xff".b)
  assert_equal "\x80\xff".b, a.take_message.ws_data
  assert_equal true, a.add(F::OP_TEXT, true, "again")
  assert_equal "again", a.take_message.ws_data
end

test "the assembler enforces max_message across fragments" do
  a = F::Assembler.new(4)
  assert_equal false, a.add(F::OP_TEXT, false, "abc")
  assert_raises("TooLargeError") { a.add(F::OP_CONTINUATION, false, "de") }
end

test "close payloads" do
  p = F.close_payload(1001, "bye")
  assert_equal "\x03\xe9bye".b, p
  assert_equal 1001, F.close_code(p)
  assert_equal "bye", F.close_reason(p)
  assert_equal 1005, F.close_code("")
  assert_equal "", F.close_reason("")
  assert_raises("ProtocolError") { F.close_code("\x03".b) }
  assert_equal "ab", F.close_reason(F.close_payload(1000, "a\x00\nb\x7f"))
  long = F.close_payload(1000, "x" * 200)
  assert_equal 123, F.close_reason(long).bytesize
end

test "error classes nest under WebSocket::Error" do
  W = Cybertrain::WebSocket
  [W::TimeoutError, W::RefusedError, W::TLSError, W::BlockedAddressError,
   W::HandshakeError, W::ProtocolError, W::TooLargeError, W::ClosedError].each do |k|
    assert k.ancestors.include?(W::Error)
  end
  e = W::ClosedError.new("gone", 1001, "bye")
  assert_equal 1001, e.close_code
  assert_equal "bye", e.close_reason
  assert_equal "gone", e.message
end

test "Message holds opcode and data" do
  m = Cybertrain::WebSocket::Message.new(:binary, "ab")
  assert_equal :binary, m.ws_opcode
  assert_equal "ab", m.ws_data
end

Cybertrain::Test.run!
