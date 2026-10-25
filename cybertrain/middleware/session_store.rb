require "cybertrain/middleware"
require "cybertrain/session"
require "cybertrain/flash"
require "cybertrain/http/cookies"

module Cybertrain
  # Loads the session (and the flash riding inside it) from the request's
  # cookie before the rest of the chain runs, and writes it back out as a
  # Set-Cookie afterward -- but only when something actually changed, so an
  # ordinary read-only request does not churn the cookie on every hit.
  class SessionStore < Middleware
    # secure: true adds the Secure attribute, so browsers only send the
    # cookie back over HTTPS (Config#session_secure: on in production).
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
    def initialize(app, secret:, cookie_name: "_cybertrain_session", max_age: 1209600, secure: false,
                   same_site: "Lax", partitioned: false, absolute_max_age: 0)
      super(app)
      @absolute_max_age = absolute_max_age
      # 0: the clock is Time.now. Tests set a fixed time with fixed_now=.
      @fixed_now = 0
      @secret = secret
      @cookie_name = cookie_name
      @max_age = max_age
      @secure = secure
      @same_site = same_site
      @partitioned = partitioned
    end

    def call(ctx)
      cookies = Cookies.parse(ctx.request.cookie_header)
      cookie_value = cookies[@cookie_name]
      loaded = Session.load(cookie_value.nil? ? "" : cookie_value, @secret)
      lifetime = @absolute_max_age
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
        max_age = @max_age
        if lifetime > 0
          ctx.session.stamp_issued_at!(now, false)
          left = ctx.session.issued_at + lifetime - now
          max_age = left if left < max_age
        end
        set_cookie = Cookies.serialize(@cookie_name, Session.dump(ctx.session, @secret),
                                       max_age: max_age, secure: @secure, same_site: @same_site,
                                       partitioned: @partitioned)
        ctx.response.add_cookie(set_cookie)
      end
      result
    end

    # Pins the clock the absolute lifetime is measured with to `seconds`
    # since the epoch (0 goes back to Time.now), for tests.
    def fixed_now=(seconds)
      @fixed_now = seconds
    end

    def current_time
      fixed = @fixed_now
      fixed > 0 ? fixed : Time.now.to_i
    end
  end
end
