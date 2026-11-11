# Cybertrain::Encryptor: AES-256-GCM, for column encryption (`encrypts
# :api_key` in a model, spec section 10), the session cookie and
# `cookies.encrypted` (spec section 5.1).
#
# Loaded by every program: `require "cybertrain"` requires it, because the
# session cookie is encrypted. It requires Spinel's openssl package, which
# links the system libssl and libcrypto (on macOS, Homebrew's OpenSSL:
# docs/guide/install.md), so every application links them. Once openssl is
# in a program, a `getbyte` on a boxed String dispatches over the package's
# own `getbyte` (spikes/NOTES.md rule 62): code that scans such a String
# byte by byte reads it through a new local, `s = text.to_s`. gen/app.rb no
# longer requires this file for `encrypts`; it still sets
# `Config.encryption_required` then, so boot requires
# CYBERTRAIN_ENCRYPTION_KEY.
#
# Two forms of sealed value, each with a 12-byte random nonce made per
# call and the GCM tag's 16 bytes, so nothing is encrypted without being
# authenticated:
#
# - {#encrypt} / {#decrypt} (columns, {Crypto.encrypt}): the payload is
#   `"1:" + Base64(nonce ‖ ciphertext ‖ tag)`, `1` the payload format's
#   version, with no additional data. A wrong key, a changed byte, an
#   unknown version, bad Base64 or a payload too short to hold a nonce and
#   a tag raises {Encryptor::Error}.
# - {#seal_bytes} / {#open_bytes} (the session cookie and
#   `cookies.encrypted`, under keys {Crypto.derive_key} makes): the raw
#   bytes `nonce ‖ ciphertext ‖ tag`, sealed with additional data that names
#   the purpose (`"session"`, `"cookie:<name>"`), so a value opens only for
#   the purpose it was sealed for. {#open_bytes} answers nil, never raises,
#   for anything that does not authenticate.
#
# This file also adds to {Crypto} (encrypt, decrypt, encrypt_or_nil,
# decrypt_or_nil, through the configured key) and to {Config} (encryptor).
require "openssl"
require "base64"
require "securerandom"
require "cybertrain/crypto"
require "cybertrain/config"

