require "cybertrain/test"
require "cybertrain/password"

# Cybertrain::Password is plain Ruby over Digest::SHA256 (no FFI), so this
# program runs under CRuby and `spin test --regen` makes its snapshot.
# The digests below are checked against the RFC 6070 / RFC 7914 PBKDF2
# vectors, which pin the HMAC keying, the block index and the XOR fold.

def hex(bytes)
  Cybertrain::Crypto.hex(bytes)
end

# First, before any test sets Password.iterations: the default follows
# Cybertrain.config's environment until something sets a count.
test "iterations defaults to TEST_ITERATIONS under test? and test digests verify anywhere" do
  config = Cybertrain.config
  config.env = "development"
  assert_equal 100_000, Cybertrain::Password.iterations
  config.env = "test"
  assert_equal 1000, Cybertrain::Password.iterations
  assert_equal 1000, Cybertrain::Password::TEST_ITERATIONS
  quick = Cybertrain::Password.hash("s3cr3t-s3cr3t")
  assert quick.start_with?("$pbkdf2-sha256$i=1000$"), quick
  assert Cybertrain::Password.verify?("s3cr3t-s3cr3t", quick)
  refute Cybertrain::Password.needs_rehash?(quick)
  # The digest records its count: production verifies it, and asks for a rehash.
  config.env = "production"
  assert Cybertrain::Password.verify?("s3cr3t-s3cr3t", quick)
  assert Cybertrain::Password.needs_rehash?(quick)
  # A count set explicitly wins over the environment.
  Cybertrain::Password.iterations = 2000
  assert_equal 2000, Cybertrain::Password.iterations
  config.env = "test"
  assert_equal 2000, Cybertrain::Password.iterations
  Cybertrain::Password.iterations = 1000
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

# Counts the answers verifier threads get. Typed instance methods (NOTES
# rule 35) rather than a shared Array the threads append to.
class VerifyTally
  def initialize
    @tally_true = 0
    @tally_false = 0
  end

  def add(flag)
    if flag
      @tally_true = @tally_true + 1
    else
      @tally_false = @tally_false + 1
    end
    nil
  end

  def tally_true
    @tally_true
  end

  def tally_false
    @tally_false
  end
end

# Four threads, each verifying twice (the right password, then a wrong
# one); a method of its own, not a loop nested in a test block (rule 68).
def run_verifiers(digest, tally)
  workers = []
  4.times do
    workers << Thread.new do
      tally.add(Cybertrain::Password.verify_serialized("s3cr3t", digest))
      tally.add(Cybertrain::Password.verify_serialized("wrong", digest))
    end
  end
  workers.each(&:join)
  nil
end

def verify_in_thread(digest, tally)
  Thread.new { tally.add(Cybertrain::Password.verify_serialized("s3cr3t", digest)) }
end

test "verify_serialized answers like verify?" do
  Cybertrain::Password.iterations = 1000
  digest = Cybertrain::Password.hash("s3cr3t")
  assert Cybertrain::Password.verify_serialized("s3cr3t", digest)
  refute Cybertrain::Password.verify_serialized("wrong", digest)
  refute Cybertrain::Password.verify_serialized("", digest)
  refute Cybertrain::Password.verify_serialized("s3cr3t", nil)
  refute Cybertrain::Password.verify_serialized("s3cr3t", "not a digest")
end

test "verify_serialized runs one verification at a time across threads" do
  Cybertrain::Password.iterations = 1000
  digest = Cybertrain::Password.hash("s3cr3t")
  tally = VerifyTally.new
  run_verifiers(digest, tally)
  assert_equal 4, tally.tally_true
  assert_equal 4, tally.tally_false
  assert_equal 1, Cybertrain::Password.serialized_peak

  # While another holder has the lock, a verification waits for it.
  waiting = VerifyTally.new
  lock = Cybertrain::Password.serial_lock
  lock.lock
  blocked = verify_in_thread(digest, waiting)
  sleep 0.2
  assert_equal 0, waiting.tally_true + waiting.tally_false
  lock.unlock
  blocked.join
  assert_equal 1, waiting.tally_true
end

test "dummy_digest is made once per process, at the current cost, and matches nothing" do
  Cybertrain::Password.iterations = 1000
  dummy = Cybertrain::Password.dummy_digest
  assert dummy.start_with?("$pbkdf2-sha256$i=1000$"), dummy
  assert dummy.equal?(Cybertrain::Password.dummy_digest)
  assert_equal dummy, Cybertrain::Password.dummy_digest
  refute Cybertrain::Password.verify_serialized("s3cr3t", dummy)
  refute Cybertrain::Password.verify?("", dummy)
  # A changed cost makes a new one, so it keeps costing what a real digest does.
  Cybertrain::Password.iterations = 2000
  costlier = Cybertrain::Password.dummy_digest
  assert costlier.start_with?("$pbkdf2-sha256$i=2000$"), costlier
  assert_equal costlier, Cybertrain::Password.dummy_digest
  Cybertrain::Password.iterations = 1000
end

test "session_key is an HMAC of the digest under secret_key_base" do
  Cybertrain::Password.iterations = 1000
  secret = "k" * 64
  Cybertrain.config.secret_key_base = secret
  digest = Cybertrain::Password.hash("s3cr3t")
  key = Cybertrain::Password.session_key(digest)
  assert_equal 64, key.size
  assert_equal Cybertrain::Crypto.hmac_hex(secret, "cybertrain.password.session_key\n" + digest), key
  assert_equal key, Cybertrain::Password.session_key(digest)
  assert_equal key, Cybertrain::Password.session_key_with(digest, secret)
  refute key == Cybertrain::Password.session_key_with(digest, "another secret")
  # A new password (or a rehash: a new salt) is a new digest, so a new key.
  changed = Cybertrain::Password.hash("s3cr3t")
  refute key == Cybertrain::Password.session_key(changed)
  assert Cybertrain::Password.session_key_matches?(key, digest)
  refute Cybertrain::Password.session_key_matches?(key, changed)
  refute Cybertrain::Password.session_key_matches?("", digest)
  refute Cybertrain::Password.session_key_matches?(nil, digest)
  refute Cybertrain::Password.session_key_matches?(key[0, 63].to_s, digest)
end

Cybertrain::Test.run!
