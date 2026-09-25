require "cybertrain/test"
require "cybertrain/crypto"

test "hmac_hex is deterministic and 64 hex chars" do
  a = Cybertrain::Crypto.hmac_hex("secret", "hello world")
  b = Cybertrain::Crypto.hmac_hex("secret", "hello world")
  assert_equal a, b
  assert_equal 64, a.length
  a.each_char { |c| assert("0123456789abcdef".include?(c)) }
end

test "hmac_hex differs for a different key or a different message" do
  base = Cybertrain::Crypto.hmac_hex("secret", "hello world")
  other_key = Cybertrain::Crypto.hmac_hex("other-secret", "hello world")
  other_msg = Cybertrain::Crypto.hmac_hex("secret", "goodbye world")
  refute base == other_key
  refute base == other_msg
end

# A key longer than the 64-byte block size is hashed down to raw (binary)
# bytes first; mixing that BINARY key material with UTF-8 message data must
# not raise Encoding::CompatibilityError.
test "hmac_hex handles a long key and non-ASCII UTF-8 data without raising" do
  long_key = "k" * 100
  digest = Cybertrain::Crypto.hmac_hex(long_key, "héllo")
  assert_equal 64, digest.length
  assert_equal digest, Cybertrain::Crypto.hmac_hex(long_key, "héllo")
end

test "secure_compare is true only for equal strings of equal length" do
  assert Cybertrain::Crypto.secure_compare("abc", "abc")
  refute Cybertrain::Crypto.secure_compare("abc", "abd")
  refute Cybertrain::Crypto.secure_compare("abc", "ab")
end

test "random_token returns distinct hex strings of the requested byte length" do
  t1 = Cybertrain::Crypto.random_token
  t2 = Cybertrain::Crypto.random_token
  refute t1 == t2
  assert_equal 64, t1.length

  short = Cybertrain::Crypto.random_token(8)
  assert_equal 16, short.length
end

Cybertrain::Test.run!
