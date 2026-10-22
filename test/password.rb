require "cybertrain/test"
require "cybertrain/password"

# Cybertrain::Password is plain Ruby over Digest::SHA256 (no FFI), so this
# program runs under CRuby and `spin test --regen` makes its snapshot.
# The digests below are checked against the RFC 6070 / RFC 7914 PBKDF2
# vectors, which pin the HMAC keying, the block index and the XOR fold.

def hex(bytes)
  Cybertrain::Crypto.hex(bytes)
end

test "pbkdf2_sha256 matches the published test vectors" do
  assert_equal "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
               hex(Cybertrain::Password.pbkdf2_sha256("password", "salt", 1))
  assert_equal "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43",
               hex(Cybertrain::Password.pbkdf2_sha256("password", "salt", 2))
  assert_equal "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
               hex(Cybertrain::Password.pbkdf2_sha256("password", "salt", 4096))
  # dkLen 40 in the RFC; the first 32 bytes are T_1.
  assert_equal "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1",
               hex(Cybertrain::Password.pbkdf2_sha256("passwordPASSWORDpassword", "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096))
  # A password longer than the HMAC block is hashed down first (RFC 2104).
  long = "p" * 100
  short_key = Cybertrain::Password.pbkdf2_sha256(long, "salt", 3)
  assert_equal 32, short_key.bytesize
  refute short_key == Cybertrain::Password.pbkdf2_sha256("p" * 99, "salt", 3)
end

test "hash writes a PHC string with the current iteration count and a fresh salt" do
  Cybertrain::Password.iterations = 1000
  digest = Cybertrain::Password.hash("correct horse battery staple")
  assert digest.start_with?("$pbkdf2-sha256$i=1000$"), digest
  assert_equal 5, digest.split("$").size
  assert_equal 22, digest.split("$")[3].size   # 16 salt bytes, unpadded base64
  assert_equal 43, digest.split("$")[4].size   # 32 key bytes
  again = Cybertrain::Password.hash("correct horse battery staple")
  refute digest == again, "two hashes of one password must differ (random salt)"
  assert Cybertrain::Password.verify?("correct horse battery staple", digest)
  assert Cybertrain::Password.verify?("correct horse battery staple", again)
end

test "verify? rejects the wrong password, a blank one and a damaged digest" do
  Cybertrain::Password.iterations = 1000
  digest = Cybertrain::Password.hash("s3cr3t")
  refute Cybertrain::Password.verify?("s3cr3t ", digest)
  refute Cybertrain::Password.verify?("S3cr3t", digest)
  refute Cybertrain::Password.verify?("", digest)
  refute Cybertrain::Password.verify?("s3cr3t", nil)
  refute Cybertrain::Password.verify?("s3cr3t", "")
  refute Cybertrain::Password.verify?("s3cr3t", "plain text in the column")
  refute Cybertrain::Password.verify?("s3cr3t", digest + "x")
  refute Cybertrain::Password.verify?("s3cr3t", digest[0, digest.size - 1].to_s)
  # Another algorithm name, a missing count, a non-numeric count.
  refute Cybertrain::Password.verify?("s3cr3t", digest.sub("pbkdf2-sha256", "bcrypt"))
  refute Cybertrain::Password.verify?("s3cr3t", digest.sub("i=1000", "i="))
  refute Cybertrain::Password.verify?("s3cr3t", digest.sub("i=1000", "i=10x0"))
  refute Cybertrain::Password.verify?("s3cr3t", digest.sub("i=1000", "1000"))
  # A salt or key with characters outside the urlsafe alphabet.
  refute Cybertrain::Password.verify?("s3cr3t", digest.sub("$i=1000$", "$i=1000$+/"))
  # Unicode passwords are compared byte for byte.
  utf8 = Cybertrain::Password.hash("パスワード")
  assert Cybertrain::Password.verify?("パスワード", utf8)
  refute Cybertrain::Password.verify?("パスワート", utf8)
end

test "a digest made with fewer iterations still verifies and asks for a rehash" do
  Cybertrain::Password.iterations = 1000
  old = Cybertrain::Password.hash("s3cr3t")
  Cybertrain::Password.iterations = 2000
  assert Cybertrain::Password.verify?("s3cr3t", old)
  assert Cybertrain::Password.needs_rehash?(old)
  fresh = Cybertrain::Password.hash("s3cr3t")
  refute Cybertrain::Password.needs_rehash?(fresh)
  assert fresh.start_with?("$pbkdf2-sha256$i=2000$")
  # More iterations than current is not behind.
  Cybertrain::Password.iterations = 1000
  refute Cybertrain::Password.needs_rehash?(fresh)
  # Not a digest at all: rehash.
  assert Cybertrain::Password.needs_rehash?(nil)
  assert Cybertrain::Password.needs_rehash?("")
  assert Cybertrain::Password.needs_rehash?("md5$abc")
end

test "hash refuses an empty or overlong password, and iterations= a tiny count" do
  Cybertrain::Password.iterations = 1000
  assert_equal "password must not be empty", assert_raises("ArgumentError") { Cybertrain::Password.hash("") }
  message = assert_raises("ArgumentError") { Cybertrain::Password.hash("x" * 1025) }
  assert_includes message, "too long"
  assert Cybertrain::Password.hash("x" * 1024).start_with?("$pbkdf2-sha256$i=1000$")
  message = assert_raises("ArgumentError") { Cybertrain::Password.iterations = 999 }
  assert_includes message, "at least 1000"
  assert_equal 1000, Cybertrain::Password.iterations
  # The default the framework ships with.
  assert_equal 100_000, Cybertrain::Password::ITERATIONS
end

test "parse reads the fields back and refuses the rest" do
  parts = Cybertrain::Password.parse("$pbkdf2-sha256$i=12345$c2FsdA$a2V5")
  assert_equal ["12345", "c2FsdA", "a2V5"], parts
  assert_nil Cybertrain::Password.parse("$pbkdf2-sha256$i=12345$c2FsdA")
  assert_nil Cybertrain::Password.parse("$pbkdf2-sha256$i=12345$c2FsdA$a2V5$extra")
  assert_nil Cybertrain::Password.parse("pbkdf2-sha256$i=12345$c2FsdA$a2V5")
  assert_nil Cybertrain::Password.parse("$pbkdf2-sha256$i=0$c2FsdA$a2V5")
  assert_nil Cybertrain::Password.parse("$pbkdf2-sha256$i=1234567890$c2FsdA$a2V5")
  assert_nil Cybertrain::Password.parse("$pbkdf2-sha256$i=12345$$a2V5")
  assert_equal "salt", Cybertrain::Password.decode("c2FsdA")
  assert_equal "c2FsdA", Cybertrain::Password.encode("salt")
end

Cybertrain::Test.run!
