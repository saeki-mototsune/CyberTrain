# Signing in and out (cybertrain generate authentication) through the
# full stack: the session cookie, the router, the Authentication
# concern, the CSRF check.
require "test_helper"

# after_authentication_url is private (the Authentication concern's): a
# controller made for these tests reads it.
class ReturnPathProbeController < ApplicationController
  def probe_after_authentication_url
    after_authentication_url
  end
end

class SessionsControllerTest < ActionDispatch::IntegrationTest
  # Every action but sign-in and setup needs a user: DELETE /session is
  # the one such action this test can rely on before the app has pages
  # of its own (a `root` route, a scaffold).
  test "a visitor is sent to the sign-in page" do
    delete "/session"
    assert_redirected_to "/session/new"
    assert_response :see_other
  end

  test "GET /session/new renders the sign-in form" do
    get "/session/new"
    assert_response :ok
    assert_includes response.body, "<h1>Sign in</h1>"
    assert_includes response.body, "<form action=\"/session\" method=\"post\">"
    assert_includes response.body, "name=\"email_address\""
    assert_includes response.body, "type=\"password\" name=\"password\""
    refute response.body.include?("/sign_up")
  end

  # Every form that signs in, out or resets carries the page's token
  # (Cybertrain's CSRF check, off in tests until with_forgery_protection
  # turns it on): without it, a 403 and nothing done.
  test "POST /session, PUT /passwords/:token and DELETE /session without the form's token are refused" do
    user = users(:one)
    token = user.password_reset_token
    with_forgery_protection do
      post "/session", params: { email_address: "one@example.com", password: "password" }
      assert_response :forbidden
      assert_equal 0, Session.count
      put "/passwords/#{token}", params: { password: "an0ther-s3cr3t", password_confirmation: "an0ther-s3cr3t" }
      assert_response :forbidden
      refute User.find_by_password_reset_token(token).nil?
    end
    # The sign-in form's own token is accepted.
    with_forgery_protection do
      get "/session/new"
      post "/session", params: { authenticity_token: authenticity_token_in(response.body), email_address: "one@example.com", password: "password" }
      assert_redirected_to "/"
    end
    assert_equal 1, Session.count
    with_forgery_protection do
      delete "/session"
      assert_response :forbidden
      assert_equal 1, Session.count
    end
  end

  test "POST /session signs in with the right password" do
    sign_in_as users(:one)
    assert_redirected_to "/"
    assert_response :see_other
    assert_equal 1, Session.count
    assert_equal "127.0.0.1", Session.first.ip_address
  end

  test "authentication returns to a local path once" do
    ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
    ctx.session = Cybertrain::Session.new
    controller = ReturnPathProbeController.new(ctx)
    assert_equal "/", controller.probe_after_authentication_url
    ["/", "/products", "/products/1?tab=details#title", "/products//1", "/caf%C3%A9"].each do |path|
      controller.session[:return_to_after_authenticating] = path
      assert_equal path, controller.probe_after_authentication_url
      refute controller.session.key?(:return_to_after_authenticating)
      assert_equal "/", controller.probe_after_authentication_url
    end
  end

  test "authentication rejects unsafe return destinations and consumes them" do
    ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
    ctx.session = Cybertrain::Session.new
    controller = ReturnPathProbeController.new(ctx)
    unsafe = ["", "products", "https://evil.example/", "//evil.example/", "///evil.example/",
              "/\\evil.example/", "/products\\evil", " //evil.example/", "/記事", "/" + "a" * 2048]
    (0..32).each { |byte| unsafe << "/#{Cybertrain::Test.binary([byte])}/evil.example/" }
    unsafe << "/#{Cybertrain::Test.binary([127])}/evil.example/"
    unsafe.each do |path|
      controller.session[:return_to_after_authenticating] = path
      assert_equal "/", controller.probe_after_authentication_url
      refute controller.session.key?(:return_to_after_authenticating)
    end
  end

  test "POST /session with the wrong password shows an alert" do
    post "/session", params: { email_address: "one@example.com", password: "wrong-password" }
    assert_redirected_to "/session/new"
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Try another email address or password.</p>"
    assert_equal 0, Session.count
    post "/session", params: { email_address: "nobody@example.com", password: "password" }
    assert_redirected_to "/session/new"
  end

  # SessionsController's rate_limit: ten attempts per address, then even
  # the right password goes back to the form until the window closes.
  # The counts live in Cybertrain::Cache, in windows aligned to the
  # epoch: travel_to holds the clock still, so the attempts share one
  # window, then travel moves it a whole window on. The ten go to an
  # address no user has: the limit counts per client, whatever the
  # address, and there is no account for lockout
  # (test/integration/lockout_test.rb) to lock.
  test "POST /session past ten attempts is refused for a while" do
    travel_to(Time.at(2_000_000_000)) do
      wrong_password = { email_address: "nobody@example.com", password: "wrong-password" }
      right_password = { email_address: "one@example.com", password: "password" }
      10.times { post "/session", params: wrong_password }
      post "/session", params: right_password
      assert_redirected_to "/session/new"
      assert_equal 0, Session.count
      follow_redirect!
      assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
      travel 3.minutes
      post "/session", params: right_password
      assert_redirected_to "/"
      assert_equal 1, Session.count
    end
  end

  test "DELETE /session signs out and drops the Session row" do
    sign_in_as users(:one)
    sign_out
    assert_redirected_to "/session/new"
    assert_equal 0, Session.count
    follow_redirect!
    assert_includes response.body, "<p class=\"notice\">You have been signed out.</p>"
    assert_includes response.body, "<a href=\"/session/new\">Sign in</a>"
  end

  test "a session the database no longer has signs the browser out" do
    sign_in_as users(:one)
    Session.all.delete_all
    delete "/session"
    assert_redirected_to "/session/new"
  end

  test "changing the password signs out the sessions started before" do
    user = users(:one)
    sign_in_as user
    get "/session/new"
    assert_includes response.body, "<span>one@example.com</span>"
    user.password = "another-s3cr3t"
    user.save!
    get "/session/new"
    refute response.body.include?("<span>one@example.com</span>")
    assert_equal 0, Session.count
    post "/session", params: { email_address: "one@example.com", password: "another-s3cr3t" }
    get "/session/new"
    assert_includes response.body, "<span>one@example.com</span>"
  end

  # The Session row's own limit, apart from the cookie's: signed in for
  # two minutes, then the limit lowered to one, so that a minute later
  # the cookie is still within its own two (SessionStore keeps it) and
  # only the row's check can end the sign-in. The row is saved at that
  # moment, which moves its updated_at: neither that nor a rewritten
  # cookie extends authentication (the limit counts from created_at).
  test "an expired cookie cannot restore its user or reach a protected action" do
    max_age = Cybertrain.config.session_absolute_max_age
    begin
      freeze_time
      Cybertrain.config.session_absolute_max_age = 120
      sign_in_as users(:one)
      name = Cybertrain.config.session_cookie_name
      cookie = "#{name}=#{cookies[name]}"
      get "/session/new", headers: { "cookie" => cookie }
      assert_includes response.body, "<span>one@example.com</span>"

      Cybertrain.config.session_absolute_max_age = 60
      travel 1.minute
      row = Session.first
      row.user_agent = "saved at the limit"
      row.save!
      assert_equal Time.current.to_i, Session.first.updated_at.to_i
      get "/session/new", headers: { "cookie" => cookie }
      refute response.body.include?("<span>one@example.com</span>")
      assert_equal 0, Session.count
      delete "/session", headers: { "cookie" => cookie }
      assert_redirected_to "/session/new"
      get "/session/new"
      refute response.body.include?("<span>one@example.com</span>")
      assert_includes response.body, "<a href=\"/session/new\">Sign in</a>"

      # Replaying the original credential again still fails, even
      # after the server removed its id from the browser's cookie.
      get "/session/new", headers: { "cookie" => cookie }
      refute response.body.include?("<span>one@example.com</span>")
    ensure
      Cybertrain.config.session_absolute_max_age = max_age
    end
  end

end
