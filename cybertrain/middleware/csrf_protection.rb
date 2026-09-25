require "cybertrain/middleware"
require "cybertrain/crypto"

module Cybertrain
  # Verifies a per-session CSRF token on every state-changing request.
  # Requires SessionStore earlier in the chain (ctx.session must already be
  # loaded); a nil ctx.session is treated as "no token available" and fails
  # closed rather than skipping the check.
  class CsrfProtection < Middleware
    TOKEN_KEY = "_csrf_token"
    PARAM = "authenticity_token"
    HEADER = "x-csrf-token"

    # Returns the session's CSRF token, minting and storing one the first
    # time it is asked for.
    def self.token_for(session)
      token = session[TOKEN_KEY]
      if token.nil? || token.empty?
        token = Crypto.random_token
        session[TOKEN_KEY] = token
      end
      token
    end

    def call(ctx)
      req = ctx.request
      return super if req.get? || req.head? || req.method == "OPTIONS"

      session = ctx.session
      expected = session.nil? ? nil : session[TOKEN_KEY]
      provided = ctx.params[PARAM]
      provided = req.header(HEADER) if provided.nil?

      if expected.nil? || provided.nil? || !Crypto.secure_compare(provided, expected)
        ctx.response.status = 403
        ctx.response.body = "Invalid authenticity token"
        ctx.response.performed!
        return nil
      end

      super
    end
  end
end
