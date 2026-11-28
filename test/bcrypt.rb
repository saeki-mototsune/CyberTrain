require "cybertrain/test"
require "cybertrain/password"

# Cybertrain::Bcrypt verifies the bcrypt digests Rails' has_secure_password
# writes (docs/design.md D97). Plain Ruby, so this program runs under CRuby
# too. The vectors are OpenBSD's (Provos's, also bcrypt-ruby's spec) and
# crypt_blowfish's (Solar Designer's wrapper.c, the C the bcrypt gem
# bundles); the others were made with crypt(3) of libxcrypt, the same
# algorithm, under CRuby. Costs stay at 8 or below so that the CRuby run
# (script/preview-parity) stays short; spikes/bcrypt/ times cost 12.

def bcrypt_ok(password, digest)
  Cybertrain::Bcrypt.verify?(password, digest)
end

test "OpenBSD's vectors verify, and a changed password does not" do
  vectors = [
    ["", "$2a$06$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s."],
    ["a", "$2a$06$m0CrhHm10qJ3lXRY.5zDGO3rS2KdeeWLuGmsfGlMfOxih58VYVfxe"],
    ["abc", "$2a$06$If6bvum7DFjUnE9p2uDeDu0YHzrHM6tf.iqN8.yx.jNN1ILEf7h0i"],
    ["abcdefghijklmnopqrstuvwxyz", "$2a$06$.rCVZVOThsIa97pEDOxvGuRRgzG64bvtJ0938xuqzv18d3ZpQhstC"],
    ["~!@\#$%^&*()      ~!@\#$%^&*()PNBFRD", "$2a$06$fPIsBO8qRqkjj273rfaOI.HtSV9jLDpTbZn782DC6/t7qT67P6FfO"]
  ]
  vectors.each do |pair|
    assert Cybertrain::Bcrypt.digest?(pair[1])
    assert_equal pair[1], Cybertrain::Bcrypt.hash_with(pair[0], pair[1])
    assert bcrypt_ok(pair[0], pair[1])
    refute bcrypt_ok(pair[0] + "!", pair[1])
  end
end

