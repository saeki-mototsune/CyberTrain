require "cybertrain/crypto"
require "base64"
require "json"

module Cybertrain
  # A cookie-store session: a flat Hash<String,String> that round-trips
  # through a signed, base64-encoded cookie value. Design D8 restricts
  # values to String -- there is no marshalling format to smuggle other
  # types through, so nothing else needs to be ruled out at the type level.
  class Session
    def initialize(data = {})
      @data = {}
      data.each { |k, v| @data[k.to_s] = v.to_s }
      @changed = false
    end

    def [](key)
      @data[key.to_s]
    end

    def []=(key, value)
      k = key.to_s
      v = value.to_s
      @changed = true unless @data[k] == v
      @data[k] = v
    end

    def delete(key)
      k = key.to_s
      @changed = true if @data.key?(k)
      @data.delete(k)
    end

    def key?(key)
      @data.key?(key.to_s)
    end

    def keys
      @data.keys
    end

    def clear
      @changed = true unless @data.empty?
      @data.clear
    end

    def to_h
      @data.dup
    end

    def changed?
      @changed
    end

    CSRF_TOKEN_KEY = "_csrf_token"

    # Returns this session's CSRF token, minting and storing one the first
    # time it is asked for. This is a typed instance method (rather than a
    # module method taking a Session argument) so Spinel resolves `self`
    # statically at every call site; a free function
    # `CsrfProtection.token_for(session)` widened `session` to an untyped
    # poly value once it was called through a real SessionStore -> Context
    # chain, so `session[TOKEN_KEY] = token` silently did nothing
    # (regression tests: test/csrf_chain.rb, test/csrf_conditional.rb).
    def csrf_token!
      token = @data[CSRF_TOKEN_KEY]
      if token.nil? || token.empty?
        token = Crypto.random_token
        self[CSRF_TOKEN_KEY] = token
      end
      token
    end

    FLASH_KEY = "_flash"

    # Flash's own storage primitives, kept here (as typed Session instance
    # methods, `self` statically known) for the same reason as
    # csrf_token! above: Flash.load/.store used to mutate the session
    # straight from a module method taking `session` as a plain parameter
    # (`session[FLASH_KEY] = json`), and through a real SessionStore ->
    # Middleware chain that write silently failed to stick (session.changed?
    # stayed false) the same way CsrfProtection.token_for's did. Flash calls
    # these instead of touching `[]`/`[]=`/`delete` on a `session` parameter
    # directly.
    def flash_payload
      self[FLASH_KEY]
    end

    def flash_payload=(json)
      self[FLASH_KEY] = json
    end

    def clear_flash!
      delete(FLASH_KEY)
    end

    # cookie_value is "<base64 JSON payload>--<64 hex HMAC>". The signature
    # occupies a known-width suffix, so it is sliced off rather than located
    # by scanning for "--" -- urlsafe base64's own alphabet includes "-",
    # so the separator can legitimately recur inside the payload.
    def self.load(cookie_value, secret)
      empty = Session.new
      return empty if cookie_value.nil? || cookie_value.length < 66

      len = cookie_value.length
      sep = cookie_value[len - 66, 2]
      return empty unless sep == "--"

      payload = cookie_value[0, len - 66]
      signature = cookie_value[len - 64, 64]
      expected = Crypto.hmac_hex(secret, payload)
      return empty unless Crypto.secure_compare(signature, expected)

      data = {}
      begin
        # JSON::ParserError is NOT a StandardError under Spinel 2026.09.12
        # (it has no entry in the builtin exception hierarchy table), so a
        # bare `rescue StandardError` lets a malformed payload's parse error
        # through; it is listed explicitly here and in Flash.load.
        json = Base64.urlsafe_decode64(payload)
        parsed = JSON.parse(json)
        case parsed
        when Hash
          parsed.each { |k, v| data[k.to_s] = v.to_s }
        end
      rescue JSON::ParserError, StandardError
        return Session.new
      end
      Session.new(data)
    end

    def self.dump(session, secret)
      payload = Base64.urlsafe_encode64(JSON.generate(session.to_h))
      "#{payload}--#{Crypto.hmac_hex(secret, payload)}"
    end
  end
end
