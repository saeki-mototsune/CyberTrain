# Sign-up, sign-in and sign-out through the full stack (session cookie,
# CSRF, method override, router). Run with `cybertrain spin test`; its
# snapshot comes from the compiled binary (the database is FFI):
# `script/regen-snapshot`-style.
require_relative "support/app_test"

def new_client
  Session.all.delete_all
  User.all.delete_all
  Cybertrain::Test::Client.new(APP)
end

# Every action but sign-in and sign-up needs a user: DELETE /session is
# the one such action this test can rely on before the app has pages
# of its own (a `root` route, a scaffold).
test "a visitor is sent to the sign-in page" do
  client = new_client
  client.get("/session/new")
  res = client.post("/session", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
  assert_redirected_to res, "/session/new"
  assert_response res, :see_other
end

test "GET /session/new renders the sign-in form" do
  client = new_client
  res = client.get("/session/new")
  assert_response res, :ok
  assert_includes res.body, "<h1>Sign in</h1>"
  assert_includes res.body, "<form action=\"/session\" method=\"post\">"
  assert_includes res.body, "name=\"email_address\""
  assert_includes res.body, "type=\"password\" name=\"password\""
  assert_includes res.body, "<a href=\"/sign_up\">Sign up</a>"
end

test "POST /sign_up creates the user and signs them in" do
  client = new_client
  client.get("/sign_up")
  res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                  "user[email_address]" => " Ann@Example.com ",
                                  "user[password]" => "s3cr3t-s3cr3t",
                                  "user[password_confirmation]" => "s3cr3t-s3cr3t" })
  assert_redirected_to res, "/"
  assert_equal 1, User.count
  assert_equal "ann@example.com", User.first.email_address
  assert User.first.password_digest.start_with?("$pbkdf2-sha256$")
  assert_equal 1, Session.count
  res = client.get("/session/new")
  assert_includes res.body, "<span>ann@example.com</span>"
  assert_includes res.body, "Sign out"
end

test "POST /sign_up with a short or mismatched password re-renders the form" do
  client = new_client
  client.get("/sign_up")
  res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                  "user[email_address]" => "ann@example.com",
                                  "user[password]" => "short",
                                  "user[password_confirmation]" => "other" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Password is too short (minimum is 8 characters)</li>"
  assert_includes res.body, "<li>Password confirmation doesn&#39;t match Password</li>"
  assert_equal 0, User.count
  res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                  "user[email_address]" => "ann@example.com",
                                  "user[password]" => "",
                                  "user[password_confirmation]" => "" })
  assert_includes res.body, "<li>Password can&#39;t be blank</li>"
end

