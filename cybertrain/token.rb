# Cybertrain::Token -- signed, expiring tokens for links sent by mail (a
# password reset, an address confirmation), as Rails 8's
# `generates_token_for` makes them: a token carries a record id and an
# expiry, and stops working when the value it is bound to changes (the
# password digest for a reset, so the link works once).
#
# A token reads `"<id>--<expires>--<hmac>"`: the id and the expiry (Unix
# seconds) in decimal, then the lowercase hex of the HMAC-SHA256 of
# `"<purpose>:<id>:<expires>:<bound_to>"` keyed with
# `Crypto.derive_key(Cybertrain.config.secret_key_base, "cybertrain
# token")` (cybertrain/crypto.rb; the session and cookie keys are
# derived the same way under their own labels). The key is derived on
# each call from the secret boot resolved (Config#resolve_secret!), so
# rotating `secret_key_base` ends every token. A token has no `.` in it
# (the router splits a format off at the last dot) and nothing to escape
# in a URL.
#
# Code inside Cybertrain::Template that names `Token` means the template
# lexer's (cybertrain/template/lexer.rb); write `Cybertrain::Token` there.
require "cybertrain/crypto"
require "cybertrain/config"

module Cybertrain
  # Signed, expiring tokens (see the file comment).
  # @api public
  module Token
    # The label of the token key (Crypto.derive_key).
    KEY_LABEL = "cybertrain token"
    # The most decimal digits an id or an expiry may have (both stay
    # below 10**18, so reading one back never overflows a 64-bit Integer).
    MAX_DIGITS = 18
    # The largest id a token can carry.
    MAX_ID = 999_999_999_999_999_999
    # Hex digits of the HMAC-SHA256.
    MAC_HEX = 64
    # The longest well-formed token: two numbers, two separators, the MAC.
    MAX_BYTES = MAX_DIGITS + 2 + MAX_DIGITS + 2 + MAC_HEX

    # A token for the record `id`, for `purpose`, valid for `expires_in`
    # seconds from `now` and while `bound_to` keeps its value.
    # @example
    #   Cybertrain::Token.issue("password_reset", user.id, 15 * 60, user.password_digest)
    #   # => "7--1762861200--3f9c..." (64 hex digits at the end)
    # @param purpose [String] what the token is for; non-empty, no `:`
    # @param id [Integer] the record's id, 1 to {MAX_ID}
    # @param expires_in [Integer] seconds, positive
    # @param bound_to [String] a value the token stops verifying without
    #   (the password digest, the address being confirmed)
    # @param now [Integer] the current Unix time
    # @return [String]
    # @raise [ArgumentError] for a purpose, id or lifetime the token could
    #   not carry, or when `Cybertrain.config.secret_key_base` is empty
    # @api public
    def self.issue(purpose, id, expires_in, bound_to, now = Time.now.to_i)
      label = purpose.to_s
      unless Token.purpose_ok?(label)
        message = "the token purpose must be non-empty and contain no \":\""
        raise ArgumentError, message
      end
      if id < 1 || id > MAX_ID
        message = "the token id must be from 1 to #{MAX_ID} (got #{id})"
        raise ArgumentError, message
      end
      if expires_in < 1
        message = "expires_in must be positive (got #{expires_in})"
        raise ArgumentError, message
      end
      expires = now + expires_in
      if expires < 1 || expires > MAX_ID
        message = "the token expiry must be from 1 to #{MAX_ID} (got #{expires})"
        raise ArgumentError, message
      end
      id_text = id.to_s
      expires_text = expires.to_s
      mac = Token.token_mac(label, id_text, expires_text, bound_to.to_s)
      out = String.new
      out << id_text << "--" << expires_text << "--" << mac
      out
    end

    # The id a token carries, read without verifying it (to find the
    # record whose `bound_to` {.valid?} then checks). 0 for a token that
    # is not `"<id>--<expires>--<64 lowercase hex>"`, each number 1 to 18
    # digits with no leading zero.
    # @example
    #   Cybertrain::Token.id_from(params[:token].to_s)   # => 7, or 0
    # @param token [String]
    # @return [Integer]
    # @api public
    def self.id_from(token)
      fields = Token.token_fields(token)
      return 0 if fields.empty?

      Token.digits_value(fields[0])
    end

    # Whether `token` was issued for `purpose` and `bound_to` under the
    # current `secret_key_base` and has not expired at `now`: the MAC is
    # compared first, in constant time ({Crypto.secure_compare}), then the
    # expiry (`now` must be before it). A malformed token answers false.
    # @example
    #   Cybertrain::Token.valid?(token, "password_reset", user.password_digest)
    # @param token [String]
    # @param purpose [String]
    # @param bound_to [String]
    # @param now [Integer] the current Unix time
    # @return [Boolean]
    # @raise [ArgumentError] when `Cybertrain.config.secret_key_base` is empty
    # @api public
    def self.valid?(token, purpose, bound_to, now = Time.now.to_i)
      label = purpose.to_s
      fields = Token.token_fields(token)
      return false if fields.empty?
      return false unless Token.purpose_ok?(label)

      expected = Token.token_mac(label, fields[0], fields[1], bound_to.to_s)
      return false unless Crypto.secure_compare(fields[2], expected)

      now < Token.digits_value(fields[1])
    end

    # The hex MAC of one token's fields under the derived key.
    # @api private
    def self.token_mac(purpose, id_text, expires_text, bound_to)
      data = String.new
      data << purpose << ":" << id_text << ":" << expires_text << ":" << bound_to
      Crypto.hmac_hex(Token.token_key, data)
    end

    # Crypto.derive_key(secret_key_base, KEY_LABEL); raises on an empty
    # secret rather than sign with a key anyone can compute.
    # @api private
    def self.token_key
      secret = Cybertrain.config.secret_key_base.to_s
      if secret.empty?
        message = "Token needs Cybertrain.config.secret_key_base (boot sets it)"
        raise ArgumentError, message
      end
      Crypto.derive_key(secret, KEY_LABEL)
    end

    # Non-empty, without the `:` that separates the MAC's fields.
    # @api private
    def self.purpose_ok?(purpose)
      !purpose.empty? && purpose.index(":").nil?
    end

    # The three fields of a well-formed token, `[id, expires, mac]`, or an
    # empty Array. Byte by byte through a fresh local (spikes/NOTES.md
    # rule 62); a token longer than MAX_BYTES is refused before scanning.
    # @api private
    def self.token_fields(token)
      s = token.to_s
      none = Array.new(0) { "" }
      n = s.bytesize
      return none if n > MAX_BYTES

      first = Token.number_end(s, 0)
      return none if first < 0 || first + 1 >= n || s.getbyte(first) != 45 || s.getbyte(first + 1) != 45

      second = Token.number_end(s, first + 2)
      return none if second < 0 || second + 1 >= n || s.getbyte(second) != 45 || s.getbyte(second + 1) != 45

      mac_at = second + 2
      return none unless n - mac_at == MAC_HEX

      i = mac_at
      while i < n
        b = s.getbyte(i)
        return none unless (b >= 48 && b <= 57) || (b >= 97 && b <= 102)

        i += 1
      end
      [s.byteslice(0, first), s.byteslice(first + 2, second - first - 2), s.byteslice(mac_at, MAC_HEX)]
    end

    # Where the decimal number starting at `from` ends: 1 to MAX_DIGITS
    # digits, no leading zero; -1 when there is none.
    # @api private
    def self.number_end(text, from)
      s = text.to_s
      n = s.bytesize
      i = from
      while i < n
        b = s.getbyte(i)
        break unless b >= 48 && b <= 57

        i += 1
      end
      digits = i - from
      return -1 if digits < 1 || digits > MAX_DIGITS
      return -1 if s.getbyte(from) == 48

      i
    end

    # The value of a String of decimal digits (token_fields checked them).
    # @api private
    def self.digits_value(text)
      s = text.to_s
      value = 0
      i = 0
      n = s.bytesize
      while i < n
        value = value * 10 + (s.getbyte(i) - 48)
        i += 1
      end
      value
    end
  end
end
