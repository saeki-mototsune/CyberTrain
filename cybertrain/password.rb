# Cybertrain::Password -- password hashing for `cybertrain generate
# authentication` (and for any model with a `password_digest` column).
#
# PBKDF2-HMAC-SHA256, in Ruby over the runtime's vendored SHA-256, like
# Crypto's HMAC: bcrypt and argon2 would need a C library the binary links
# (`String#crypt` is libc crypt(3), whose bcrypt is glibc/libxcrypt only; macOS
# has none), and Spinel's `openssl` package needs libssl on the link path,
# which cybertrain avoids (docs/design.md D8). PBKDF2 is what NIST SP 800-132
# and Django's default hasher use; the loop is plain Ruby, so it compiles
# wherever the framework does.
#
# A digest is a PHC-style string naming its parameters, so the cost can be
# raised later (or the algorithm replaced) and old digests still verify:
#
#   $pbkdf2-sha256$i=100000$<salt, urlsafe base64>$<32 bytes, urlsafe base64>
#
# `needs_rehash?` tells a login flow to rehash with the current parameters
# after a successful verify, as Django does.
require "digest"
require "securerandom"
require "base64"
require "cybertrain/crypto"

module Cybertrain
  # Hashes and verifies passwords (PBKDF2-HMAC-SHA256, salted, 100,000
  # iterations by default) for a model's `password_digest` column.
  # `cybertrain generate authentication` writes the User model that calls
  # it; use it directly for any other credential.
  #
  # A digest is a String of 130 or so characters (`$pbkdf2-sha256$i=...$...$...`)
  # that records its own salt and iteration count, so {verify?} works on
  # digests made with other settings and {needs_rehash?} says when one is
  # behind the current ones. One hash costs about 0.2 s compiled (100,000
  # iterations) on a 2026 cloud core; raise {ITERATIONS} with
  # `Cybertrain::Password.iterations = ...` in `config/app.rb` when the
  # server has the budget (600,000 is OWASP's 2023 figure, about a second).
  # The loop is interruptible Ruby (a safepoint per iteration), so other
  # requests keep being served while a login hashes.
  # @example
  #   digest = Cybertrain::Password.hash("correct horse battery staple")
  #   Cybertrain::Password.verify?("correct horse battery staple", digest)   # => true
  #   Cybertrain::Password.verify?("wrong", digest)                          # => false
  # @api public
  module Password
    # The algorithm identifier a digest starts with.
    ALGORITHM = "pbkdf2-sha256"
    # The default iteration count {hash} uses, and the one {needs_rehash?}
    # compares against.
    # @api public
    ITERATIONS = 100_000
    # Salt bytes (16, as NIST SP 800-132 recommends at least).
    SALT_BYTES = 16
    # The derived key is one HMAC-SHA256 block.
    KEY_BYTES = 32
    # An empty password is refused by {hash}; a digest is never longer than
    # this, so a `password_digest` column (TEXT) holds it.
    MAX_PASSWORD_BYTES = 1024

    @iterations = ITERATIONS

    # The iteration count new digests get (and the one {needs_rehash?}
    # checks); {ITERATIONS} unless `config/app.rb` set another.
    # @return [Integer]
    # @api public
    def self.iterations
      @iterations
    end

    # @param n [Integer] at least 1,000
    # @return [Integer]
    # @raise [ArgumentError] when n is below 1,000
    # @api public
    def self.iterations=(n)
      raise ArgumentError, "Password.iterations must be at least 1000 (got #{n})" if n < 1000

      @iterations = n
    end

    # Hashes a password with a fresh random salt and the current
    # {iterations}.
    # @param password [String] not empty, at most 1024 bytes
    # @return [String] the digest to store
    # @raise [ArgumentError] for an empty or overlong password
    # @api public
    def self.hash(password)
      plain = password.to_s
      raise ArgumentError, "password must not be empty" if plain.empty?
      raise ArgumentError, "password is too long (#{plain.bytesize} bytes, at most #{MAX_PASSWORD_BYTES})" if plain.bytesize > MAX_PASSWORD_BYTES

      salt = SecureRandom.random_bytes(SALT_BYTES)
      n = @iterations
      key = Password.pbkdf2_sha256(plain, salt, n)
      "$#{ALGORITHM}$i=#{n}$#{Password.encode(salt)}$#{Password.encode(key)}"
    end

    # Whether the password matches the digest. A malformed digest, an
    # unknown algorithm or an empty password is false, never an exception,
    # so a login form can call it with whatever it was given. The comparison
    # is constant-time.
    # @param password [String]
    # @param digest [String, nil] what {hash} returned, from the database
    # @return [Boolean]
    # @api public
    def self.verify?(password, digest)
      plain = password.to_s
      return false if plain.empty? || plain.bytesize > MAX_PASSWORD_BYTES

      parts = Password.parse(digest)
      return false if parts.nil?

      expected = Password.decode(parts[2])
      return false if expected.bytesize != KEY_BYTES

      key = Password.pbkdf2_sha256(plain, Password.decode(parts[1]), parts[0].to_i)
      Crypto.secure_compare(key, expected)
    end

    # Whether a digest was made with fewer iterations than the current
    # {iterations} (or is not a digest this version understands), so that
    # a login flow can store a fresh {hash} of the password it just verified.
    # @param digest [String, nil]
    # @return [Boolean]
    # @api public
    def self.needs_rehash?(digest)
      parts = Password.parse(digest)
      return true if parts.nil?

      parts[0].to_i < @iterations
    end

    # ["<iterations>", "<salt b64>", "<key b64>"], or nil for anything that
    # is not a `$pbkdf2-sha256$i=N$salt$key` string with a sane N.
    # A String Array on every path (NOTES rule 10/34: one return type), nil
    # for "not a digest".
    def self.parse(digest)
      return nil if digest.nil?

      text = digest.to_s
      fields = text.split("$")
      # "$a$i=n$s$k".split("$") is ["", "a", "i=n", "s", "k"].
      return nil unless fields.size == 5 && fields[0] == "" && fields[1] == ALGORITHM

      count = fields[2]
      return nil unless count.start_with?("i=")

      digits = count[2, count.size - 2].to_s
      return nil if digits.empty? || digits.size > 9 || !Password.digits?(digits)
      return nil if digits.to_i < 1
      return nil if fields[3].empty? || fields[4].empty?
      return nil unless Password.base64?(fields[3]) && Password.base64?(fields[4])

      [digits, fields[3], fields[4]]
    end

    def self.digits?(text)
      i = 0
      while i < text.bytesize
        b = text.getbyte(i)
        return false if b < 48 || b > 57

        i += 1
      end
      true
    end

    # The urlsafe alphabet without padding: what encode writes.
    def self.base64?(text)
      i = 0
      while i < text.bytesize
        b = text.getbyte(i)
        ok = (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 95
        return false unless ok

        i += 1
      end
      true
    end

    def self.encode(bytes)
      Base64.urlsafe_encode64(bytes, padding: false)
    end

    # Decoding pads the text back up: Base64.urlsafe_decode64 accepts
    # unpadded input under CRuby but is not relied on to under Spinel. Text
    # that is not base64 at all (a length no padding fixes) decodes to "",
    # which verify? then rejects by length; a login form must never raise
    # on what the database holds.
    def self.decode(text)
      padded = text.dup
      padded << "=" while padded.size % 4 != 0
      begin
        Base64.urlsafe_decode64(padded)
      rescue ArgumentError
        ""
      end
    end

    # RFC 8018 PBKDF2 with HMAC-SHA256 for one 32-byte block (dkLen = hLen,
    # so T_1 is the whole key). The HMAC pads are keyed once; every
    # iteration is two SHA-256 calls over `pad + data`, the runtime offering
    # no incremental digest. Written with `while` loops: each back-edge is a
    # safepoint, so the scheduler can preempt a hash in progress.
    def self.pbkdf2_sha256(password, salt, iterations)
      key = password.bytesize > Crypto::BLOCK_SIZE ? Digest::SHA256.digest(password) : password
      ipad = ("6" * Crypto::BLOCK_SIZE).b
      opad = ("\\" * Crypto::BLOCK_SIZE).b
      n = key.bytesize
      i = 0
      while i < n
        b = key.getbyte(i)
        ipad.setbyte(i, b ^ 0x36)
        opad.setbyte(i, b ^ 0x5c)
        i += 1
      end
      # U_1 = PRF(password, salt || INT_32_BE(1))
      u = Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + salt.b + "\x00\x00\x00\x01".b))
      out = u.dup
      c = 1
      while c < iterations
        u = Digest::SHA256.digest(opad + Digest::SHA256.digest(ipad + u))
        j = 0
        while j < KEY_BYTES
          out.setbyte(j, out.getbyte(j) ^ u.getbyte(j))
          j += 1
        end
        c += 1
      end
      out
    end
  end
end
