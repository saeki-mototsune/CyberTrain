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

# RFC 4231 test cases 2 and 6 (a 131-byte key), a 64-byte key (exactly the
# block size, used as is), the empty key and message, and UTF-8 data;
# expected values from OpenSSL::HMAC.hexdigest("SHA256", key, data).
test "hmac_hex matches HMAC-SHA256 reference values" do
  assert_equal "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
               Cybertrain::Crypto.hmac_hex("Jefe", "what do ya want for nothing?")
  long_key = Array.new(131) { 0xaa }.pack("C*")
  assert_equal "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
               Cybertrain::Crypto.hmac_hex(long_key, "Test Using Larger Than Block-Size Key - Hash Key First")
  assert_equal "4254a0b7109cb1fdbe66d1071c255a645ca4c9de3a914133e8b9109978c10dee",
               Cybertrain::Crypto.hmac_hex("k" * 64, "h\u00e9llo")
  assert_equal "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
               Cybertrain::Crypto.hmac_hex("", "")
end

test "hex spells raw bytes in lowercase hex" do
  assert_equal "", Cybertrain::Crypto.hex("")
  assert_equal "00010aff7f80", Cybertrain::Crypto.hex([0, 1, 10, 255, 127, 128].pack("C*"))
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
