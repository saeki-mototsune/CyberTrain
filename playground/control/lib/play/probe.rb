# frozen_string_literal: true

require "net/http"
require "uri"

module Play
  # The readiness check of a new session (spec §5.7): GET /healthz through
  # the router with the editor's Host. A 200 whose body names a "status"
  # means the router is attached, Docker's DNS knows the alias and
  # code-server answers. code-server's /healthz does not count as activity,
  # so the check does not hold off its idle timeout.
  class Probe
    def initialize(config, timeout: 2)
      @uri = URI.join(config.router_url, "/healthz")
      @domain = config.domain
      @timeout = timeout
    end

    def ready?(sid)
      http = Net::HTTP.new(@uri.host, @uri.port, nil)
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout
      response = http.request(Net::HTTP::Get.new(@uri.request_uri, "Host" => "#{sid}.#{@domain}"))
      response.code == "200" && response.body.to_s.include?('"status"')
    rescue StandardError
      false
    end
  end
end
