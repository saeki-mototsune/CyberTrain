require "cybertrain/middleware"
require "cybertrain/content_security_policy"

module Cybertrain
  # Writes the Content Security Policy (spec C-5) on every response: the
  # controller's own policy (Controller.content_security_policy, which
  # Controller#process puts in Context#csp_policy) or else the
  # application's (Config#content_security_policy). With nonce directives
  # (Config#content_security_policy_nonce_directives) each of them gets
  # this request's Context#csp_nonce, the one `csp_meta_tag` and
  # `javascript_tag(nonce: true)` wrote into the page. The header is
  # `Content-Security-Policy`, or `Content-Security-Policy-Report-Only`
  # with Config#content_security_policy_report_only. A response that
  # already carries a header of that name (send_blob's `default-src
  # 'none'; sandbox`) keeps its own. Inside RequestLogger, so static files
  # and the health check get it too.
  class ContentSecurityPolicyHeader < Middleware
    def initialize(app, policy, report_only, nonce_directives)
      super(app)
      @policy = policy
      @header_name = report_only ? "Content-Security-Policy-Report-Only" : "Content-Security-Policy"
      @nonce_directives = nonce_directives
    end

    def call(ctx)
      # Before the app: a template rendered without a controller policy
      # sees the application's (csp_meta_tag).
      app_policy = @policy
      ctx.csp_policy = app_policy if ctx.csp_policy.nil? && !app_policy.nil?
      super
      policy = ctx.csp_policy
      return nil if policy.nil?

      response = ctx.response
      # A 304 carries no policy: the browser merges a 304's headers onto
      # its cached copy, and a fresh nonce there would block the cached
      # page's nonce'd scripts (RFC 9111 4.3.4). The cached policy stays.
      return nil if response.status == 304

      name = @header_name
      return nil unless response.header(name).nil?

      directives = @nonce_directives
      nonce = directives.empty? ? "" : ctx.csp_nonce
      value = policy.header_value(nonce, directives)
      response.set_header(name, value) unless value.empty?
      nil
    end
  end
end
