require "cybertrain/middleware"
require "cybertrain/session"
require "cybertrain/flash"
require "cybertrain/http/cookies"
require "cybertrain/crypto"
require "cybertrain/cookie_jar"

module Cybertrain
  # Loads the session (and the flash riding inside it) from the request's
  # cookie before the rest of the chain runs, and writes it back out as a
  # Set-Cookie afterward -- but only when something actually changed, so an
  # ordinary read-only request does not churn the cookie on every hit.
  #
  # The session cookie is AES-256-GCM under a key derived from `secret:`
  # (Session.load / Session.dump); the keys of the session and of
  # `cookies.signed` and `cookies.encrypted` are derived once, here, each
  # with its own label (Crypto.derive_key), and the secret itself is not
  # kept. It also builds the request's cookie jar (Context#cookie_jar,
  # Controller#cookies) over the cookies it parses anyway. A session whose
  # cookie, `name=value`, would pass 4096 bytes raises
  # Session::CookieOverflow instead of being written.
  class SessionStore < Middleware
    # secure: true adds the Secure attribute, so browsers only send the
    # cookie back over HTTPS (Application passes Config#secure_cookies?:
    # session_secure, on in production, or force_ssl).
    # same_site is the SameSite value, "Lax", "Strict" or "None"
    # (Config#session_same_site); partitioned adds Partitioned (CHIPS,
    # Config#session_partitioned). "None" with Partitioned keeps the session
    # working inside another site's frame, such as an editor's preview; both
    # add Secure too (Cookies.serialize).
    #
    # absolute_max_age (Config#session_absolute_max_age; 0, the default
    # here, turns it off) bounds a session's whole life: the cookie
    # records when it was first written (Session#issued_at), a cookie
    # older than that many seconds loads as an empty session however
    # recently it was used, and the Max-Age sent never reaches past that
    # end. A cookie from before the setting was on gets its start stamped
    # on its first request.
    #
    # A session stamped with Session#stamp_lifetime! (generated sign-in,
    # "remember me") uses its own lifetime in place of absolute_max_age,
    # both when it is loaded and when it is written, and the start is
    # recorded even with absolute_max_age 0. Its cookie's Max-Age is the
    # time left of that lifetime, not capped by max_age, or there is no
    # Max-Age and no Expires at all for a browser session
    # (Session#browser_session?). The write reads the session as the
    # action left it, so a stamp or restart made during this request
    # applies to this request's cookie.
    def initialize(app, secret:, cookie_name: "_cybertrain_session", max_age: 1209600, secure: false,
                   same_site: "Lax", partitioned: false, absolute_max_age: 0)
      super(app)
      @absolute_max_age = absolute_max_age
      @session_key = Crypto.derive_key(secret, SESSION_KEY_LABEL)
      @signed_key = Crypto.derive_key(secret, CookieJar::SIGNED_KEY_LABEL)
      @encrypted_key = Crypto.derive_key(secret, CookieJar::ENCRYPTED_KEY_LABEL)
      @cookie_name = cookie_name
      @max_age = max_age
      @secure = secure
      @same_site = same_site
      @partitioned = partitioned
    end

    # The label of the session key (Crypto.derive_key).
    SESSION_KEY_LABEL = "cybertrain session"

    def call(ctx)
      cookies = Cookies.parse(ctx.request.cookie_header)
      ctx.cookie_jar = CookieJar.new(cookies, ctx.response, signed_key: @signed_key,
                                                            encrypted_key: @encrypted_key, secure: @secure)
      cookie_value = cookies[@cookie_name]
      loaded = Session.load(cookie_value.nil? ? "" : cookie_value, @session_key)
      # The cookie's own lifetime (Session#stamp_lifetime!) replaces the
      # absolute limit; the cookie is authenticated, so the client cannot
      # change it.
      stamped = loaded.lifetime_limit
      lifetime = stamped > 0 ? stamped : @absolute_max_age
      now = lifetime > 0 ? current_time : 0
      if lifetime > 0
        if loaded.lifetime_over?(now, lifetime)
          loaded = Session.new
        else
          loaded.stamp_issued_at!(now, true)
        end
      end
      ctx.session = loaded
      ctx.flash = Flash.load(ctx.session)

      result = super

      Flash.store(ctx.flash, ctx.session)
      if ctx.session.changed?
        # The action may have restarted or stamped the lifetime, so the
        # write reads the stamp of the session as it is now, not of the
        # one loaded.
        session = ctx.session
        stamped = session.lifetime_limit
        lifetime = stamped > 0 ? stamped : @absolute_max_age
        max_age = @max_age
        if lifetime > 0
          now = current_time if now == 0
          session.stamp_issued_at!(now, false)
          left = session.issued_at + lifetime - now
          left = 0 if left < 0
          if stamped > 0
            # "Remember me": the time left, even past max_age.
            max_age = left
          elsif left < max_age
            max_age = left
          end
        end
        # "Remember me" unchecked: no Max-Age, no Expires.
        max_age = -1 if session.browser_session?
        value = Session.dump(ctx.session, @session_key)
        size = @cookie_name.bytesize + 1 + value.bytesize
        if size > Session::MAX_COOKIE_BYTES
          message = "session cookie is #{size} bytes, over the 4096 a browser keeps (store less in the session)"
          raise Session::CookieOverflow, message
        end

        set_cookie = Cookies.serialize(@cookie_name, value,
                                       max_age: max_age, secure: @secure, same_site: @same_site,
                                       partitioned: @partitioned)
        ctx.response.add_cookie(set_cookie)
      end
      result
    end

    # The clock the absolute lifetime is measured with, in epoch seconds:
    # {Clock.now}, so a test moves it with `travel_to` / `travel`.
    def current_time
      Clock.now.to_i
    end
  end
end
