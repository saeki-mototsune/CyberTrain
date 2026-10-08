# Cybertrain::Crypto -- the primitives Session and CsrfProtection sign and
# compare with.
#
# HMAC-SHA256 is implemented here in pure Ruby over Digest::SHA256.digest
# rather than via `require "openssl"`: the `openssl` package links against
# Homebrew's OpenSSL, which is not on this build's link path, while `digest`
# is the runtime's own vendored SHA-256 (spikes/NOTES.md numbers table).
require "digest"
require "securerandom"

module Cybertrain
  module Crypto
    BLOCK_SIZE = 64
    HEX_DIGITS = "0123456789abcdef"

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
    # signature or token was guessed correctly.
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
    def self.random_token(bytes = 32)
      Crypto.hex(SecureRandom.random_bytes(bytes))
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
