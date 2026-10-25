require "cybertrain/crypto"
require "base64"
require "json"

module Cybertrain
  # A cookie-store session: a flat Hash<String,String> that round-trips
  # through a signed, base64-encoded cookie value. Design D8 restricts
  # values to String -- there is no marshalling format to smuggle other
  # types through, so nothing else needs to be ruled out at the type level.
  #
  # {Controller#session} in an action. Keys and values are Strings (a
  # Symbol key is its name; a value is stored as `value.to_s`, so
  # `session[:user_id] = 5` reads back as `"5"`).
  #
  # The cookie is signed with `secret_key_base` (HMAC-SHA256), not
  # encrypted: the client can read it, but a changed or forged cookie is
  # dropped and the request starts with an empty session. It is sent only
  # when the session changed, as `_cybertrain_session` with `Path=/;
  # HttpOnly; SameSite=Lax`, `Secure` in production and a two-week Max-Age
  # (the name, the Max-Age and `Secure` are {Config} settings).
  # `"_csrf_token"` and `"_flash"` are the framework's keys.
  # @example
  #   session[:user_id] = user.id
  #   User.find(session[:user_id]) if session.key?(:user_id)
  #   session.delete(:user_id)
  # @api public
  class Session
    def initialize(data = {})
      @data = {}
      # keys + while: an each block is a Proc and closure per new Session.
      keys = data.keys
      i = 0
      while i < keys.size
        @data[keys[i].to_s] = data[keys[i]].to_s
        i += 1
      end
      @changed = false
    end

    # @param key [String, Symbol]
    # @return [String, nil]
    # @api public
    def [](key)
      @data[key.to_s]
    end

    # @param key [String, Symbol]
    # @param value [Object] stored as `value.to_s`
    # @return [String]
    # @api public
    def []=(key, value)
      k = key.to_s
      v = value.to_s
      @changed = true unless @data[k] == v
      @data[k] = v
    end

    # @param key [String, Symbol]
    # @return [String, nil] the removed value
    # @api public
    def delete(key)
      k = key.to_s
      @changed = true if @data.key?(k)
      @data.delete(k)
    end

    # @param key [String, Symbol]
    # @return [Boolean]
    # @api public
    def key?(key)
      @data.key?(key.to_s)
    end

    # @return [Array<String>]
    # @api public
    def keys
      @data.keys
    end

    # Empties the session, the CSRF token included, so forms rendered
    # before it no longer submit (403). Use it on sign-out.
    # @api public
    def clear
      @changed = true unless @data.empty?
      @data.clear
    end

    # @return [Hash{String => String}] a copy
    # @api public
    def to_h
      @data.dup
    end

    def changed?
      @changed
    end

    CSRF_TOKEN_KEY = "_csrf_token"

    # Returns this session's CSRF token, minting and storing one the first
    # time it is asked for. Forms built with `form_with` and `button_to`
    # already carry it; send it yourself as the `X-CSRF-Token` header or an
    # `authenticity_token` parameter from JavaScript or a hand-written form.
    #
    # This is a typed instance method (rather than a
    # module method taking a Session argument) so Spinel resolves `self`
    # statically at every call site: a free function taking `session` as a
    # plain parameter widens it to an untyped poly value once it is called
    # through a real SessionStore -> Context chain, and then
    # `session[TOKEN_KEY] = token` silently does nothing
    # (tests: test/csrf_chain.rb, test/csrf_conditional.rb).
    # @return [String]
    # @api public
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
    # csrf_token! above: a module method that writes `session[FLASH_KEY] =
    # json` through a plain `session` parameter fails to stick through a real
    # SessionStore -> Middleware chain (session.changed? stays false). Flash
    # calls these instead of touching `[]`/`[]=`/`delete` on a `session`
    # parameter directly.
    def flash_payload
      self[FLASH_KEY]
    end

    def flash_payload=(json)
      self[FLASH_KEY] = json
    end

    def clear_flash!
      delete(FLASH_KEY)
    end

    ISSUED_AT_KEY = "_issued_at"

    # When this session's lifetime started, in seconds since the epoch, or
    # 0 when it has no `"_issued_at"` key (SessionStore writes it when
    # `Config#session_absolute_max_age` is on). The cookie is signed, so the
    # client cannot move it.
    # @return [Integer]
    def issued_at
      Session.epoch_seconds(@data[ISSUED_AT_KEY])
    end

    # Restarts the absolute lifetime (`Config#session_absolute_max_age`):
    # SessionStore stamps the time of this request when it writes the
    # cookie, so the session lasts the full lifetime from now. Call it at
    # sign-in (the generated `start_new_session_for` does), so that a
    # visitor who browsed for a while before signing in is not signed out
    # early.
    # @return [nil]
    # @api public
    def restart_lifetime!
      delete(ISSUED_AT_KEY)
      nil
    end

    # Whether the lifetime started at least `max_age` seconds before `now`
    # (false for a session without a start).
    def lifetime_over?(now, max_age)
      started = issued_at
      started > 0 && now >= started + max_age
    end

    # Writes `now` as the start of the lifetime unless one is recorded.
    # With `only_if_used` true, an empty session is left alone (a request
    # without a cookie gets none for this).
    def stamp_issued_at!(now, only_if_used)
      return nil if @data.key?(ISSUED_AT_KEY)
      return nil if only_if_used && @data.empty?

      self[ISSUED_AT_KEY] = now
      nil
    end

    # The Integer in an `"_issued_at"` value: 1 to 18 decimal digits (to_i
    # raises past 2**63-1 under Spinel, NOTES rule 25), else 0.
    def self.epoch_seconds(value)
      return 0 if value.nil?

      s = value.to_s # NOTES rule 62
      n = s.bytesize
      return 0 if n < 1 || n > 18

      i = 0
      while i < n
        b = s.getbyte(i)
        return 0 if b < 48 || b > 57

        i += 1
      end
      s.to_i
    end

    # cookie_value is "<base64 JSON payload>--<64 hex HMAC>". The signature
    # occupies a known-width suffix, so it is sliced off rather than located
    # by scanning for "--" -- urlsafe base64's own alphabet includes "-",
    # so the separator can legitimately recur inside the payload.
    def self.load(cookie_value, secret)
      # A fresh empty Session on each early return, not one made up front:
      # a valid cookie (nearly every request) never needs it.
      return Session.new if cookie_value.nil? || cookie_value.length < 66

      len = cookie_value.length
      sep = cookie_value[len - 66, 2]
      return Session.new unless sep == "--"

      payload = cookie_value[0, len - 66]
      signature = cookie_value[len - 64, 64]
      expected = Crypto.hmac_hex(secret, payload)
      return Session.new unless Crypto.secure_compare(signature, expected)

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
          keys = parsed.keys
          i = 0
          while i < keys.size
            data[keys[i].to_s] = parsed[keys[i]].to_s
            i += 1
          end
        end
      rescue JSON::NestingError, JSON::ParserError, StandardError
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
