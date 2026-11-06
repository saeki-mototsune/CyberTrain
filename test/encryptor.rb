require "cybertrain/test"
require "cybertrain/config"
require "cybertrain/encryptor"

# Cybertrain::Encryptor (AES-256-GCM through Spinel's openssl package) and
# the Crypto / Config entry points cybertrain/encryptor.rb adds. Payloads
# are random (a fresh nonce each), so the tests print nothing that
# depends on them. openssl needs libssl, so the snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).
KEY_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
OTHER_HEX = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"

def key_bytes(hex) = Cybertrain::Encryptor.from_hex(hex)

# The payload with the byte at `index` of its decoded body changed.
def flipped_payload(payload, index)
  raw = Base64.strict_decode64(payload[2, payload.size - 2].to_s)
  bytes = raw.bytes
  bytes[index] = bytes[index] ^ 1
  "1:" + Base64.strict_encode64(bytes.pack("C*"))
end

test "a round trip gives the text back, UTF-8 included" do
  enc = Cybertrain::Encryptor.new(key_bytes(KEY_HEX))
  assert_equal "hello", enc.decrypt(enc.encrypt("hello"))
  text = enc.decrypt(enc.encrypt("héllo, 世界"))
  assert_equal "héllo, 世界", text
  assert_equal "UTF-8", text.encoding.to_s
  assert_equal "", enc.decrypt(enc.encrypt(""))
end

test "the payload is version 1, Base64 of nonce, ciphertext and tag" do
  enc = Cybertrain::Encryptor.new(key_bytes(KEY_HEX))
  payload = enc.encrypt("secret")
  assert payload.start_with?("1:")
  raw = Base64.strict_decode64(payload[2, payload.size - 2].to_s)
  assert_equal 12 + 6 + 16, raw.bytesize
end

test "two encryptions of one text differ (a fresh nonce each)" do
  enc = Cybertrain::Encryptor.new(key_bytes(KEY_HEX))
  refute enc.encrypt("same") == enc.encrypt("same")
end

test "a changed byte anywhere in the payload raises Encryptor::Error" do
  enc = Cybertrain::Encryptor.new(key_bytes(KEY_HEX))
  payload = enc.encrypt("secret")
  # The nonce, the ciphertext and the tag.
  [0, 13, 33].each do |index|
    message = assert_raises("Encryptor::Error") { enc.decrypt(flipped_payload(payload, index)) }
    assert_equal "encrypted payload does not decrypt with the configured keys (wrong key or changed data)", message
  end
end

test "a payload made with another key raises" do
  mine = Cybertrain::Encryptor.new(key_bytes(KEY_HEX))
  theirs = Cybertrain::Encryptor.new(key_bytes(OTHER_HEX))
  assert_raises("Encryptor::Error") { mine.decrypt(theirs.encrypt("secret")) }
end

test "a previous key decrypts; encryption always uses the current one" do
  old = Cybertrain::Encryptor.new(key_bytes(OTHER_HEX))
  stored = old.encrypt("rotated")
  rotated = Cybertrain::Encryptor.new(key_bytes(KEY_HEX), [key_bytes(OTHER_HEX)])
  assert_equal "rotated", rotated.decrypt(stored)
  fresh = rotated.encrypt("rotated")
  assert_equal "rotated", Cybertrain::Encryptor.new(key_bytes(KEY_HEX)).decrypt(fresh)
  assert_raises("Encryptor::Error") { old.decrypt(fresh) }
end

test "an unknown version, bad Base64 and a short payload each raise their own message" do
  enc = Cybertrain::Encryptor.new(key_bytes(KEY_HEX))
  assert_equal "encrypted payload has an unknown version (expected \"1:\")",
               assert_raises("Encryptor::Error") { enc.decrypt("2:AAAA") }
  assert_equal "encrypted payload has an unknown version (expected \"1:\")",
               assert_raises("Encryptor::Error") { enc.decrypt("plain text") }
  assert_equal "encrypted payload is not valid Base64",
               assert_raises("Encryptor::Error") { enc.decrypt("1:!!!") }
  assert_equal "encrypted payload is too short",
               assert_raises("Encryptor::Error") { enc.decrypt("1:" + Base64.strict_encode64("x" * 27)) }
