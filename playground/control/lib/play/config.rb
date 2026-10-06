# frozen_string_literal: true

require "json"
require "uri"

module Play
  # The control plane's settings, read once from the environment (spec
  # §5.10). Every value is checked here, so the rest of the code can trust
  # it; a missing or malformed value raises Config::Error, and config.ru
  # prints "error: <message>" and exits 1. An empty variable counts as unset.
  class Config
    class Error < StandardError; end

    DEFAULTS = {
      "PLAY_ROUTER_URL" => "http://ctplay-router",
      "PLAY_ROUTER_FILTERS" => "label=service=cybertrain-play-router,label=role=web",
      "PLAY_CLIENT_IP_HEADER" => "",
      "PLAY_MAX_SESSIONS" => "5",
      "PLAY_MAX_SESSIONS_PER_IP" => "1",
      "PLAY_CREATE_LIMIT" => "3",
      "PLAY_CREATE_WINDOW" => "600",
      "PLAY_TTL" => "1800",
      "PLAY_IDLE_TIMEOUT" => "300",
      "PLAY_READY_TIMEOUT" => "30",
      "PLAY_REAP_INTERVAL" => "5",
      "PLAY_SUBNET_POOL" => "10.250.0.0/16",
      "PLAY_SUBNET_PREFIX" => "28",
      "PLAY_SESSION_MEMORY" => "1536m",
      "PLAY_SESSION_CPUS" => "1",
      "PLAY_SESSION_PIDS" => "512",
      "PLAY_TMPFS_TMP" => "256m",
      "PLAY_TMPFS_HOME" => "128m",
      "PLAY_TMPFS_WORKSPACE" => "256m",
      "PLAY_TMPFS_CACHE" => "64m",
      "PLAY_RUNTIME" => "",
      "PLAY_DATA_DIR" => "/data",
      "PLAY_CODESPACES_URL" => "https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1"
    }.freeze
    REQUIRED = %w[PLAY_PUBLIC_URL PLAY_SESSION_IMAGE PLAY_ABUSE_CONTACT].freeze

    attr_reader :scheme, :domain, :port, :session_image, :router_url, :router_filters, :allowed_origins,
                :client_ip_header, :max_sessions, :max_sessions_per_ip, :create_limit, :create_window, :ttl,
                :idle_timeout, :ready_timeout, :reap_interval, :subnet_pool, :subnet_prefix, :session_memory,
                :session_cpus, :session_pids, :tmpfs_tmp, :tmpfs_home, :tmpfs_workspace, :tmpfs_cache, :runtime,
                :data_dir, :codespaces_url, :abuse_contact

    def self.from_env(env = ENV)
      new(env.to_h)
    end

    def initialize(env)
      @env = env
      parse_public_url(value("PLAY_PUBLIC_URL"))
      @session_image = matching("PLAY_SESSION_IMAGE", %r{\A[A-Za-z0-9][A-Za-z0-9._/:@-]*\z}, "an image reference")
      @abuse_contact = matching("PLAY_ABUSE_CONTACT", /\A[^\s@]+@[^\s@]+\z/, "an email address")
      @router_url = plain_http_url("PLAY_ROUTER_URL")
      @router_filters = value("PLAY_ROUTER_FILTERS").split(",").map(&:strip).reject(&:empty?)
      if @router_filters.empty? || @router_filters.any? { |f| !f.match?(/\A[a-z_]+=\S+\z/) }
        raise Error, "PLAY_ROUTER_FILTERS must be docker ps filters such as label=role=web, separated by commas"
      end
      @allowed_origins = parse_origins(@env["PLAY_ALLOWED_ORIGINS"].to_s)
      @client_ip_header = matching("PLAY_CLIENT_IP_HEADER", /\A[A-Za-z0-9-]*\z/, "a header name such as CF-Connecting-IP")
      @max_sessions = whole("PLAY_MAX_SESSIONS")
      @max_sessions_per_ip = whole("PLAY_MAX_SESSIONS_PER_IP")
      @create_limit = whole("PLAY_CREATE_LIMIT")
      @create_window = whole("PLAY_CREATE_WINDOW")
      @ttl = whole("PLAY_TTL")
      @idle_timeout = whole("PLAY_IDLE_TIMEOUT")
      raise Error, "PLAY_IDLE_TIMEOUT must be more than 60 seconds (got #{@idle_timeout})" if @idle_timeout <= 60

      @ready_timeout = whole("PLAY_READY_TIMEOUT")
      @reap_interval = whole("PLAY_REAP_INTERVAL")
      @subnet_pool = value("PLAY_SUBNET_POOL")
      @subnet_prefix = whole("PLAY_SUBNET_PREFIX")
      Subnets.validate!(@subnet_pool, @subnet_prefix)
      @session_memory = size("PLAY_SESSION_MEMORY")
      @session_cpus = matching("PLAY_SESSION_CPUS", /\A(?=.*[1-9])\d+(\.\d+)?\z/, "a number of CPUs such as 1 or 0.5")
      @session_pids = whole("PLAY_SESSION_PIDS")
      @tmpfs_tmp = size("PLAY_TMPFS_TMP")
      @tmpfs_home = size("PLAY_TMPFS_HOME")
      @tmpfs_workspace = size("PLAY_TMPFS_WORKSPACE")
      @tmpfs_cache = size("PLAY_TMPFS_CACHE")
      @runtime = matching("PLAY_RUNTIME", /\A([a-z][a-z0-9_.-]*)?\z/, "a runtime name such as runsc, or empty")
      @data_dir = matching("PLAY_DATA_DIR", %r{\A/\S*\z}, "an absolute path")
      @codespaces_url = http_url("PLAY_CODESPACES_URL")
    end

    # ":8080" when PLAY_PUBLIC_URL names a port, "" for the scheme's default.
    def port_suffix
      port ? ":#{port}" : ""
    end

    def public_origin
      "#{scheme}://#{domain}#{port_suffix}"
    end

    # The Rack env key of PLAY_CLIENT_IP_HEADER (nil when unset: REMOTE_ADDR).
    def client_ip_env_key
      client_ip_header.empty? ? nil : "HTTP_#{client_ip_header.upcase.tr("-", "_")}"
    end

    # The address POST /sessions redirects to (spec §5.2): the editor opens
    # the blog and its guide, as text, so that the preview opens beside it.
    def editor_url(sid)
      origin = "#{scheme}://#{sid}.#{domain}#{port_suffix}"
      guide = "vscode-remote://#{sid}.#{domain}#{port_suffix}/workspace/blog/PLAYGROUND.md"
      payload = JSON.generate([["openFile", guide]])
      "#{origin}/?folder=#{URI.encode_www_form_component("/workspace/blog")}&payload=#{URI.encode_www_form_component(payload)}"
    end

    # VSCODE_PROXY_URI of a session: where its editor opens port 3000.
    def proxy_uri(pid)
      "#{scheme}://{{port}}-#{pid}.#{domain}#{port_suffix}"
    end

    # Every session host, as a CSP source (the entry page's form-action).
    def session_hosts_source
      "#{scheme}://*.#{domain}#{port_suffix}"
    end

    private

    def value(name)
      raw = @env[name].to_s
      return raw unless raw.empty?
      raise Error, "#{name} is required" if REQUIRED.include?(name)

      DEFAULTS.fetch(name)
    end

    def matching(name, pattern, what)
      text = value(name)
      raise Error, "#{name} must be #{what} (got #{text.inspect})" unless text.match?(pattern)

      text
    end

    def whole(name)
      text = value(name)
      number = Integer(text, 10, exception: false)
      raise Error, "#{name} must be a whole number above 0 (got #{text.inspect})" unless number&.positive?

      number
    end

    def size(name)
      matching(name, /\A[1-9]\d*[kmg]\z/, "a size such as 256m")
    end

    # A page the control plane links to: an http or https URL with a host.
    def http_url(name)
      text = value(name)
      return text if url_with_host?(text, %w[http https])

      raise Error, "#{name} must be an http or https URL (got #{text.inspect})"
    end

    # The router's address: the probe speaks plain HTTP only.
    def plain_http_url(name)
      text = value(name)
      return text if url_with_host?(text, %w[http])

      raise Error, "#{name} must be a plain http URL such as http://ctplay-router (got #{text.inspect})"
    end

    def url_with_host?(text, schemes)
      uri = URI.parse(text)
      schemes.include?(uri.scheme) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end

    # The host takes host-name characters only: it reaches the session
    # host names and, through session_hosts_source, a CSP header.
    def parse_public_url(text)
      uri = URI.parse(text)
      bare = uri.is_a?(URI::HTTP) && uri.host.to_s.match?(/\A[A-Za-z0-9.-]+\z/) && uri.userinfo.nil? &&
             ["", "/"].include?(uri.path) && uri.query.nil? && uri.fragment.nil?
      raise Error, "PLAY_PUBLIC_URL must be a scheme and a host such as https://play.example (got #{text.inspect})" unless bare

      @scheme = uri.scheme
      @domain = uri.host.downcase
      @port = uri.port == uri.default_port ? nil : uri.port
    rescue URI::InvalidURIError
      raise Error, "PLAY_PUBLIC_URL must be a scheme and a host such as https://play.example (got #{text.inspect})"
    end

    def parse_origins(text)
      items = text.split(",").map(&:strip).reject(&:empty?)
      return [public_origin] if items.empty?

      items.map do |item|
        uri = URI.parse(item)
        unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty? && uri.path.empty? && uri.query.nil? && uri.userinfo.nil?
          raise Error, "PLAY_ALLOWED_ORIGINS must list origins such as https://example.org (got #{item.inspect})"
        end

        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host.downcase}#{port}"
      rescue URI::InvalidURIError
        raise Error, "PLAY_ALLOWED_ORIGINS must list origins such as https://example.org (got #{item.inspect})"
      end
    end
  end
end
