require "cybertrain/middleware"
require "cybertrain/config"
require "cybertrain/http/parser"

module Cybertrain
  # Config#force_ssl (spec C-11, plan decision 21, Rails'
  # ActionDispatch::SSL). The server speaks plain HTTP behind a
  # TLS-terminating proxy, so a request is https when it carries
  # `X-Forwarded-Proto: https`; the header is read whatever
  # Config#trusted_proxy says, so a proxy not declared trusted does not
  # loop the redirect (a client that forges the header only skips its own
  # redirect: nothing else is decided by it here). Request#base_url
  # trusts the header only from a trusted proxy, so behind a proxy also
  # set Config#trusted_proxy or #trusted_proxies, or URLs the application
  # builds (a `turbo_stream_from ws: true` URL) stay http/ws.
  #
  # - https: the app answers, and the response gets
  #   `Strict-Transport-Security: max-age=63072000; includeSubDomains`
  #   unless it set its own;
  # - http GET or HEAD of the exempt path (the health path): the app
  #   answers, without HSTS, so a load balancer may probe over http;
  # - any other http request: 301 (GET, HEAD) or 307 (the rest, which
  #   keeps the method and body) to `https://<host><path>?<query>`. The
  #   host is the request's Host checked as a host name (Config.host_name?)
  #   with a valid numeric port kept unless 80 or 443; a missing or
  #   malformed Host answers 400 "Bad Request" rather than redirect
  #   anywhere. HostAuthorization, outside this middleware when the host
  #   check is on, has already refused a Host not on the list.
  class SslRedirect < Middleware
    HSTS = "max-age=63072000; includeSubDomains"

    def initialize(app, exempt_path)
      super(app)
      @exempt_path = exempt_path
    end

    def call(ctx)
      request = ctx.request
      if SslRedirect.https?(request.header("x-forwarded-proto"))
        super
        response = ctx.response
        response.set_header("Strict-Transport-Security", HSTS) if response.header("strict-transport-security").nil?
        return nil
      end
      safe = request.get? || request.head?
      path = @exempt_path
      return super if safe && !path.empty? && request.path == path

      location = SslRedirect.https_location(request.header("host").to_s, request.path, request.query_string)
      response = ctx.response
      if location.empty?
        response.reset_to(400, "Bad Request")
      else
        response.reset_to(safe ? 301 : 307, "")
        response.redirect(location, safe ? 301 : 307)
      end
      nil
    end

    # Whether an X-Forwarded-Proto value says https: its first element
    # (the hop the client reached; a list as chained proxies append it,
    # as Rack reads it), any case, blanks around it ignored.
    # @param value [String, nil]
    # @return [Boolean]
    def self.https?(value)
      return false if value.nil?

      text = value.to_s
      comma = text.index(",")
      first = comma.nil? ? text : text[0, comma].to_s
      first.strip.downcase == "https"
    end

    # `https://<host>[:port]<path>[?query]`, or "" when the Host is not a
    # host name with an optional valid port.
    # @param authority [String] the Host header
    # @param path [String] as sent
    # @param query [String] without the `?`
    # @return [String]
    def self.https_location(authority, path, query)
      host = SslRedirect.host_part(authority)
      return "" if host.empty?

      port = SslRedirect.port_part(authority, host.bytesize)
      return "" if port == "-"

      target = path.start_with?("/") ? path : "/"
      location = +"https://"
      location << host.downcase
      location << ":" << port unless port.empty? || port == "80" || port == "443"
      location << target
      location << "?" << query unless query.empty?
      location
    end

    # The host name of `authority` without its port ("" when it is not a
    # host name): up to the `]` of an IPv6 address, else up to the last
    # `:`.
    def self.host_part(authority)
      s = authority.to_s
      host = s
      if s.start_with?("[")
        close = s.index("]")
        return "" if close.nil?

        host = s[0, close + 1].to_s
      else
        colon = s.rindex(":")
        host = s[0, colon].to_s unless colon.nil?
      end
      Config.host_name?(host) ? host : ""
    end

    # The port after the host ("" for none), or "-" when what follows the
    # host is not `:` and 1 to 5 digits up to 65535.
    def self.port_part(authority, host_size)
      s = authority.to_s
      rest_size = s.bytesize - host_size
      return "" if rest_size == 0

      rest = s.byteslice(host_size, rest_size).to_s
      return "-" unless rest.start_with?(":")

      digits = rest.byteslice(1, rest.bytesize - 1).to_s
      return "-" if digits.empty? || digits.bytesize > 5 || !HttpParser.digits?(digits) || digits.to_i > 65535

      digits
    end
  end
end
