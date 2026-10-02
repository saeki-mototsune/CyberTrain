# frozen_string_literal: true

require "digest"
require "json"
require "rack/utils"
# Sinatra::Base takes its environment from APP_ENV (then RACK_ENV) when it
# loads, and in development gives every app a debugging route. The control
# plane runs as production wherever it runs, the tests included.
ENV["APP_ENV"] = "production"
require "sinatra/base"
require_relative "../play"

module Play
  # The entry page, POST /sessions and the small endpoints (spec §5.2,
  # §5.13). A request is read for three headers only: Origin and
  # Sec-Fetch-Site (the origin check) and PLAY_CLIENT_IP_HEADER (the
  # client); no parameter and no body (Play::Guard, in front of it, hands it
  # each request without its query string, refuses a body and puts the
  # security headers on every answer).
  class App < Sinatra::Base
    # Disables the Start button while the session starts (no double submit);
    # pageshow enables it again when the browser restores the page from its
    # back-forward cache. The page works without it.
    BUTTON_SCRIPT = 'document.querySelectorAll("form.start").forEach(function(f){var b=f.querySelector("button");' \
                    'f.addEventListener("submit",function(){b.disabled=true;b.textContent="Starting…";});' \
                    'window.addEventListener("pageshow",function(){b.disabled=false;b.textContent=b.dataset.label;});});'
    SCRIPT_SOURCE = "'sha256-#{[Digest::SHA256.digest(BUTTON_SCRIPT)].pack("m0")}'"
    SECURITY_TXT_EXPIRES = (Time.now.utc + (365 * 86_400)).strftime("%Y-%m-%dT%H:%M:%SZ")
    REFUSAL_STATUS = { paused: 503, unavailable: 503, full: 503, failed: 503, per_ip: 429, rate: 429 }.freeze

    # Rack::Protection stays off: its HttpOrigin compares Origin with the
    # request's own scheme, which is http behind the router, and would refuse
    # every POST; its FrameOptions adds X-Frame-Options, which spec §6.3 does
    # not want. The origin check below and Play::Guard's headers replace it.
    set :protection, false
    # Production whatever RACK_ENV says (see APP_ENV above), and errors stay
    # inside: no debug page, nothing raised past Play::Guard, no backtrace on
    # rack.errors (Puma's stderr). An unexpected exception is one event line
    # and the fixed 500 page (`error 500` below).
    set :environment, :production
    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, false
    set :views, File.expand_path("../../views", __dir__)

    # The control plane's Rack app for CONFIG and SESSIONS, behind
    # Play::Guard: the one way to build it (config.ru, the tests). LOG takes
    # the event line of an unexpected exception. Host names other than
    # PLAY_PUBLIC_URL's (and 127.0.0.1 and localhost, for the health check
    # and playctl) get 403.
    def self.for(config:, sessions:, log: EventLog.new($stdout))
      set :host_authorization, { permitted_hosts: [config.domain, "127.0.0.1", "localhost"] }
      Guard.new(new(config: config, sessions: sessions, log: log), headers: security_headers(config))
    end

    def initialize(app = nil, config:, sessions:, log:)
      super(app)
      @config = config
      @sessions = sessions
      @log = log
    end

    helpers do
      def h(text)
        Rack::Utils.escape_html(text.to_s)
      end

      def minutes(seconds)
        n = [(seconds / 60.0).ceil, 1].max
        n == 1 ? "1 minute" : "#{n} minutes"
      end

      # TEXT escaped and without a final period, for a sentence the page ends
      # itself: a pause message may bring its own.
      def without_period(text)
        h(text.to_s.delete_suffix("."))
      end
    end

    # The entry origin's security headers (spec §5.13, §6.3) for CONFIG.
    # Play::Guard puts them on every answer, also on those made before any
    # route runs (Sinatra's 400, the host check's 403).
    def self.security_headers(config)
      { "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; script-src #{SCRIPT_SOURCE}; " \
                                     "form-action 'self' #{config.session_hosts_source}; " \
                                     "frame-ancestors 'none'; base-uri 'none'",
        "referrer-policy" => "no-referrer",
        "x-content-type-options" => "nosniff",
        "cache-control" => "no-store" }.freeze
    end

    get "/" do
      erb :index, locals: { status: @sessions.status, closed: @sessions.closed_message }
    end

    post "/sessions" do
      unless origin_allowed?
        @sessions.note_refusal(:origin)
        status 403
        return erb(:refusal, locals: { reason: :origin, refusal: nil })
      end
      result = @sessions.create(Limits.client_key(request.env, @config.client_ip_env_key))
      redirect result.editor_url, 303 if result.is_a?(Sessions::Created)

      status REFUSAL_STATUS.fetch(result.reason)
      headers "Retry-After" => result.retry_after.to_s
      erb :refusal, locals: { reason: result.reason, refusal: result }
    end

    get "/status.json" do
      content_type :json
      JSON.generate(@sessions.status)
    end

    get "/terms" do
      erb :terms
    end

    get "/robots.txt" do
      content_type :text
      "User-agent: *\nDisallow: /sessions\n"
    end

    get "/.well-known/security.txt" do
      content_type :text
      "Contact: mailto:#{@config.abuse_contact}\nExpires: #{SECURITY_TXT_EXPIRES}\n" \
        "Policy: https://github.com/saeki-mototsune/cybertrain/blob/main/SECURITY.md\n"
    end

    get "/up" do
      content_type :text
      halt 503, "the reaper has not reached Docker within the last minute\n" unless @sessions.healthy?
      "OK"
    end

    # playctl status reads the clients from here; the router answers 404 for
    # /internal/* itself, and this route only for loopback peers.
    get "/internal/sessions" do
      halt 404, "Not Found" unless ["127.0.0.1", "::1"].include?(request.env["REMOTE_ADDR"])
      content_type :json
      JSON.generate(@sessions.internal_list)
    end

    not_found do
      content_type :text
      "Not Found\n"
    end

    # Rack's form parser can still fail on a form type without a body;
    # Sinatra's own 400 would name the reason.
    error 400 do
      content_type :text
      "Bad Request\n"
    end

    # An unexpected exception: one event line naming its class, never its
    # message or anything of the request, and the fixed page.
    error 500 do
      @log.event("error", step: "request", exception: env["sinatra.error"].class.name)
      content_type :text
      "Internal Server Error\n"
    end

    private

    # Spec §5.2: an Origin must be one of PLAY_ALLOWED_ORIGINS; without one,
    # Sec-Fetch-Site must be absent, same-origin or none (same-site is
    # refused: a visitor's own app runs on a sibling host). Origin "null"
    # counts as absent: a browser sends it for a form POST from a page served
    # with Referrer-Policy: no-referrer, which is every page here.
    def origin_allowed?
      origin = request.env["HTTP_ORIGIN"].to_s
      return @config.allowed_origins.include?(origin) unless origin.empty? || origin == "null"

      ["", "same-origin", "none"].include?(request.env["HTTP_SEC_FETCH_SITE"].to_s)
    end
  end
end
