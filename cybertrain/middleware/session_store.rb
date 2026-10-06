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
    def initialize(app, secret:, cookie_name: "_cybertrain_session", max_age: 1209600, secure: false,
                   same_site: "Lax", partitioned: false)
      super(app)
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
      ctx.session = Session.load(cookie_value.nil? ? "" : cookie_value, @secret)
      ctx.flash = Flash.load(ctx.session)

      result = super

      Flash.store(ctx.flash, ctx.session)
      if ctx.session.changed?
        set_cookie = Cookies.serialize(@cookie_name, Session.dump(ctx.session, @secret),
                                       max_age: @max_age, secure: @secure, same_site: @same_site,
                                       partitioned: @partitioned)
        ctx.response.add_cookie(set_cookie)
      end
      result
    end
  end
end