module Cybertrain
  # AES-256-GCM with one current key (encrypts and decrypts) and any number
  # of previous ones (decrypt only, tried in order after the current one).
  # Keys are raw bytes, 32 each: {Encryptor.from_hex} reads the 64-hex
  # configuration value.
  # @example
  #   enc = Cybertrain::Encryptor.new(Cybertrain::Encryptor.from_hex(ENV["CYBERTRAIN_ENCRYPTION_KEY"].to_s))
  #   payload = enc.encrypt("sk_live_...")   # => "1:3q2+7w..."
  #   enc.decrypt(payload)                   # => "sk_live_..."
  # @api public
  class Encryptor
    # A payload that cannot be decrypted, or a key that cannot be used.
    # @api public
    class Error < StandardError
    end

    PAYLOAD_PREFIX = "1:"
    KEY_BYTES = 32
    NONCE_BYTES = 12
    TAG_BYTES = 16
    CIPHER = "aes-256-gcm"

    # @param key_bytes [String] the current key, 32 raw bytes
    # @param previous [Array<String>] earlier keys, 32 raw bytes each
    # @raise [Encryptor::Error] when a key is not 32 bytes
    def initialize(key_bytes, previous = Array.new(0) { "" })
      @keys = Array.new(0) { "" }
      @keys << Encryptor.checked_key(key_bytes)
      i = 0
      while i < previous.size
        @keys << Encryptor.checked_key(previous[i])
        i += 1
      end
    end

    # The 32 raw bytes of a 64-hex-character key (either case).
    # @param hex [String]
    # @return [String]
    # @raise [Encryptor::Error] for anything but 64 hex characters
    # @api public
    def self.from_hex(hex)
      s = hex.to_s
      raise Error, "encryption key must be 64 hex characters" unless Config.encryption_key_text?(s)

      [s].pack("H*")
    end

    def self.checked_key(key)
      raise Error, "encryption key must be #{KEY_BYTES} bytes" unless key.bytesize == KEY_BYTES

      key
    end

    # The payload of `text` under the current key, with a fresh nonce.
    # @param text [String]
    # @return [String] `"1:"` and Base64
    # @api public
    def encrypt(text)
      raw = seal_bytes(text, "")
      PAYLOAD_PREFIX + Base64.strict_encode64(raw)
    end

    # `text` sealed under the current key with a fresh random nonce and
    # `aad` as the GCM additional data (authenticated, not encrypted): the
    # raw bytes `nonce(12) ‖ ciphertext ‖ tag(16)`, which only
    # {#open_bytes} with the same `aad` opens.
    # @example
    #   raw = enc.seal_bytes("{\"user_id\":\"5\"}", "session")
    #   enc.open_bytes(raw, "session")   # => "{\"user_id\":\"5\"}"
    #   enc.open_bytes(raw, "cookie:x")  # => nil
    # @param text [String]
    # @param aad [String] the purpose the value is sealed for
    # @return [String] binary
    # @api public
    def seal_bytes(text, aad)
      s = text.to_s
      data = aad.to_s
      nonce = SecureRandom.random_bytes(NONCE_BYTES)
      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.encrypt
      cipher.key = @keys[0]
      cipher.iv = nonce
      cipher.auth_data = data
      sealed = cipher.update(s) + cipher.final
      tag = cipher.auth_tag
      nonce + sealed + tag
    end

    # The text {#seal_bytes} sealed with the same `aad`, under the current
    # key or a previous one, as UTF-8; nil when no key authenticates it (a
    # wrong key, other additional data, a changed or missing byte, or fewer
    # bytes than a nonce and a tag). Never raises for the bytes it is given.
    # @param raw [String] binary, `nonce ‖ ciphertext ‖ tag`
    # @param aad [String]
    # @return [String, nil]
    # @api public
    def open_bytes(raw, aad)
      bytes = raw.to_s
      data = aad.to_s
      n = bytes.bytesize
      return nil if n < NONCE_BYTES + TAG_BYTES

      nonce = bytes.byteslice(0, NONCE_BYTES).to_s
      sealed = bytes.byteslice(NONCE_BYTES, n - NONCE_BYTES - TAG_BYTES).to_s
      tag = bytes.byteslice(n - TAG_BYTES, TAG_BYTES).to_s
      i = 0
      while i < @keys.size
        opened = Encryptor.open_with(@keys[i], nonce, sealed, tag, data)
        return opened.force_encoding("UTF-8") unless opened.nil?

        i += 1
      end
      nil
    end

    # The text of a payload {#encrypt} made, under the current key or a
    # previous one, as UTF-8. An empty String (an empty stored cell, which
    # no payload is) is "".
    # @param payload [String]
    # @return [String]
    # @raise [Encryptor::Error] on an unknown version, bad Base64, a payload
    #   too short, or one no key authenticates (a wrong key or a changed byte)
    # @api public
    def decrypt(payload)
      s = payload.to_s
      return "" if s.empty?
      unless s.start_with?(PAYLOAD_PREFIX)
        raise Error, "encrypted payload has an unknown version (expected \"#{PAYLOAD_PREFIX}\")"
      end

      raw = Encryptor.decode_payload(s[2, s.size - 2].to_s)
      raise Error, "encrypted payload is too short" if raw.bytesize < NONCE_BYTES + TAG_BYTES

      opened = open_bytes(raw, "")
      return opened unless opened.nil?

      raise Error, "encrypted payload does not decrypt with the configured keys (wrong key or changed data)"
    end

    def self.decode_payload(text)
      Base64.strict_decode64(text)
    rescue ArgumentError
      raise Error, "encrypted payload is not valid Base64"
    end

    # The plaintext bytes, or nil when the tag does not authenticate them
    # and `aad` under `key` (OpenSSL checks the GCM tag in constant time).
    # OpenSSLError, the parent of both Spinel's OpenSSL::CipherError and
    # CRuby's OpenSSL::Cipher::CipherError.
    def self.open_with(key, nonce, sealed, tag, aad)
      cipher = OpenSSL::Cipher.new(CIPHER)
      cipher.decrypt
      cipher.key = key
      cipher.iv = nonce
      cipher.auth_tag = tag
      cipher.auth_data = aad
      opened = cipher.update(sealed) + cipher.final
      opened
    rescue OpenSSL::OpenSSLError
      nil
    end

    # The Encryptor {Config#encryptor} answers, kept for the key text it was
    # built from: built again only when the configured keys change.
    @shared = nil
    @shared_for = ""

    def self.for_keys(key_hex, previous_hex)
      if key_hex.empty?
        raise Error, "CYBERTRAIN_ENCRYPTION_KEY is not set; make one with `cybertrain secret --hex`"
      end

      label = key_hex + "," + previous_hex.join(",")
      cached = @shared
      return cached if !cached.nil? && @shared_for == label

      previous = Array.new(0) { "" }
      previous_hex.each { |hex| previous << Encryptor.from_hex(hex) }
      built = Encryptor.new(Encryptor.from_hex(key_hex), previous)
      @shared = built
      @shared_for = label
      built
    end
  end

  class Config
    # The {Encryptor} for {#encryption_key} and {#encryption_keys_previous},
    # built on first use and again only when they change.
    # @return [Encryptor]
    # @raise [Encryptor::Error] when the key is unset or not 64 hex
    #   characters (boot reports this first: {#encryption_error})
    # @api public
    def encryptor
      Encryptor.for_keys(@encryption_key, @encryption_keys_previous)
    end
  end

  module Crypto
    # `text` encrypted with the configured key ({Config#encryptor}).
    # @example
    #   Cybertrain::Crypto.encrypt("sk_live_...")   # => "1:3q2+7w..."
    # @param text [String]
    # @return [String]
    # @raise [Encryptor::Error] when no key is configured
    # @api public
    def self.encrypt(text)
      Cybertrain.config.encryptor.encrypt(text)
    end

    # The text of a payload {Crypto.encrypt} made, with the configured key
    # or a previous one.
    # @param payload [String]
    # @return [String]
    # @raise [Encryptor::Error] when it does not decrypt
    # @api public
    def self.decrypt(payload)
      Cybertrain.config.encryptor.decrypt(payload)
    end

    # {Crypto.encrypt}, with nil kept nil (a nullable encrypted column's
    # generated to_row).
    # @param text [String, nil]
    # @return [String, nil]
    def self.encrypt_or_nil(text)
      return nil if text.nil?

      Cybertrain.config.encryptor.encrypt(text)
    end

    # {Crypto.decrypt}, with nil kept nil (a nullable encrypted column's
    # generated load_row).
    # @param payload [String, nil]
    # @return [String, nil]
    def self.decrypt_or_nil(payload)
      return nil if payload.nil?

      Cybertrain.config.encryptor.decrypt(payload)
    end
  end
end
