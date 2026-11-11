require "cybertrain/middleware"
require "cybertrain/http/parser"
require "cybertrain/logger"

module Cybertrain
  # Keeps requests on explicitly trusted hostnames, even when an attacker's
  # DNS resolves to the server's address: in development always, elsewhere
  # when `CYBERTRAIN_HOSTS` is set (Config#host_check?). A refused Host
  # answers 403 "Blocked host". A GET or HEAD of `exempt_path` (the health
  # path) passes whatever the Host, so a load balancer probing by IP still
  # reaches HealthCheck; every other path and method is checked.
  class HostAuthorization < Middleware
    def initialize(app, allowed_hosts, exempt_path = "")
      super(app)
      @allowed_hosts = allowed_hosts
      @exempt_path = exempt_path
    end

    def call(ctx)
      request = ctx.request
      return super if allowed?(request.header("host"))
      return super if exempt?(request)

      # One line so a CYBERTRAIN_HOSTS typo shows (Rails logs blocked
      # hosts too); inspect escapes whatever bytes the client sent.
      Cybertrain.logger.warn("Blocked host: #{request.header("host").to_s.inspect} for #{request.path.inspect}")
      ctx.response.reset_to(403, "Blocked host")
      nil
    end

    # Whether the request is a probe of the exempt path.
    def exempt?(request)
      path = @exempt_path
      !path.empty? && request.path == path && (request.get? || request.head?)
    end

    # Compare the whole authority, allowing only a numeric port after an
    # exact hostname (IPv6 entries include brackets). Do not resolve DNS or
    # trust Forwarded / X-Forwarded-Host supplied by the client.
    def allowed?(value)
      authority = value.to_s.downcase
      return false if authority.empty?

      hosts = @allowed_hosts
      i = 0
      while i < hosts.size
        name = hosts[i].downcase
        unless name.empty?
          return true if authority == name
          if authority.start_with?("#{name}:")
            port = authority[name.size + 1, authority.size - name.size - 1]
            return true if port.size <= 5 && HttpParser.digits?(port) && port.to_i <= 65535
          end
        end
        i += 1
      end
      false
    end
  end
end
