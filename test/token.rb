require "cybertrain/test"
require "cybertrain/token"

# Cybertrain::Token (plan D15): "<id>--<expires epoch>--<64 hex>", the hex
# an HMAC-SHA256 of "<purpose>:<id>:<expires>:<bound_to>" keyed with
# Crypto.derive_key(Cybertrain.config.secret_key_base, "cybertrain token").
# Runs under CRuby too (`ruby -I. test/token.rb`).

SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
Cybertrain.config.secret_key_base = SECRET

# The HMAC of "password_reset:7:1900:digest-a" under the derived key,
# computed apart from the framework with CRuby's OpenSSL:
#   k = OpenSSL::HMAC.digest("SHA256", SECRET, "cybertrain key\0cybertrain token")
#   OpenSSL::HMAC.hexdigest("SHA256", k, "password_reset:7:1900:digest-a")
RESET_MAC = "46a54aa8e2b35722e58e0a13f634c427191202c02fa4091510332b8e201ea6be"

test "a token verifies for its purpose, id and binding until it expires" do
  t = Cybertrain::Token.issue("password_reset", 7, 900, "digest-a", 1_000)
  assert_equal 7, Cybertrain::Token.id_from(t)
  assert Cybertrain::Token.valid?(t, "password_reset", "digest-a", 1_000)
  assert Cybertrain::Token.valid?(t, "password_reset", "digest-a", 1_899)
  refute Cybertrain::Token.valid?(t, "password_reset", "digest-a", 1_900)
  refute Cybertrain::Token.valid?(t, "password_reset", "digest-a", 1_901)
  refute Cybertrain::Token.valid?(t, "password_reset", "digest-b", 1_899)
  refute Cybertrain::Token.valid?(t, "confirmation", "digest-a", 1_899)
  assert_equal false, t.include?(".")
end

test "a token is id--expires--hmac of purpose:id:expires:bound_to under the derived key" do
  t = Cybertrain::Token.issue("password_reset", 7, 900, "digest-a", 1_000)
  assert_equal "7--1900--#{RESET_MAC}", t
  key = Cybertrain::Crypto.derive_key(SECRET, "cybertrain token")
  assert_equal RESET_MAC, Cybertrain::Crypto.hmac_hex(key, "password_reset:7:1900:digest-a")
  # Issued again with the same inputs, the same token: nothing random.
  assert_equal t, Cybertrain::Token.issue("password_reset", 7, 900, "digest-a", 1_000)
  assert_equal "12--1300--", Cybertrain::Token.issue("confirmation", 12, 300, "ann@example.com", 1_000).byteslice(0, 10)
end

test "a changed id, expiry or MAC does not verify, though id_from still reads the id" do
  forged_id = "8--1900--#{RESET_MAC}"
  assert_equal 8, Cybertrain::Token.id_from(forged_id)
  refute Cybertrain::Token.valid?(forged_id, "password_reset", "digest-a", 1_000)
  later = "7--9900--#{RESET_MAC}"
  assert_equal 7, Cybertrain::Token.id_from(later)
  refute Cybertrain::Token.valid?(later, "password_reset", "digest-a", 1_000)
  flipped = "7--1900--#{RESET_MAC.byteslice(0, 63)}f"
  refute Cybertrain::Token.valid?(flipped, "password_reset", "digest-a", 1_000)
  assert Cybertrain::Token.valid?("7--1900--#{RESET_MAC}", "password_reset", "digest-a", 1_000)
end

test "a token stops verifying when secret_key_base changes" do
  t = Cybertrain::Token.issue("password_reset", 7, 900, "digest-a", 1_000)
  Cybertrain.config.secret_key_base = "f" * 64
  refute Cybertrain::Token.valid?(t, "password_reset", "digest-a", 1_000)
  other = Cybertrain::Token.issue("password_reset", 7, 900, "digest-a", 1_000)
  Cybertrain.config.secret_key_base = SECRET
  refute other == t
  assert Cybertrain::Token.valid?(t, "password_reset", "digest-a", 1_000)
end

test "malformed tokens are refused without raising" do
  zeros = "0" * 64
  malformed = [
    "",
    "7--x--y",
    "-1--1--#{zeros}",
    "-" * 10_240,
    "7--1900",
    "7--1900--",
    "--1900--#{RESET_MAC}",
    "7----#{RESET_MAC}",
    "07--1900--#{RESET_MAC}",
    "7--01900--#{RESET_MAC}",
    "7--1900--#{RESET_MAC.upcase}",
    "7--1900--#{RESET_MAC.byteslice(0, 63)}",
    "7--1900--#{RESET_MAC}0",
    "7--1900--#{RESET_MAC}--1",
    "7-1900-#{RESET_MAC}",
    " 7--1900--#{RESET_MAC}",
    "7.0--1900--#{RESET_MAC}",
    "1234567890123456789--1900--#{RESET_MAC}",
    "7--1234567890123456789--#{RESET_MAC}",
    "7--1900--#{"g" * 64}"
  ]
  malformed.each do |bad|
    assert_equal 0, Cybertrain::Token.id_from(bad)
    refute Cybertrain::Token.valid?(bad, "password_reset", "digest-a", 1_000)
  end
end

test "issue refuses what it could not read back" do
  assert_equal "the token id must be from 1 to 999999999999999999 (got 0)",
               assert_raises("ArgumentError") { Cybertrain::Token.issue("password_reset", 0, 900, "d", 1_000) }
  assert_equal "the token id must be from 1 to 999999999999999999 (got -3)",
               assert_raises("ArgumentError") { Cybertrain::Token.issue("password_reset", -3, 900, "d", 1_000) }
  assert_equal "expires_in must be positive (got 0)",
               assert_raises("ArgumentError") { Cybertrain::Token.issue("password_reset", 7, 0, "d", 1_000) }
  assert_equal "the token purpose must be non-empty and contain no \":\"",
               assert_raises("ArgumentError") { Cybertrain::Token.issue("", 7, 900, "d", 1_000) }
  assert_equal "the token purpose must be non-empty and contain no \":\"",
               assert_raises("ArgumentError") { Cybertrain::Token.issue("password:reset", 7, 900, "d", 1_000) }
  refute Cybertrain::Token.valid?("7--1900--#{RESET_MAC}", "password:reset", "digest-a", 1_000)
  refute Cybertrain::Token.valid?("7--1900--#{RESET_MAC}", "", "digest-a", 1_000)
end

test "without a secret_key_base, issue and valid? raise rather than sign with an empty key" do
  Cybertrain.config.secret_key_base = ""
  issued = assert_raises("ArgumentError") { Cybertrain::Token.issue("password_reset", 7, 900, "d", 1_000) }
  checked = assert_raises("ArgumentError") { Cybertrain::Token.valid?("7--1900--#{RESET_MAC}", "password_reset", "digest-a", 1_000) }
  Cybertrain.config.secret_key_base = SECRET
  assert_equal "Token needs Cybertrain.config.secret_key_base (boot sets it)", issued
  assert_equal "Token needs Cybertrain.config.secret_key_base (boot sets it)", checked
end

Cybertrain::Test.run!