test "an email address can be registered once" do
  client = new_client
  AppTest.user("ann@example.com")
  client.get("/sign_up")
  res = client.post("/sign_up", { "authenticity_token" => AppTest.form_token(client),
                                  "user[email_address]" => "ANN@example.com",
                                  "user[password]" => "another-one",
                                  "user[password_confirmation]" => "another-one" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Email address has already been taken</li>"
  assert_equal 1, User.count
end

test "POST /session signs in with the right password" do
  client = new_client
  AppTest.user
  res = AppTest.sign_in(client)
  assert_redirected_to res, "/"
  assert_response res, :see_other
  assert_equal 1, Session.count
  assert_equal "127.0.0.1", Session.first.ip_address
end

test "authentication returns to a local path once" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
  ctx.session = Cybertrain::Session.new
  controller = ApplicationController.new(ctx)
  assert_equal "/", controller.after_authentication_url
  ["/", "/products", "/products/1?tab=details#title", "/products//1", "/caf%C3%A9"].each do |path|
    controller.session[:return_to_after_authenticating] = path
    assert_equal path, controller.after_authentication_url
    refute controller.session.key?(:return_to_after_authenticating)
    assert_equal "/", controller.after_authentication_url
  end
end

test "authentication rejects unsafe return destinations and consumes them" do
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/", {}, ""))
  ctx.session = Cybertrain::Session.new
  controller = ApplicationController.new(ctx)
  unsafe = ["", "products", "https://evil.example/", "//evil.example/", "///evil.example/",
            "/\\evil.example/", "/products\\evil", " //evil.example/", "/記事", "/" + "a" * 2048]
  (0..32).each { |byte| unsafe << "/#{Cybertrain::Test.binary([byte])}/evil.example/" }
  unsafe << "/#{Cybertrain::Test.binary([127])}/evil.example/"
  unsafe.each do |path|
    controller.session[:return_to_after_authenticating] = path
    assert_equal "/", controller.after_authentication_url
    refute controller.session.key?(:return_to_after_authenticating)
  end
end

test "POST /session with the wrong password shows an alert" do
  client = new_client
  AppTest.user
  res = AppTest.sign_in(client, "ann@example.com", "wrong-password")
  assert_redirected_to res, "/session/new"
  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"alert\">Try another email address or password.</p>"
  assert_equal 0, Session.count
  res = AppTest.sign_in(client, "nobody@example.com", "s3cr3t-s3cr3t")
  assert_redirected_to res, "/session/new"
end

# SessionsController's rate_limit: ten attempts per address, then even
# the right password goes back to the form until the window closes.
test "POST /session past ten attempts is refused for a while" do
  client = new_client
  AppTest.user
  Cybertrain::RateLimit.reset_all!
  client.get("/session/new")
  wrong_password = { "authenticity_token" => AppTest.form_token(client),
                     "email_address" => "ann@example.com", "password" => "wrong-password" }
  right_password = { "authenticity_token" => AppTest.form_token(client),
                     "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" }
  10.times { client.post("/session", wrong_password) }
  res = client.post("/session", right_password)
  assert_redirected_to res, "/session/new"
  assert_equal 0, Session.count
  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"alert\">Try again later.</p>"
  Cybertrain::RateLimit.current_time = Time.now.to_i + 3 * 60
  res = client.post("/session", right_password)
  Cybertrain::RateLimit.current_time = -1
  assert_redirected_to res, "/"
  assert_equal 1, Session.count
end

test "DELETE /session signs out and drops the Session row" do
  client = new_client
  AppTest.user
  AppTest.sign_in(client)
  client.get("/session/new")
  res = client.post("/session", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
  assert_redirected_to res, "/session/new"
  assert_equal 0, Session.count
  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"notice\">You have been signed out.</p>"
  assert_includes res.body, "<a href=\"/session/new\">Sign in</a>"
end

test "a session the database no longer has signs the browser out" do
  client = new_client
  AppTest.user
  AppTest.sign_in(client)
  Session.all.delete_all
  client.get("/session/new")
  res = client.post("/session", { "_method" => "delete", "authenticity_token" => AppTest.form_token(client) })
  assert_redirected_to res, "/session/new"
end

test "changing the password signs out the sessions started before" do
  client = new_client
  user = AppTest.user
  AppTest.sign_in(client)
  res = client.get("/session/new")
  assert_includes res.body, "<span>ann@example.com</span>"
  user.password = "another-s3cr3t"
  user.save!
  res = client.get("/session/new")
  refute res.body.include?("<span>ann@example.com</span>")
  assert_equal 0, Session.count
  AppTest.sign_in(client, "ann@example.com", "another-s3cr3t")
  res = client.get("/session/new")
  assert_includes res.body, "<span>ann@example.com</span>"
end

test "an expired cookie cannot restore its user or reach a protected action" do
  max_age = Cybertrain.config.session_absolute_max_age
  Cybertrain.config.session_absolute_max_age = 60
  begin
    client = new_client
    AppTest.user
    AppTest.sign_in(client)
    name = Cybertrain.config.session_cookie_name
    cookie = "#{name}=#{client.cookies[name]}"
    res = client.get("/session/new", { "cookie" => cookie })
    assert_includes res.body, "<span>ann@example.com</span>"
    token = AppTest.form_token(client)

    # Keep the signed cookie and its row, but move the creation time
    # to the expiration boundary. Saving updates updated_at too;
    # neither that nor a rewritten cookie extends authentication.
    row = Session.first
    row.created_at = Time.at(Time.now.to_i - Cybertrain.config.session_absolute_max_age).utc
    row.save!
    res = client.post("/session", { "_method" => "delete", "authenticity_token" => token },
                                 { "cookie" => cookie })
    assert_redirected_to res, "/session/new"
    assert_equal 1, Session.count
    res = client.get("/session/new")
    refute res.body.include?("<span>ann@example.com</span>")
    assert_includes res.body, "<a href=\"/session/new\">Sign in</a>"

    # Replaying the original credential again still fails, even
    # after the server removed its id from the client's cookie.
    res = client.get("/session/new", { "cookie" => cookie })
    refute res.body.include?("<span>ann@example.com</span>")
  ensure
    Cybertrain.config.session_absolute_max_age = max_age
  end
end

Cybertrain::Test.run!
