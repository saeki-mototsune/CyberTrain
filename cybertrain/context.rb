require "cybertrain/http/request"
require "cybertrain/http/response"
require "cybertrain/params"
require "cybertrain/content_security_policy"
require "base64"
require "securerandom"

module Cybertrain
  # Everything one request carries through the middleware stack, the router
  # and the controller. The Response is created here and written back to the
  # socket by the Server once the stack returns.
  class Context
    attr_reader :request, :response
    attr_accessor :params, :route_params, :route_name
    attr_accessor :session, :flash   # set by SessionStore; nil when the middleware is absent
    # The request's cookies (CookieJar), set by SessionStore; nil without it
    # (Controller#cookies then builds one over the Cookie header).
    attr_accessor :cookie_jar
    # The Content Security Policy for this response: the controller's own
    # (Controller.content_security_policy) or the application's, set by
    # ContentSecurityPolicyHeader and Controller#process; nil without one.
    attr_accessor :csp_policy
    # The controller and action that answered, `"ArticlesController#show"`
    # (Controller#run_action sets it); `""` when no action ran.
    attr_accessor :controller_action
    # Whether the exception this request raised has been reported: the
    # RequestId that reported it sets it, and a RequestId further out does
    # not report it again. ErrorPages does not set it: the exception it
    # reports goes no further, so only a new exception (one its page
    # raises) can reach a RequestId, which reports that one too.
    attr_accessor :error_reported

    def initialize(request)
      @request = request
      @response = Response.new
      @params = Params.new
      @route_params = {}
      @route_name = ""
      @session = nil
      @flash = nil
      @cookie_jar = nil
      @csp_policy = nil
      @csp_nonce = ""
      @controller_action = ""
      @error_reported = false
    end

    # This request's CSP nonce: 16 bytes from SecureRandom, strict Base64,
    # made on first use and the same for the rest of the request (the
    # header and every `csp_meta_tag` / `javascript_tag(nonce: true)` of
    # the page). A Context is one request: never shared or reused.
    # @return [String]
    # @api public
    def csp_nonce
      nonce = @csp_nonce
      if nonce.empty?
        nonce = Base64.strict_encode64(SecureRandom.random_bytes(16))
        @csp_nonce = nonce
      end
      nonce
    end
  end
end
