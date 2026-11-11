# Cybertrain::CookieJar -- `cookies` in a controller (spec section 5, C-7):
# plain, permanent, signed and encrypted cookies, as Rails' cookie jar.
#
# SessionStore builds one per request (Context#cookie_jar) over the cookies
# it parses anyway, with the request's two cookie keys, each derived once
# from `secret_key_base` under its own label (Crypto.derive_key):
#
# - signed (`cookies.signed`): the value `"<urlsafe Base64>--<64 hex
#   HMAC-SHA256>"` under the key labelled `"cybertrain signed cookie"`. The
#   HMAC covers `"<name>=<Base64>"`, so a value signed for one cookie does
#   not verify as another. The client can read the value but not change it;
#   a value whose HMAC does not match (compared in constant time,
#   Crypto.secure_compare) reads nil.
# - encrypted (`cookies.encrypted`): urlsafe Base64 of Encryptor#seal_bytes
#   (AES-256-GCM, a fresh random nonce per write) under the key labelled
#   `"cybertrain encrypted cookie"`, with `"cookie:<name>"` as the
#   additional data, so a value moved to another cookie, the session's
#   included, does not open. The client can neither read nor change it; a
#   value that does not authenticate reads nil.
#
# Base64 is written without padding, so no value needs percent-encoding.
# Writes go out as Set-Cookie through Cookies.serialize and
# Response#replace_cookie (a cookie written twice in one request is sent
# once, with its last value), with `Path=/`, `HttpOnly`, `SameSite=Lax`,
# and `Secure` where the session cookie has it (Config#secure_cookies?:
# session_secure, on in production, or force_ssl) unless the write says
# otherwise. A value read after
# a write in the same request is the written one. Without SessionStore in
# the stack (Controller#cookies then builds a jar over the Cookie header),
# plain and permanent cookies work, `Secure` follows
# Cybertrain.config.secure_cookies? as with SessionStore, and
# `signed` / `encrypted` raise ArgumentError: there is no key.
require "base64"
require "cybertrain/cast"
require "cybertrain/crypto"
require "cybertrain/encryptor"
require "cybertrain/http/cookies"
require "cybertrain/http/response"

