# frozen_string_literal: true

require_relative "test_helper"
require "rack/test"
require "play/app"

class AppTest < Minitest::Test
  include PlayTestHelpers
  include Rack::Test::Methods

  SITE = "https://saeki-mototsune.github.io"

  def config
    @config ||= play_config("PLAY_ALLOWED_ORIGINS" => "https://play.example.test,#{SITE}",
                            "PLAY_CLIENT_IP_HEADER" => "CF-Connecting-IP")
  end

  def fake
    @fake ||= FakeSessions.new(config)
  end

  # The stack config.ru builds: Play::Guard in front of the app.
  def app
    Play::Guard.new(Play::App.for(config: config, sessions: fake), headers: Play::App.security_headers(config))
  end

  def setup
    header "Host", "play.example.test"
  end

  def start(headers = {})
    post "/sessions", {}, { "HTTP_CF_CONNECTING_IP" => "203.0.113.7" }.merge(headers)
  end

  def refusal(reason, retry_after, message: nil, ends_at: nil)
    Play::Sessions::Refusal.new(reason, retry_after, message, ends_at)
  end

  # The four headers test_every_page_carries_the_security_headers pins for
  # the entry page, on the last response.
  def assert_entry_headers(what)
    script = "'sha256-#{[Digest::SHA256.digest(Play::App::BUTTON_SCRIPT)].pack("m0")}'"
    expected = { "content-security-policy" => "default-src 'none'; style-src 'unsafe-inline'; script-src #{script}; " \
                                              "form-action 'self' https://*.play.example.test; frame-ancestors 'none'; " \
                                              "base-uri 'none'",
                 "referrer-policy" => "no-referrer", "x-content-type-options" => "nosniff", "cache-control" => "no-store" }
    assert_equal expected, last_response.headers.to_h.slice(*expected.keys), what
  end

  # ---- the entry page ---------------------------------------------------------

  def test_entry_page_shows_the_free_sessions_and_the_button
    get "/"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Try cybertrain in your browser, no account"
    assert_includes last_response.body, "3 of 5 sessions are free."
    assert_includes last_response.body, "Lasts: 30 minutes, then the session is deleted with its files"
    assert_includes last_response.body, '<form class="start" method="post" action="/sessions">'
    assert_includes last_response.body, "<script>#{Play::App::BUTTON_SCRIPT}</script>"
    assert_includes last_response.body, "mailto:abuse@example.test"
  end

  def test_entry_page_when_full_or_paused
    fake.status_value = fake.status_value.merge(live: 5, accepting: false)
    get "/"
    assert_includes last_response.body, "All 5 sessions are in use: try again in a few minutes."
    fake.closed = "Maintenance"
    get "/"
    assert_includes last_response.body, "The playground is paused. Maintenance. Try again later"
    refute_includes last_response.body, "<form"
  end

  # The pages end the operator's sentence themselves.
  def test_a_pause_message_with_its_own_period_is_not_doubled
    fake.closed = "Back at 14:00 UTC."
    get "/"
    assert_includes last_response.body, "The playground is paused. Back at 14:00 UTC. Try again later"
    refute_includes last_response.body, "UTC.."
    fake.result = refusal(:paused, 300, message: "Back at 14:00 UTC.")
    start("HTTP_ORIGIN" => "https://play.example.test")
    assert_includes last_response.body, "<p>Back at 14:00 UTC. Try again later, or use"
    refute_includes last_response.body, "UTC.."
  end

  def test_every_page_carries_the_security_headers
    get "/"
    script = "'sha256-#{[Digest::SHA256.digest(Play::App::BUTTON_SCRIPT)].pack("m0")}'"
    assert_equal "default-src 'none'; style-src 'unsafe-inline'; script-src #{script}; " \
                 "form-action 'self' https://*.play.example.test; frame-ancestors 'none'; base-uri 'none'",
                 last_response.headers["Content-Security-Policy"]
    assert_equal "no-referrer", last_response.headers["Referrer-Policy"]
    assert_equal "nosniff", last_response.headers["X-Content-Type-Options"]
    assert_equal "no-store", last_response.headers["Cache-Control"]
    assert_nil last_response.headers["X-Frame-Options"]
    assert_nil last_response.headers["X-XSS-Protection"]
  end

  # ---- POST /sessions ---------------------------------------------------------

  def test_start_redirects_to_the_editor
    start("HTTP_ORIGIN" => "https://play.example.test", "HTTP_SEC_FETCH_SITE" => "same-origin")
    assert_equal 303, last_response.status
    assert_equal fake.result.editor_url, last_response.headers["Location"]
    assert_equal "no-store", last_response.headers["Cache-Control"]
    assert_equal ["203.0.113.7"], fake.clients
  end

  def test_the_sites_button_may_start_a_session
    start("HTTP_ORIGIN" => SITE, "HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_equal 303, last_response.status
  end

  # The entry page is served with Referrer-Policy: no-referrer, so a browser
  # sends its form POST with Origin: null (Fetch, "append a request Origin
  # header"); Sec-Fetch-Site tells whether it came from this origin.
  def test_the_entry_pages_own_button_sends_origin_null_and_is_let_through
    start("HTTP_ORIGIN" => "null", "HTTP_SEC_FETCH_SITE" => "same-origin")
    assert_equal 303, last_response.status
    start("HTTP_ORIGIN" => "null", "HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_equal 403, last_response.status
  end

  def test_another_origin_is_refused_without_creating_anything
    start("HTTP_ORIGIN" => "https://evil.example", "HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_equal 403, last_response.status
    assert_includes last_response.body, "Start a session from play.example.test"
    assert_includes last_response.body, 'href="https://play.example.test/"'
    assert_empty fake.clients
    assert_equal [:origin], fake.refusals
  end

  def test_a_sibling_host_is_refused
    start("HTTP_SEC_FETCH_SITE" => "same-site")
    assert_equal 403, last_response.status
    start("HTTP_ORIGIN" => "https://3000-#{"f" * 32}.play.example.test", "HTTP_SEC_FETCH_SITE" => "same-site")
    assert_equal 403, last_response.status
  end

  def test_neither_origin_nor_fetch_metadata_is_let_through
    start
    assert_equal 303, last_response.status
  end

  def test_without_the_client_header_everyone_shares_the_peer_address
    post "/sessions", {}, { "REMOTE_ADDR" => "172.18.0.9" }
    assert_equal ["172.18.0.9"], fake.clients
  end

  def test_refusal_pages_and_retry_after
    ends_at = Time.utc(2027, 1, 2, 14, 32).to_i
    {
      refusal(:full, 60) => [503, "60", "All 5 playground sessions are in use right now."],
      refusal(:per_ip, 1740, ends_at: ends_at) => [429, "1740", "at the latest it ends at 14:32 UTC."],
      refusal(:rate, 500) => [429, "500", "Try again in 9 minutes."],
      refusal(:paused, 300, message: "Maintenance") => [503, "300", "Maintenance. Try again later, or use"],
      refusal(:unavailable, 300, message: "It is starting up") => [503, "300", "It is starting up. Try again later"],
      refusal(:failed, 60) => [503, "60", "Something went wrong on our side. Try again in a minute."]
    }.each do |result, (status, retry_after, text)|
      fake.result = result
      start("HTTP_ORIGIN" => "https://play.example.test")
      assert_equal status, last_response.status, result.reason
      assert_equal retry_after, last_response.headers["Retry-After"], result.reason
      assert_includes last_response.body, text, result.reason
      assert_equal "no-store", last_response.headers["Cache-Control"]
    end
  end

  # ---- the small endpoints ----------------------------------------------------

  def test_status_json
    get "/status.json"
    assert_equal 200, last_response.status
    assert_equal '{"accepting":true,"paused":false,"live":2,"capacity":5,"ttl_seconds":1800}', last_response.body
    assert_match %r{\Aapplication/json}, last_response.headers["Content-Type"]
    assert_equal "no-store", last_response.headers["Cache-Control"]
  end

  def test_up_follows_the_reaper
    header "Host", "127.0.0.1:9292"
    get "/up"
    assert_equal [200, "OK"], [last_response.status, last_response.body]
    fake.healthy = false
    get "/up"
    assert_equal 503, last_response.status
  end

  def test_internal_sessions_only_for_loopback
    fake.internal = [{ handle: "1f2e3d4c5b6a7980", client: "203.0.113.7" }]
    header "Host", "127.0.0.1:9292"
    get "/internal/sessions"
    assert_equal 200, last_response.status
    assert_equal '[{"handle":"1f2e3d4c5b6a7980","client":"203.0.113.7"}]', last_response.body
    get "/internal/sessions", {}, { "REMOTE_ADDR" => "172.18.0.4" }
    assert_equal 404, last_response.status
  end

  def test_other_host_names_are_refused
    header "Host", "3000-#{"f" * 32}.play.example.test"
    get "/"
    assert_equal 403, last_response.status
    header "Host", "play.example.test"
    get "/", {}, { "HTTP_X_FORWARDED_HOST" => "evil.example" }
    assert_equal 403, last_response.status
  end

  # ---- every answer (Play::Guard) ------------------------------------------------

  # No route takes a body, and Rack would parse a form body before any route
  # ran (a multipart one into a temp file). Puma passes a chunked body with
  # its decoded length; another server may pass only Transfer-Encoding.
  def test_a_post_with_a_body_is_refused_and_creates_nothing
    multipart = "--x\r\nContent-Disposition: form-data; name=\"f\"; filename=\"f.bin\"\r\n\r\nhello\r\n--x--\r\n"
    {
      "urlencoded" => ["a=1", { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }],
      "multipart" => [multipart, { "CONTENT_TYPE" => "multipart/form-data; boundary=x" }],
      "chunked" => ["a=1", { "CONTENT_TYPE" => "application/x-www-form-urlencoded", "CONTENT_LENGTH" => "0",
                             "HTTP_TRANSFER_ENCODING" => "chunked" }]
    }.each do |kind, (body, env)|
      post "/sessions", body, { "HTTP_ORIGIN" => "https://play.example.test", "HTTP_CF_CONNECTING_IP" => "203.0.113.7" }.merge(env)
      assert_equal [413, "No request body is accepted.\n"], [last_response.status, last_response.body], kind
      assert_entry_headers kind
    end
    assert_empty fake.clients
  end

  # A browser's form POST from the entry page has no fields: Content-Length: 0.
  def test_an_empty_post_still_starts_a_session
    start("HTTP_ORIGIN" => "https://play.example.test", "CONTENT_TYPE" => "application/x-www-form-urlencoded")
    assert_equal "0", last_request.env["CONTENT_LENGTH"]
    assert_equal 303, last_response.status
    assert_equal ["203.0.113.7"], fake.clients
  end

  def test_a_get_with_a_body_is_refused
    get "/", {}, { input: "a=1", "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    assert_equal 413, last_response.status
  end

  # Sinatra parses the query before any route or filter runs, and its 400
  # would quote it.
  def test_an_unparsable_query_gets_a_fixed_400_with_the_headers
    get "/", {}, { "QUERY_STRING" => "%zz<b>hi</b>" }
    assert_equal [400, "Bad Request\n"], [last_response.status, last_response.body]
    refute_match(/zz|hi/, last_response.body)
    assert_entry_headers "400"
  end

  def test_a_foreign_host_gets_403_with_the_headers
    header "Host", "evil.example"
    get "/"
    assert_equal [403, "Host not permitted"], [last_response.status, last_response.body]
    assert_entry_headers "403"
  end

  def test_an_unexpected_exception_gets_a_fixed_500_with_the_headers
    fake.define_singleton_method(:create) { |_client| raise "docker exploded at 0123456789abcdef" }
    start("HTTP_ORIGIN" => "https://play.example.test")
    assert_equal [500, "<h1>Internal Server Error</h1>"], [last_response.status, last_response.body]
    assert_entry_headers "500"
  end

  def test_the_small_answers_carry_the_headers_too
    get "/nothing-here"
    assert_equal [404, "Not Found\n"], [last_response.status, last_response.body]
    assert_entry_headers "404"
    %w[/status.json /robots.txt /.well-known/security.txt /terms].each do |path|
      get path
      assert_entry_headers path
    end
    header "Host", "127.0.0.1:9292"
    get "/up"
    assert_entry_headers "/up 200"
    fake.healthy = false
    get "/up"
    assert_entry_headers "/up 503"
  end

  # Play::Guard adds the headers the routes used to set, and nothing else.
  def test_the_redirect_and_the_pages_keep_their_headers
    start("HTTP_ORIGIN" => "https://play.example.test")
    assert_equal %w[cache-control content-length content-security-policy content-type location referrer-policy
                    x-content-type-options], last_response.headers.keys.sort
    assert_entry_headers "303"
    get "/"
    assert_equal %w[cache-control content-length content-security-policy content-type referrer-policy
                    x-content-type-options], last_response.headers.keys.sort
    fake.result = refusal(:full, 60)
    start("HTTP_ORIGIN" => "https://play.example.test")
    assert_equal %w[cache-control content-length content-security-policy content-type referrer-policy retry-after
                    x-content-type-options], last_response.headers.keys.sort
    assert_entry_headers "503"
  end

  def test_terms_robots_and_security_txt
    get "/terms"
    assert_includes last_response.body, "Your browser asks no extension marketplace."
    assert_includes last_response.body, "abuse@example.test"
    get "/robots.txt"
    assert_equal "User-agent: *\nDisallow: /sessions\n", last_response.body
    get "/.well-known/security.txt"
    assert_match %r{\AContact: mailto:abuse@example.test\nExpires: \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\n}, last_response.body
    assert_includes last_response.body, "Policy: https://github.com/saeki-mototsune/cybertrain/blob/main/SECURITY.md\n"
  end
end
