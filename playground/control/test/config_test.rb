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
end
