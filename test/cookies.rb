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

test "parse of a malformed percent-escape does not raise (Spinel diverges from CRuby, which raises ArgumentError)" do
  cookies = Cybertrain::Cookies.parse("e=%zz")
  assert_equal({ "e" => "\u0000" }, cookies)
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
