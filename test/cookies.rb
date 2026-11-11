require "cybertrain/http/cookies"
require "cybertrain/test"

test "parse splits 'a=1; b=2' into a Hash, percent-decoding values" do
  cookies = Cybertrain::Cookies.parse("a=1; b=hello%20world")
  assert_equal({ "a" => "1", "b" => "hello world" }, cookies)
end

test "parse of an empty header yields an empty Hash" do
  assert_equal({}, Cybertrain::Cookies.parse(""))
end

test "parse keeps the first of a duplicate cookie name (most specific Path wins)" do
  cookies = Cybertrain::Cookies.parse("a=1; a=2")
  assert_equal({ "a" => "1" }, cookies)
end

test "parse keeps the raw value of a malformed percent-escape on every runtime" do
  cookies = Cybertrain::Cookies.parse("e=%zz; f=50%off; g=%; h=%41")
  assert_equal({ "e" => "%zz", "f" => "50%off", "g" => "%", "h" => "A" }, cookies)
end

test "decode keeps the raw value of an invalid byte sequence (raw or percent-encoded), as a foreign cookie must not fail the request" do
  # decode, not parse: under CRuby String#split/strip refuse an invalid UTF-8
  # String themselves (a socket header is binary there, so parse never sees one).
  assert_equal 3, Cybertrain::Cookies.decode("x\x81y").bytesize
  assert_equal 4, Cybertrain::Cookies.decode("%41\x81").bytesize
  assert_equal "%81", Cybertrain::Cookies.decode("%81")
  assert_equal "%C3", Cybertrain::Cookies.decode("%C3")
  # half a character raw plus its other half escaped: also kept raw
  assert_equal 4, Cybertrain::Cookies.decode("\xC3%A9").bytesize
  cookies = Cybertrain::Cookies.parse("c=%81; d=ok; e=%C3%A9")
  assert_equal({ "c" => "%81", "d" => "ok", "e" => "\u00e9" }, cookies)
end

test "serialize with defaults" do
  value = Cybertrain::Cookies.serialize("session_id", "abc123")
  assert_equal "session_id=abc123; Path=/; HttpOnly; SameSite=Lax", value
end

test "serialize with all options set" do
  value = Cybertrain::Cookies.serialize(
    "session_id", "abc 123",
    path: "/admin", max_age: 3600, http_only: false,
    same_site: "Strict", secure: true
  )
  assert_equal(
    "session_id=abc+123; Path=/admin; SameSite=Strict; Max-Age=3600; Secure",
    value
  )
end

test "serialize omits Max-Age when negative and HttpOnly/Secure when off" do
  value = Cybertrain::Cookies.serialize("a", "1", max_age: -1, http_only: false, secure: false)
  assert_equal "a=1; Path=/; SameSite=Lax", value
end

test "serialize with same_site None adds Secure even when secure is false" do
  value = Cybertrain::Cookies.serialize("s", "v", same_site: "None")
  assert_equal "s=v; Path=/; HttpOnly; SameSite=None; Secure", value
end

test "serialize with partitioned appends Partitioned and implies Secure" do
  lax = Cybertrain::Cookies.serialize("s", "v", partitioned: true)
  assert_equal "s=v; Path=/; HttpOnly; SameSite=Lax; Secure; Partitioned", lax
  none = Cybertrain::Cookies.serialize("s", "v", max_age: 60, same_site: "None", partitioned: true)
  assert_equal "s=v; Path=/; HttpOnly; SameSite=None; Max-Age=60; Secure; Partitioned", none
end

# Production (secure: true) inside another site's frame: one Secure, not two.
test "serialize writes Secure once when secure, same_site None and partitioned are all set" do
  value = Cybertrain::Cookies.serialize("s", "v", max_age: 60, same_site: "None", secure: true, partitioned: true)
  assert_equal "s=v; Path=/; HttpOnly; SameSite=None; Max-Age=60; Secure; Partitioned", value
end

# Query.plain? lets serialize skip the encoder, so a value must come out the
# same down either path. Compared whole, not by prefix: a prefix match would
# let a plain path drop the end of a value.
def assert_serialized_as_encoded(value)
  encoded = URI.encode_www_form_component(value)
  assert_equal "k=#{encoded}; Path=/; HttpOnly; SameSite=Lax", Cybertrain::Cookies.serialize("k", value)
end

test "serialize encodes exactly as encode_www_form_component, plain or not" do
  byte = 0
  while byte < 128
    assert_serialized_as_encoded(byte.chr)
    byte += 1
  end
  assert_serialized_as_encoded("a b")
  assert_serialized_as_encoded("a+b")
  assert_serialized_as_encoded("50%")
  assert_serialized_as_encoded("a;b")
  assert_serialized_as_encoded("a=b")
  assert_serialized_as_encoded("\u65E5\u672C\u8A9E")
  assert_serialized_as_encoded("")
  assert_serialized_as_encoded("abc--DEF_-.")
end

test "plain? is true exactly for the ASCII bytes the encoder leaves alone" do
  byte = 0
  while byte < 128
    char = byte.chr
    assert_equal URI.encode_www_form_component(char) == char, Cybertrain::Query.plain?(char)
    byte += 1
  end
  assert Cybertrain::Query.plain?("")
  assert Cybertrain::Query.plain?("abc--DEF_-.")
  assert !Cybertrain::Query.plain?("a=")
  assert !Cybertrain::Query.plain?("\u00e9")
end

test "serialize rejects a cookie name that is not an RFC 6265 token" do
  ["x; Domain=evil.example", "x=y", "a b", "a\tb", "", "a,b", "a\"b", "a(b)", "a/b", "a[b]", "a{b}", "caf\u00e9", "a\r\nb"].each do |bad|
    message = assert_raises("ArgumentError") { Cybertrain::Cookies.serialize(bad, "v") }
    assert message.start_with?("cookie name")
  end
  assert_equal "a.b-c_d!#$%&'*+^`|~1=v; Path=/; HttpOnly; SameSite=Lax", Cybertrain::Cookies.serialize("a.b-c_d!#$%&'*+^`|~1", "v")
end

test "serialize rejects ';' and CR/LF in path and same_site, and an unknown same_site" do
  assert_raises("ArgumentError") { Cybertrain::Cookies.serialize("a", "v", path: "/; Domain=evil.example") }
  assert_raises("ArgumentError") { Cybertrain::Cookies.serialize("a", "v", path: "/\r\nX: y") }
  assert_raises("ArgumentError") { Cybertrain::Cookies.serialize("a", "v", same_site: "Lax; Secure") }
  assert_raises("ArgumentError") { Cybertrain::Cookies.serialize("a", "v", same_site: "Sloppy") }
  assert_equal "a=v; Path=/; HttpOnly; SameSite=strict", Cybertrain::Cookies.serialize("a", "v", same_site: "strict")
  assert_equal "a=v; Path=/; HttpOnly; SameSite=none; Secure", Cybertrain::Cookies.serialize("a", "v", same_site: "none")
end

Cybertrain::Test.run!