end

test "an empty stored value decrypts to an empty String" do
  enc = Cybertrain::Encryptor.new(key_bytes(KEY_HEX))
  assert_equal "", enc.decrypt("")
end

test "from_hex takes 64 hex characters, either case, and nothing else" do
  assert_equal 32, Cybertrain::Encryptor.from_hex(KEY_HEX).bytesize
  assert_equal Cybertrain::Encryptor.from_hex(KEY_HEX), Cybertrain::Encryptor.from_hex(KEY_HEX.upcase)
  message = assert_raises("Encryptor::Error") { Cybertrain::Encryptor.from_hex(KEY_HEX[0, 63].to_s) }
  assert_equal "encryption key must be 64 hex characters", message
  assert_raises("Encryptor::Error") { Cybertrain::Encryptor.from_hex(KEY_HEX[0, 62].to_s + "zz") }
  assert_raises("Encryptor::Error") { Cybertrain::Encryptor.from_hex("") }
end

test "a key of the wrong size is refused by the constructor" do
  message = assert_raises("Encryptor::Error") { Cybertrain::Encryptor.new("short") }
  assert_equal "encryption key must be 32 bytes", message
end

test "Crypto.encrypt without a key raises the configuration message" do
  Cybertrain.config = Cybertrain::Config.new
  Cybertrain.config.encryption_key = ""
  message = assert_raises("Encryptor::Error") { Cybertrain::Crypto.encrypt("x") }
  assert_equal "CYBERTRAIN_ENCRYPTION_KEY is not set; make one with `cybertrain secret --hex`", message
  assert_raises("Encryptor::Error") { Cybertrain::Crypto.decrypt("1:AAAA") }
end

test "Crypto.encrypt / decrypt use the configured key and the previous ones" do
  Cybertrain.config = Cybertrain::Config.new
  Cybertrain.config.encryption_key = OTHER_HEX
  stored = Cybertrain::Crypto.encrypt("kept")
  assert_equal "kept", Cybertrain::Crypto.decrypt(stored)
  Cybertrain.config.encryption_key = KEY_HEX
  assert_raises("Encryptor::Error") { Cybertrain::Crypto.decrypt(stored) }
  Cybertrain.config.encryption_keys_previous = [OTHER_HEX]
  assert_equal "kept", Cybertrain::Crypto.decrypt(stored)
end

test "the configured encryptor is built once per key" do
  Cybertrain.config = Cybertrain::Config.new
  Cybertrain.config.encryption_key = KEY_HEX
  first = Cybertrain.config.encryptor
  assert first.equal?(Cybertrain.config.encryptor)
  Cybertrain.config.encryption_key = OTHER_HEX
  refute first.equal?(Cybertrain.config.encryptor)
end

test "encrypt_or_nil and decrypt_or_nil keep nil nil" do
  Cybertrain.config = Cybertrain::Config.new
  Cybertrain.config.encryption_key = KEY_HEX
  assert_nil Cybertrain::Crypto.encrypt_or_nil(nil)
  assert_nil Cybertrain::Crypto.decrypt_or_nil(nil)
  payload = Cybertrain::Crypto.encrypt_or_nil("x")
  assert payload.to_s.start_with?("1:")
  assert_equal "x", Cybertrain::Crypto.decrypt_or_nil(payload)
end

test "encryption_key_hex is 64 lowercase hex characters, a fresh one each call" do
  hex = Cybertrain::Crypto.encryption_key_hex
  assert_equal 64, hex.size
  assert_equal 32, Cybertrain::Encryptor.from_hex(hex).bytesize
  hex.each_char { |c| assert("0123456789abcdef".include?(c)) }
  refute hex == Cybertrain::Crypto.encryption_key_hex
end

Cybertrain::Test.run!
