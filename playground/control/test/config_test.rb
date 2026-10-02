# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include PlayTestHelpers

  def error_for(env)
    assert_raises(Play::Config::Error) { play_config(env) }.message
  end

  def test_required_settings
    assert_equal "PLAY_PUBLIC_URL is required", error_for("PLAY_PUBLIC_URL" => "")
    assert_equal "PLAY_SESSION_IMAGE is required", error_for("PLAY_SESSION_IMAGE" => nil)
    assert_equal "PLAY_ABUSE_CONTACT is required", error_for("PLAY_ABUSE_CONTACT" => "")
  end

  def test_defaults
    c = play_config
    assert_equal [5, 1, 3, 600, 1800, 300, 30, 5], [c.max_sessions, c.max_sessions_per_ip, c.create_limit,
                                                   c.create_window, c.ttl, c.idle_timeout, c.ready_timeout,
                                                   c.reap_interval]
    assert_equal ["10.250.0.0/16", 28], [c.subnet_pool, c.subnet_prefix]
    assert_equal %w[1536m 1 256m 128m 256m 64m], [c.session_memory, c.session_cpus, c.tmpfs_tmp, c.tmpfs_home,
                                                  c.tmpfs_workspace, c.tmpfs_cache]
    assert_equal 512, c.session_pids
    assert_equal "", c.runtime
    assert_equal "http://ctplay-router", c.router_url
    assert_equal ["label=service=cybertrain-play-router", "label=role=web"], c.router_filters
    assert_nil c.client_ip_env_key
    assert_equal "https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1", c.codespaces_url
  end

  def test_numbers_are_checked
    assert_equal 'PLAY_MAX_SESSIONS must be a whole number above 0 (got "five")', error_for("PLAY_MAX_SESSIONS" => "five")
    assert_equal 'PLAY_TTL must be a whole number above 0 (got "0")', error_for("PLAY_TTL" => "0")
    assert_match(/PLAY_SESSION_MEMORY must be a size/, error_for("PLAY_SESSION_MEMORY" => "lots"))
    assert_match(/PLAY_SESSION_CPUS must be a number/, error_for("PLAY_SESSION_CPUS" => "0"))
    assert_match(/PLAY_RUNTIME must be a runtime name/, error_for("PLAY_RUNTIME" => "runsc --privileged"))
  end

  def test_idle_timeout_must_exceed_60
    assert_equal "PLAY_IDLE_TIMEOUT must be more than 60 seconds (got 60)", error_for("PLAY_IDLE_TIMEOUT" => "60")
    assert_equal 61, play_config("PLAY_IDLE_TIMEOUT" => "61").idle_timeout
  end

  def test_public_url_gives_scheme_domain_and_port
    c = play_config("PLAY_PUBLIC_URL" => "http://play.localhost:8080")
    assert_equal ["http", "play.localhost", 8080, ":8080"], [c.scheme, c.domain, c.port, c.port_suffix]
    assert_equal "http://play.localhost:8080", c.public_origin
    c = play_config("PLAY_PUBLIC_URL" => "https://Play.Example.TEST/")
    assert_equal ["https", "play.example.test", nil, ""], [c.scheme, c.domain, c.port, c.port_suffix]
    assert_match(/PLAY_PUBLIC_URL must be a scheme and a host/, error_for("PLAY_PUBLIC_URL" => "https://play.example.test/x"))
    assert_match(/PLAY_PUBLIC_URL must be a scheme and a host/, error_for("PLAY_PUBLIC_URL" => "play.example.test"))
  end

  def test_editor_url_and_proxy_uri
    sid = "0123456789abcdef0123456789abcdef"
    assert_equal "https://#{sid}.play.example.test/?folder=%2Fworkspace%2Fblog&payload=" \
                 "%5B%5B%22openFile%22%2C%22vscode-remote%3A%2F%2F#{sid}.play.example.test" \
                 "%2Fworkspace%2Fblog%2FPLAYGROUND.md%22%5D%5D", play_config.editor_url(sid)
    local = play_config("PLAY_PUBLIC_URL" => "http://play.localhost:8080")
    assert_equal "http://#{sid}.play.localhost:8080/?folder=%2Fworkspace%2Fblog&payload=" \
                 "%5B%5B%22openFile%22%2C%22vscode-remote%3A%2F%2F#{sid}.play.localhost%3A8080" \
                 "%2Fworkspace%2Fblog%2FPLAYGROUND.md%22%5D%5D", local.editor_url(sid)
    assert_equal "http://{{port}}-#{sid}.play.localhost:8080", local.proxy_uri(sid)
    assert_equal "http://*.play.localhost:8080", local.session_hosts_source
  end

  def test_allowed_origins
    assert_equal ["https://play.example.test"], play_config.allowed_origins
    c = play_config("PLAY_ALLOWED_ORIGINS" => "https://play.example.test, https://Saeki-Mototsune.github.io:443")
    assert_equal ["https://play.example.test", "https://saeki-mototsune.github.io"], c.allowed_origins
    assert_match(/PLAY_ALLOWED_ORIGINS must list origins/, error_for("PLAY_ALLOWED_ORIGINS" => "https://x.test/path"))
  end

  def test_client_ip_header
    assert_equal "HTTP_CF_CONNECTING_IP", play_config("PLAY_CLIENT_IP_HEADER" => "CF-Connecting-IP").client_ip_env_key
    assert_match(/PLAY_CLIENT_IP_HEADER must be a header name/, error_for("PLAY_CLIENT_IP_HEADER" => "X Bad"))
  end

  def test_pool_overlapping_dockers_defaults_stops_the_boot
    assert_equal "PLAY_SUBNET_POOL 172.20.0.0/16 overlaps Docker's default address pool 172.20.0.0/16",
                 error_for("PLAY_SUBNET_POOL" => "172.20.0.0/16")
  end

  def test_the_plans_own_values_pass
    %w[https://play.example.test http://play.localhost:8080 http://play.localhost:18080].each do |url|
      assert_equal url, play_config("PLAY_PUBLIC_URL" => url).public_origin
    end
    assert_equal "http://ctplay-router", play_config("PLAY_ROUTER_URL" => "http://ctplay-router").router_url
    ["cybertrain-playground-web:local",
     "ghcr.io/saeki-mototsune/cybertrain-playground-web@sha256:#{"0123456789abcdef" * 4}"].each do |image|
      assert_equal image, play_config("PLAY_SESSION_IMAGE" => image).session_image
    end
  end

  def test_the_session_image_must_be_an_image_reference
    assert_equal 'PLAY_SESSION_IMAGE must be an image reference (got "--privileged")',
                 error_for("PLAY_SESSION_IMAGE" => "--privileged")
    assert_match(/PLAY_SESSION_IMAGE must be an image reference/, error_for("PLAY_SESSION_IMAGE" => "img$(id)"))
  end

  def test_the_router_url_must_be_plain_http_with_a_host
    assert_equal 'PLAY_ROUTER_URL must be a plain http URL such as http://ctplay-router (got "https://ctplay-router")',
                 error_for("PLAY_ROUTER_URL" => "https://ctplay-router")
    assert_match(/PLAY_ROUTER_URL must be a plain http URL/, error_for("PLAY_ROUTER_URL" => "http://"))
  end

  def test_urls_and_origins_need_a_host
    assert_equal 'PLAY_CODESPACES_URL must be an http or https URL (got "https://")',
                 error_for("PLAY_CODESPACES_URL" => "https://")
    assert_match(/PLAY_ALLOWED_ORIGINS must list origins/, error_for("PLAY_ALLOWED_ORIGINS" => "https://"))
  end

  def test_the_public_host_has_only_host_name_characters
    assert_match(/PLAY_PUBLIC_URL must be a scheme and a host/, error_for("PLAY_PUBLIC_URL" => "https://a;b,c"))
    assert_match(/PLAY_PUBLIC_URL must be a scheme and a host/, error_for("PLAY_PUBLIC_URL" => "https://*.example.test"))
  end

  def test_router_filters_are_checked
    c = play_config("PLAY_ROUTER_FILTERS" => "label=service=x, name=ctplay-router")
    assert_equal ["label=service=x", "name=ctplay-router"], c.router_filters
    message = "PLAY_ROUTER_FILTERS must be docker ps filters such as label=role=web, separated by commas"
    assert_equal message, error_for("PLAY_ROUTER_FILTERS" => "label=role=web,--all")
    assert_equal message, error_for("PLAY_ROUTER_FILTERS" => " , ")
  end

  def test_a_size_cannot_carry_mount_options
    assert_match(/PLAY_TMPFS_HOME must be a size such as 256m/, error_for("PLAY_TMPFS_HOME" => "128m,exec"))
  end
end
