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

    # exempt_prefixes: request paths starting with one of them skip the
    # check (Config#csrf_exempt_prefixes): an API that programs call with
    # a credential of their own. The default is no exemption. The Array is
    # typed through its parameter default (NOTES rule 9), and a prefix is
    # matched against Request#path as sent, before any decoding, so a
    # percent-encoded spelling of an exempt path is still checked (fails
    # closed).
    def initialize(app, exempt_prefixes = Array.new(0) { "" })
      super(app)
      @exempt_prefixes = exempt_prefixes
    end

    # Returns the session's CSRF token, minting and storing one the first
    # time it is asked for. Delegates to the typed Session instance method
    # -- see Session#csrf_token! for why this isn't done inline here.
    def self.token_for(session)
      session.csrf_token!
    end

    def call(ctx)
      req = ctx.request
      return super if req.get? || req.head? || req.method == "OPTIONS"
      return super if exempt?(req.path)

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

    # True when path starts with one of the exempt prefixes. A while loop
    # over a typed String Array, no block (NOTES rules 32, 45); an empty
    # prefix never matches, so `[""]` does not switch the check off.
    def exempt?(path)
      prefixes = @exempt_prefixes
      i = 0
      while i < prefixes.size
        prefix = prefixes[i]
        return true if !prefix.empty? && path.start_with?(prefix)
        i += 1
      end
      false
    end

    private

    # The Router fills ctx.params only at the very end of the chain (after
    # the Router matches a route), and this middleware sits before the
    # Router in the stack (MethodOverride -> SessionStore -> CsrfProtection
    # -> Router), so ctx.params is always empty here. Read the token the
    # way MethodOverride reads `_method`: one Query.value_of_valid scan of the
    # form body, then of the query string (no parsed tree; both texts are
    # already validated by then, Request#utf8_body), falling back to the
    # header.
    def token_from_request(req)
      value = ""
      value = req.form_value(PARAM) if req.form?
      value = req.query_value(PARAM) if value.empty?
      if value.empty?
        header_value = req.header(HEADER)
        value = header_value unless header_value.nil?
      end
      value
    end
  end
end
