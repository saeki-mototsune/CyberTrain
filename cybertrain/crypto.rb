# Cybertrain::Crypto -- the primitives sessions, cookies and CsrfProtection
# sign, derive keys and compare with.
#
# HMAC-SHA256 is implemented here in pure Ruby over Digest::SHA256.digest,
# the runtime's own vendored SHA-256 (spikes/NOTES.md numbers table). It
# was written that way when the `openssl` package was linked only into
# programs that asked for it; `require "cybertrain"` now loads
# cybertrain/encryptor.rb, and so openssl, in every program (the encrypted
# session, spec section 5.1), but this file needs neither and stays usable
# on its own. {Crypto.derive_key} turns `secret_key_base` into one 32-byte
# key per purpose (the session, signed cookies, encrypted cookies), so no
# two uses share a key. The derivation input carries a fixed prefix
# ({Crypto::KEY_PREFIX}) so a derived key is never the same HMAC as one
# the framework computes directly under the raw secret (Password's
# session key tag, Stream's signing key), whose tag may be public. The AES-256-GCM encryption itself is
# cybertrain/encryptor.rb's.
require "digest"
require "securerandom"

module Cybertrain
  module Crypto
    BLOCK_SIZE = 64
    HEX_DIGITS = "0123456789abcdef"
    # Domain separation for derive_key: no other HMAC under the raw secret
    # starts with this.
    KEY_PREFIX = "cybertrain key\0"

    def self.hmac_hex(secret, data)
      Crypto.hex(hmac_digest(secret, data))
    end

    # Lowercase hex of raw bytes. The result is allocated once at its final
    # size and filled with setbyte (in place on a heap String): appending
    # HEX_DIGITS[i] made a one-character String per digit, 64 per HMAC.
    def self.hex(bytes)
      n = bytes.bytesize
      out = "0" * (n * 2)
      i = 0
      while i < n
        b = bytes.getbyte(i)
        out.setbyte(i * 2, HEX_DIGITS.getbyte((b >> 4) & 0xf))
        out.setbyte(i * 2 + 1, HEX_DIGITS.getbyte(b & 0xf))
        i += 1
      end
      out
    end

    # Constant-time byte comparison: every byte pair is examined regardless
    # of an early mismatch, so the running time does not leak how much of a
    # signature or token was guessed correctly. (Strings of different
    # lengths return false at once: the length is not the secret.)
    # @example
    #   Cybertrain::Crypto.secure_compare(params[:token].to_s, SetupController.setup_token)
    # @param a [String]
    # @param b [String]
    # @return [Boolean] whether the two hold the same bytes
    # @api public
    def self.secure_compare(a, b)
      return false if a.bytesize != b.bytesize

      a_bytes = a.bytes
      b_bytes = b.bytes
      diff = 0
      i = 0
      while i < a_bytes.length
        diff |= (a_bytes[i] ^ b_bytes[i])
        i += 1
      end
      diff == 0
    end

    # SecureRandom.hex, through Crypto.hex (SecureRandom.hex appends a
    # one-character String per digit).
    # @example
    #   Cybertrain::Crypto.random_token(16)   # => "3f9c..." (32 hex digits)
    # @param bytes [Integer] how many random bytes
    # @return [String] twice as many lowercase hex digits
    # @api public
    def self.random_token(bytes = 32)
      Crypto.hex(SecureRandom.random_bytes(bytes))
    end

    # A fresh key for `CYBERTRAIN_ENCRYPTION_KEY`: 32 random bytes as 64
    # lowercase hex digits (what `cybertrain secret --hex` prints). The
    # encryption itself is cybertrain/encryptor.rb's (AES-256-GCM through
    # openssl); making a key needs only SecureRandom.
    # @example
    #   Cybertrain::Crypto.encryption_key_hex   # => "9b1f..." (64 hex digits)
    # @return [String]
    # @api public
    def self.encryption_key_hex
      Crypto.random_token(32)
    end

    # A 32-byte key for one purpose, derived from a secret (normally
    # `secret_key_base`): the HMAC-SHA256 of `"cybertrain key\0" + label`
    # under `secret` (the prefix keeps it apart from the framework's other
    # HMACs under the raw secret). Each
    # use takes its own label ("cybertrain session", "cybertrain signed
    # cookie", "cybertrain encrypted cookie"), so a value made under one key
    # never verifies or decrypts under another, and rotating the secret
    # changes them all.
    # @example
    #   Cybertrain::Crypto.derive_key(config.secret_key_base, "cybertrain session").bytesize   # => 32
    # @param secret [String]
    # @param label [String] the purpose
    # @return [String] 32 raw bytes
    # @api public
    def self.derive_key(secret, label)
      Crypto.hmac_digest(secret, KEY_PREFIX + label)
    end

    # RFC 2104 HMAC over Digest::SHA256, keyed the way every implementation
    # is: a key longer than the block size is hashed down first, a shorter
    # one is zero-padded up to it. The pads start as BLOCK_SIZE copies of
    # 0x36 ("6") and 0x5c ("\\") -- a zero key byte XORed with the pad
    # byte -- and setbyte puts each key byte's XOR over them; `.b` makes
    # them binary so `+ data.b` never meets an encoding mismatch.
    def self.hmac_digest(secret, data)
      key = secret.bytesize > BLOCK_SIZE ? Digest::SHA256.digest(secret) : secret
      ipad = ("6" * BLOCK_SIZE).b
      opad = ("\\" * BLOCK_SIZE).b
      n = key.bytesize
      i = 0
      while i < n
        b = key.getbyte(i)
        ipad.setbyte(i, b ^ 0x36)
        opad.setbyte(i, b ^ 0x5c)
        i += 1
      end

      inner = Digest::SHA256.digest(ipad + data.b)
      Digest::SHA256.digest(opad + inner)
    end
  end
end
