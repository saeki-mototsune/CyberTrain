require "cybertrain/middleware"
require "cybertrain/crypto"
require "cybertrain/session"
require "cybertrain/http/query"

module Cybertrain
  # Verifies a per-session CSRF token on every state-changing request.
  # Requires SessionStore earlier in the chain (ctx.session must already be
  # loaded); a nil ctx.session is treated as "no token available" and fails
  # closed rather than skipping the check.
  class CsrfProtection < Middleware
    TOKEN_KEY = Session::CSRF_TOKEN_KEY
    PARAM = "authenticity_token"
    HEADER = "x-csrf-token"

    # Returns the session's CSRF token, minting and storing one the first
    # time it is asked for. Delegates to the typed Session instance method
    # -- see Session#csrf_token! for why this isn't done inline here.
    def self.token_for(session)
      session.csrf_token!
    end

    def call(ctx)
      req = ctx.request
      return super if req.get? || req.head? || req.method == "OPTIONS"

      session = ctx.session
      expected = session.nil? ? "" : session[TOKEN_KEY].to_s
      provided = token_from_request(req)

      if expected.empty? || provided.empty? || !Crypto.secure_compare(provided, expected)
        ctx.response.status = 403
        ctx.response.body = "Invalid authenticity token"
        ctx.response.performed!
        return nil
      end

      super
    end

    private

    # The Router fills ctx.params only at the very end of the chain (after
    # the Router matches a route), and this middleware sits before the
    # Router in the stack (MethodOverride -> SessionStore -> CsrfProtection
    # -> Router), so ctx.params is always empty here. Read the token the
    # way MethodOverride reads `_method`: straight out of the form body or
    # the query string, falling back to the header.
    def token_from_request(req)
      value = ""
      value = Query.parse(req.body)[PARAM].to_s if req.form?
      value = Query.parse(req.query_string)[PARAM].to_s if value.empty?
      if value.empty?
        header_value = req.header(HEADER)
        value = header_value unless header_value.nil?
      end
      value
    end
  end
end
