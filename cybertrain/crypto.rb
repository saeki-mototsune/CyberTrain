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
      digest = hmac_digest(secret, data)
      hex = +""
      digest.bytes.each do |b|
        hex << HEX_DIGITS[(b >> 4) & 0xf]
        hex << HEX_DIGITS[b & 0xf]
      end
      hex
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

    def self.random_token(bytes = 32)
      SecureRandom.hex(bytes)
    end

    # RFC 2104 HMAC over Digest::SHA256, keyed the way every implementation
    # is: a key longer than the block size is hashed down first, a shorter
    # one is zero-padded up to it, and the pad bytes come out of a typed
    # Array<Integer> (seeded via the block form -- spikes/NOTES.md rule 9)
    # so `pack("C*")` can turn them back into the raw bytes SHA-256 hashes.
    def self.hmac_digest(secret, data)
      key = secret.bytesize > BLOCK_SIZE ? Digest::SHA256.digest(secret) : secret
      key_bytes = key.bytes
      padded = Array.new(BLOCK_SIZE) { 0 }
      i = 0
      while i < key_bytes.length
        padded[i] = key_bytes[i]
        i += 1
      end

      ipad = Array.new(BLOCK_SIZE) { |j| padded[j] ^ 0x36 }
      opad = Array.new(BLOCK_SIZE) { |j| padded[j] ^ 0x5c }

      inner = Digest::SHA256.digest(ipad.pack("C*") + data.b)
      Digest::SHA256.digest(opad.pack("C*") + inner)
    end
  end
end
