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

Cybertrain::Test.run!