test "crypt_blowfish's vectors verify, with each prefix read as the bcrypt gem reads it" do
  assert bcrypt_ok("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW")
  assert bcrypt_ok("U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK")
  assert bcrypt_ok("U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a")
  assert bcrypt_ok("", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy")
  # High-bit bytes: $2a$, $2b$ and $2y$ are the corrected algorithm ...
  assert bcrypt_ok("\xa3".b, "$2y$05$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq")
  assert bcrypt_ok("\xa3".b, "$2a$05$/OK.fbVrR/bpIqNJ5ianF.Sa7shbm4.OzKpvFnX1pQLmQW96oUlCq")
  assert bcrypt_ok("\xa3".b + "ab", "$2a$05$/OK.fbVrR/bpIqNJ5ianF.6IflQkJytoRVc1yuaNtHfiuq.FRlSIS")
  assert bcrypt_ok("\xff\xa3".b + "34" + "\xff\xff\xff\xa3".b + "345", "$2a$05$/OK.fbVrR/bpIqNJ5ianF.ZC1JEJ8Z4gPfpe1JOr/oyPXTWl9EFd.")
  assert bcrypt_ok("\xff\xff\xa3".b, "$2y$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e")
  assert bcrypt_ok("\xff\xff\xa3".b, "$2b$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e")
  # ... and $2a$ deviates from it for "\xff\xff\xa3" (crypt_blowfish's
  # countermeasure against the sign-extension bug's collisions).
  assert bcrypt_ok("\xff\xff\xa3".b, "$2a$05$/OK.fbVrR/bpIqNJ5ianF.nqd1wy.pTMdcvrRWxyiGL2eMz.2a85.")
  refute bcrypt_ok("\xff\xff\xa3".b, "$2a$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e")
  # $2x$ (the bug itself) is not verified.
  refute Cybertrain::Bcrypt.digest?("$2x$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e")
  refute bcrypt_ok("\xa3".b, "$2x$05$/OK.fbVrR/bpIqNJ5ianF.CE5elHaaO4EbggVDjb8P19RukzXSM3e")
end

test "the password counts to 72 bytes and to its first NUL" do
  long = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  digest = "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"
  assert_equal 72, long.bytesize
  assert bcrypt_ok(long + "chars after 72 are ignored", digest)
  assert bcrypt_ok(long, digest)
  refute bcrypt_ok(long[0, 71].to_s, digest)
  a72 = "$2b$04$abcdefghijklmnopqrstuuBzzIgyKkz7xMWYSzkIjUSnxEQFQ0WNe"
  assert bcrypt_ok("a" * 72, a72)
  assert bcrypt_ok("a" * 100, a72)
  refute bcrypt_ok("a" * 71, a72)
  abc = "$2b$04$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2"
  assert bcrypt_ok("abc", abc)
  assert bcrypt_ok("abc\0def", abc)
end

test "digests of the shapes Rails, PHP and UTF-8 passwords give" do
  # has_secure_password: $2a$, cost BCrypt::Engine.cost (12 outside tests).
  assert bcrypt_ok("secret", "$2a$08$Kyi1xXCuZC5E6m6RsEGb7Omj70iPq0EkaVRzPKPul1wTDMk4OV80a")
  refute bcrypt_ok("Secret", "$2a$08$Kyi1xXCuZC5E6m6RsEGb7Omj70iPq0EkaVRzPKPul1wTDMk4OV80a")
  # PHP's password_hash writes $2y$.
  assert bcrypt_ok("password", "$2y$04$abcdefghijklmnopqrstuughE8Ev8uGFaUgY2cNEySvxngrb/Jzdm")
  assert bcrypt_ok("pässwörd", "$2b$04$0123456789abcdefghijkeSfXnfwqUQcojiH1lRcFaNQJz.p3Ovba")
  refute bcrypt_ok("passwörd", "$2b$04$0123456789abcdefghijkeSfXnfwqUQcojiH1lRcFaNQJz.p3Ovba")
end

test "anything not a bcrypt digest is false, never an exception" do
  good = "$2b$04$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2"
  assert Cybertrain::Bcrypt.digest?(good)
  [
    nil, "", "abc", "$2b$04$", good[0, 59].to_s, good + "x",
    "$2c$04$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2",
    "$3b$04$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2",
    "$2b$03$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2",
    "$2b$32$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2",
    "$2b$4a$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2",
    "$2b$04$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q*",
    "$2b$04$abcdefghijklmn=pqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2",
    "$2b$04abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2x"
  ].each do |bad|
    refute Cybertrain::Bcrypt.digest?(bad)
    refute bcrypt_ok("abc", bad)
  end
  # The costs at both ends are accepted (31 is not run: 2**31 rounds).
  assert Cybertrain::Bcrypt.digest?("$2b$31$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2")
  # A salt whose last character carries bits bcrypt ignores is not the
  # digest crypt(3) writes back, so it does not verify (the bcrypt gem's
  # comparison of the whole string says the same).
  refute bcrypt_ok("abc", "$2b$04$abcdefghijklmnopqrstuvCi15uRb1eH7NAlJ/TgeJertyknQpYn2")
  assert bcrypt_ok("abc", "$2b$04$abcdefghijklmnopqrstuuCi15uRb1eH7NAlJ/TgeJertyknQpYn2")
end

test "Password.verify? reads a bcrypt digest, and needs_rehash? asks to replace it" do
  rails = "$2a$08$Kyi1xXCuZC5E6m6RsEGb7Omj70iPq0EkaVRzPKPul1wTDMk4OV80a"
  assert Cybertrain::Password.verify?("secret", rails)
  assert Cybertrain::Password.verify_serialized("secret", rails)
  refute Cybertrain::Password.verify?("wrong", rails)
  # An empty password is false for every digest, as for PBKDF2 ones.
  refute Cybertrain::Password.verify?("", "$2a$06$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s.")
  assert Cybertrain::Password.rehash_bcrypt
  assert Cybertrain::Password.needs_rehash?(rails)
  Cybertrain::Password.rehash_bcrypt = false
  refute Cybertrain::Password.needs_rehash?(rails)
  # The switch is about bcrypt alone: a digest nothing reads ($2x$) and a
  # PBKDF2 one are judged as before.
  assert Cybertrain::Password.needs_rehash?("$2x$08$Kyi1xXCuZC5E6m6RsEGb7Omj70iPq0EkaVRzPKPul1wTDMk4OV80a")
  refute Cybertrain::Password.needs_rehash?(Cybertrain::Password.hash("secret"))
  Cybertrain::Password.rehash_bcrypt = true
  assert Cybertrain::Password.needs_rehash?(rails)
  # The replacement is PBKDF2 and verifies.
  fresh = Cybertrain::Password.hash("secret")
  assert fresh.start_with?("$pbkdf2-sha256$")
  assert Cybertrain::Password.verify?("secret", fresh)
end

test "verifications run side by side without sharing state" do
  rails = "$2b$04$abcdefghijklmnopqrstu.bW2K.9.6LIihvvOS5ITIU4yUe54M.q2"
  threads = []
  threads << Thread.new do
    bad = 0
    n = 0
    while n < 20
      bad += 1 unless Cybertrain::Bcrypt.verify?("abc", rails)
      n += 1
    end
    bad
  end
  threads << Thread.new do
    bad = 0
    n = 0
    while n < 20
      bad += 1 if Cybertrain::Bcrypt.verify?("abd", rails)
      n += 1
    end
    bad
  end
  assert_equal 0, threads[0].value
  assert_equal 0, threads[1].value
end

Cybertrain::Test.run!
