require "cybertrain/middleware"
require "cybertrain/http/parser"

module Cybertrain
  # Keeps development requests on explicitly trusted hostnames, even when
  # an attacker's DNS resolves to the server's loopback listening address.
  class HostAuthorization < Middleware
    def initialize(app, allowed_hosts)
      super(app)
      @allowed_hosts = allowed_hosts
    end

    def call(ctx)
      return super if allowed?(ctx.request.header("host"))

      ctx.response.reset_to(403, "Blocked host")
      nil
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