module Cybertrain
  # The request's cookies, from {Controller#cookies}. Names are Strings or
  # Symbols; values are Strings. A write takes a String, or a Hash with
  # `value:` and any of `expires:` (a Time), `max_age:` (seconds),
  # `path:` (`"/"`), `httponly:` (true), `secure:` (Config#session_secure)
  # and `same_site:` (`"Lax"`).
  # @example
  #   cookies[:theme]                      # => "dark" or nil
  #   cookies[:theme] = "dark"
  #   cookies[:theme] = { value: "dark", expires: Time.now + 365 * 86_400, httponly: false }
  #   cookies.delete(:theme)
  #   cookies.permanent[:remember] = "1"   # 20 years
  #   cookies.signed[:user_id] = user.id.to_s
  #   cookies.encrypted[:card] = "4242"
  #   cookies.permanent.signed[:user_id] = user.id.to_s
  # @api public
  class CookieJar
    # Labels of the cookie keys (Crypto.derive_key); SessionStore derives
    # them.
    SIGNED_KEY_LABEL = "cybertrain signed cookie"
    ENCRYPTED_KEY_LABEL = "cybertrain encrypted cookie"
    # Max-Age of a permanent cookie: 20 years, as Rails.
    PERMANENT_MAX_AGE = 631_139_040
    # The hex HMAC and the "--" before it, at the end of a signed value.
    SIGNATURE_TAIL = 66
    NO_KEY_MESSAGE = "cookies.signed and cookies.encrypted need SessionStore in the stack " \
                     "(it holds the keys derived from secret_key_base)"

    # 0, 1, 2: how a value is written (#assign_cookie).
    PLAIN = 0
    SIGNED = 1
    ENCRYPTED = 2

    # @param request_cookies [Hash{String => String}] {Cookies.parse} of the
    #   request's Cookie header
    # @param response [Response] where writes go
    # @param signed_key [String] 32 bytes, "" for none
    # @param encrypted_key [String] 32 bytes, "" for none
    # @param secure [Boolean] whether a write is `Secure` unless it says
    def initialize(request_cookies, response, signed_key: "", encrypted_key: "", secure: false)
      # Seeded, then emptied (NOTES rule 9): String keys and values.
      @cookies = { "" => "" }
      @cookies.delete("")
      request_cookies.each { |k, v| @cookies[k.to_s] = v.to_s }
      @response = response
      @signed_key = signed_key
      @encrypted_key = encrypted_key
      @secure = secure
    end

    # The cookie's value as the request sent it (or as this request wrote
    # it), nil when there is none.
    # @param name [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](name)
      @cookies[name.to_s]
    end

    # Writes the cookie (see the class comment for the Hash form).
    # @param name [String, Symbol]
    # @param value [String, Hash]
    # @return [String] the value written
    # @api public
    def []=(name, value)
      assign_cookie(name.to_s, value, PLAIN, false)
    end

    # Deletes the cookie: a Set-Cookie with an empty value and `Max-Age=0`
    # at `path`. Returns the value it had.
    # @param name [String, Symbol]
    # @param path [String] the path it was written with
    # @return [String, nil]
    # @api public
    def delete(name, path: "/")
      key = name.to_s
      set_cookie = Cookies.serialize(key, "", path: path, max_age: 0, secure: @secure)
      @response.replace_cookie(key, set_cookie)
      @cookies.delete(key)
    end

    # The jar whose writes last 20 years (`Max-Age=631139040`) unless they
    # give `expires:` or `max_age:`.
    # @return [PermanentCookieJar]
    # @api public
    def permanent
      PermanentCookieJar.new(self)
    end

    # The jar of signed cookies.
    # @return [SignedCookieJar]
    # @raise [ArgumentError] without SessionStore (no key)
    # @api public
    def signed
      require_cookie_keys!
      SignedCookieJar.new(self, false)
    end

    # The jar of encrypted cookies.
    # @return [EncryptedCookieJar]
    # @raise [ArgumentError] without SessionStore (no key)
    # @api public
    def encrypted
      require_cookie_keys!
      EncryptedCookieJar.new(self, false)
    end

    def require_cookie_keys!
      return nil unless @signed_key.empty? || @encrypted_key.empty?

      message = NO_KEY_MESSAGE
      raise ArgumentError, message
    end

    # Writes `value` (a String, or a Hash of options) as the cookie `name`,
    # signed or encrypted per `kind`, for 20 years when `permanent` and the
    # options set neither `expires:` nor `max_age:`. Answers the plain text.
    def assign_cookie(name, value, kind, permanent)
      text = ""
      path = "/"
      max_age = -1
      expires = Cast.time_or_nil(nil)
      http_only = true
      secure = @secure
      same_site = "Lax"
      case value
      when Hash
        text = Cast.str(value[:value])
        path = Cast.str(value[:path]) if value.key?(:path)
        max_age = Cast.int(value[:max_age]) if value.key?(:max_age)
        expires = Cast.time_or_nil(value[:expires])
        http_only = Cast.bool(value[:httponly]) if value.key?(:httponly)
        secure = Cast.bool(value[:secure]) if value.key?(:secure)
        same_site = Cast.str(value[:same_site]) if value.key?(:same_site)
      else
        text = value.to_s
      end
      max_age = PERMANENT_MAX_AGE if permanent && max_age < 0 && expires.nil?
      stored = cookie_text(name, text, kind)
      set_cookie = Cookies.serialize(name, stored, path: path, max_age: max_age, http_only: http_only,
                                                   same_site: same_site, secure: secure, expires: expires)
      @response.replace_cookie(name, set_cookie)
      @cookies[name] = stored
      text
    end

    # What the cookie carries for `text`: itself, signed or sealed.
    def cookie_text(name, text, kind)
      return text if kind == PLAIN

      payload = ""
      if kind == SIGNED
        payload = Base64.urlsafe_encode64(text, padding: false)
        signature = Crypto.hmac_hex(@signed_key, "#{name}=#{payload}")
        return "#{payload}--#{signature}"
      end

      raw = Encryptor.new(@encrypted_key).seal_bytes(text, "cookie:#{name}")
      payload = Base64.urlsafe_encode64(raw, padding: false)
      payload
    end

    # The text of the signed cookie `name`, nil when it is missing or its
    # HMAC does not match.
    def verified_cookie(name)
      value = @cookies[name]
      return nil if value.nil?

      len = value.bytesize
      return nil if len < SIGNATURE_TAIL || value.byteslice(len - SIGNATURE_TAIL, 2) != "--"

      payload = value.byteslice(0, len - SIGNATURE_TAIL).to_s
      signature = value.byteslice(len - 64, 64).to_s
      expected = Crypto.hmac_hex(@signed_key, "#{name}=#{payload}")
      return nil unless Crypto.secure_compare(signature, expected)

      decoded = CookieJar.decode_cookie_bytes(payload)
      return nil if decoded.nil?

      decoded.force_encoding("UTF-8")
    end

    # The text of the encrypted cookie `name`, nil when it is missing or
    # does not authenticate (under this key, for this name).
    def opened_cookie(name)
      value = @cookies[name]
      return nil if value.nil?

      raw = CookieJar.decode_cookie_bytes(value)
      return nil if raw.nil?

      Encryptor.new(@encrypted_key).open_bytes(raw, "cookie:#{name}")
    end

    # The bytes of urlsafe Base64 (padded or not), nil when it is not.
    def self.decode_cookie_bytes(text)
      Base64.urlsafe_decode64(text)
    rescue ArgumentError
      nil
    end
  end

  # `cookies.permanent`: writes last 20 years. Reads and deletes are the
  # jar's.
  # @api public
  class PermanentCookieJar
    def initialize(jar)
      @jar = jar
    end

    # @param name [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](name)
      @jar[name]
    end

    # @param name [String, Symbol]
    # @param value [String, Hash]
    # @return [String]
    # @api public
    def []=(name, value)
      @jar.assign_cookie(name.to_s, value, CookieJar::PLAIN, true)
    end

    # @param name [String, Symbol]
    # @param path [String]
    # @return [String, nil]
    # @api public
    def delete(name, path: "/")
      @jar.delete(name, path: path)
    end

    # `cookies.permanent.signed`: signed, for 20 years.
    # @return [SignedCookieJar]
    # @api public
    def signed
      @jar.require_cookie_keys!
      SignedCookieJar.new(@jar, true)
    end

    # `cookies.permanent.encrypted`: encrypted, for 20 years.
    # @return [EncryptedCookieJar]
    # @api public
    def encrypted
      @jar.require_cookie_keys!
      EncryptedCookieJar.new(@jar, true)
    end
  end

  # `cookies.signed`: values the client can read but not change.
  # @api public
  class SignedCookieJar
    def initialize(jar, permanent)
      @jar = jar
      @permanent = permanent
    end

    # The value, or nil when the cookie is missing or its signature does
    # not match.
    # @param name [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](name)
      @jar.verified_cookie(name.to_s)
    end

    # @param name [String, Symbol]
    # @param value [String, Hash]
    # @return [String]
    # @api public
    def []=(name, value)
      @jar.assign_cookie(name.to_s, value, CookieJar::SIGNED, @permanent)
    end

    # @param name [String, Symbol]
    # @param path [String]
    # @return [String, nil] the raw (signed) value it had
    # @api public
    def delete(name, path: "/")
      @jar.delete(name, path: path)
    end
  end

  # `cookies.encrypted`: values the client can neither read nor change.
  # @api public
  class EncryptedCookieJar
    def initialize(jar, permanent)
      @jar = jar
      @permanent = permanent
    end

    # The value, or nil when the cookie is missing or does not decrypt.
    # @param name [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](name)
      @jar.opened_cookie(name.to_s)
    end

    # @param name [String, Symbol]
    # @param value [String, Hash]
    # @return [String]
    # @api public
    def []=(name, value)
      @jar.assign_cookie(name.to_s, value, CookieJar::ENCRYPTED, @permanent)
    end

    # @param name [String, Symbol]
    # @param path [String]
    # @return [String, nil] the raw (encrypted) value it had
    # @api public
    def delete(name, path: "/")
      @jar.delete(name, path: path)
    end
  end
end
