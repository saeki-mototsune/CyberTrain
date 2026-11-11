require "cybertrain/crypto"
require "cybertrain/encryptor"
require "base64"
require "json"

module Cybertrain
  # A cookie-store session: a flat Hash<String,String> that round-trips
  # through an encrypted, base64-encoded cookie value. Design D8 restricts
  # values to String -- there is no marshalling format to smuggle other
  # types through, so nothing else needs to be ruled out at the type level.
  #
  # {Controller#session} in an action. Keys and values are Strings (a
  # Symbol key is its name; a value is stored as `value.to_s`, so
  # `session[:user_id] = 5` reads back as `"5"`).
  #
  # The cookie is encrypted and authenticated with AES-256-GCM (spec
  # section 5.1, as Rails' cookie store), under a key derived from
  # `secret_key_base` ({Crypto.derive_key} with the label
  # `"cybertrain session"`) and with `"session"` as the additional data:
  # the client can neither read it nor change it. A cookie that does not
  # decode, authenticate or parse (a changed, truncated or forged one, one
  # sealed for another cookie, one under another secret, a 0.4 signed
  # cookie) loads as an empty session, and so does one over 4096 bytes,
  # without being decrypted. A session whose cookie would pass 4096 bytes
  # raises {CookieOverflow} when SessionStore writes it: nothing is cut
  # short. It is sent only when the session changed, as
  # `_cybertrain_session` with `Path=/; HttpOnly; SameSite=Lax`, `Secure`
  # in production and a two-week Max-Age (the name, the Max-Age and
  # `Secure` are {Config} settings). `"_csrf_token"` and `"_flash"` are the
  # framework's keys.
  # @example
  #   session[:user_id] = user.id
  #   User.find(session[:user_id]) if session.key?(:user_id)
  #   session.delete(:user_id)
  # @api public
  class Session
    # A session too large for its cookie: SessionStore raises it, with the
    # cookie's size, instead of sending a cookie a browser would drop.
    # @api public
    class CookieOverflow < StandardError
    end

    # The most a browser keeps of one cookie, `name=value` (RFC 6265 section
    # 6.1's minimum, Rails' `CookieOverflow` limit).
    MAX_COOKIE_BYTES = 4096
    # The GCM additional data the session is sealed with.
    SEAL_PURPOSE = "session"

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
    # `Config#session_absolute_max_age` is on). The cookie is encrypted and
    # authenticated, so the client cannot move it.
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

    # The session a cookie value holds, under `key` (32 bytes,
    # `Crypto.derive_key(secret_key_base, "cybertrain session")`; SessionStore
    # derives it once). The value is urlsafe Base64, with or without
    # padding, of {Encryptor#seal_bytes} of the session's JSON with
    # `"session"` as the additional data. Anything else -- a value over
    # MAX_COOKIE_BYTES (not decrypted at all), bad Base64, bytes that do not
    # authenticate (a changed or truncated value, another key, another
    # purpose, a 0.4 `"<base64>--<hmac>"` signed cookie), a payload that is
    # not a JSON object -- is an empty Session. It never raises for the
    # cookie it is given.
    # @param cookie_value [String]
    # @param key [String] 32 raw bytes
    # @return [Session]
    def self.load(cookie_value, key)
      # A fresh empty Session on each early return, not one made up front:
      # a valid cookie (nearly every request) never needs it.
      value = cookie_value.to_s
      return Session.new if value.empty? || value.bytesize > MAX_COOKIE_BYTES

      raw = Session.decode_value(value)
      return Session.new if raw.empty?

      json = Encryptor.new(key).open_bytes(raw, SEAL_PURPOSE)
      return Session.new if json.nil?

      Session.from_json(json)
    end

    # The bytes of urlsafe Base64 (padded or not), "" when it is not.
    def self.decode_value(value)
      Base64.urlsafe_decode64(value)
    rescue ArgumentError
      ""
    end

    # The Session of an authenticated JSON payload; an empty one unless it
    # is a JSON object. JSON::ParserError is NOT a StandardError under
    # Spinel (NOTES rule 33), so it is listed explicitly, as in Flash.load.
    def self.from_json(json)
      data = {}
      begin
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

    # The cookie value of `session` under `key` (see {.load}): a fresh
    # nonce each call, so two dumps of one session differ. Without Base64's
    # `=` padding: it would be the only byte in the value Cookies.serialize
    # has to encode. Does not check the size; SessionStore does, against
    # the whole `name=value`.
    # @param session [Session]
    # @param key [String] 32 raw bytes
    # @return [String]
    def self.dump(session, key)
      json = JSON.generate(session.to_h)
      raw = Encryptor.new(key).seal_bytes(json, SEAL_PURPOSE)
      Base64.urlsafe_encode64(raw, padding: false)
    end
  end
end
