# First-run setup, the user command, sign-in and sign-out through the full stack (session cookie,
# CSRF, method override, router). Run with `cybertrain spin test`; its
# snapshot comes from the compiled binary (the database is FFI):
# `script/regen-snapshot`-style.
require_relative "support/app_test"
require_relative "../app/commands/user_command"

def new_client
  Session.all.delete_all
  User.all.delete_all
  Cybertrain::Test::Client.new(APP)
end

# Every action but sign-in and setup needs a user: DELETE /session is
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
  refute res.body.include?("/sign_up")
end

# The form /setup posts, filled in, with the page's one-time token
# in its hidden field.
def setup_form(authenticity_token, password, confirmation)
  { "authenticity_token" => authenticity_token,
    "token" => SetupController.setup_token,
    "user[email_address]" => " Ann@Example.com ",
    "user[password]" => password,
    "user[password_confirmation]" => confirmation }
end

# /setup with this process's token, the link the boot warning prints.
def setup_link
  "/setup?token=#{SetupController.setup_token}"
end

# `./blog ARGS...` in-process. Main.run connects a pool of one for
# the command and disconnects it, so the tests' pool is connected
# again afterwards (the database file is the same).
def run_command(argv)
  status = Cybertrain::Main.run("blog", argv, router: Gen::Routes.build(Cybertrain::Router.new),
                                           url_resolver: Gen::Routes.url_resolver,
                                           views: Cybertrain::Application.no_views)
  reconnect
  status
end

def reconnect
  Cybertrain::DB.connect(Cybertrain.config.database_path, size: Cybertrain.config.pool_size)
  nil
end

test "GET /setup with the token shows the form to this machine while no user exists" do
  client = new_client
  res = client.get(setup_link)
  assert_response res, :ok
  assert_includes res.body, "<h1>Set up</h1>"
  assert_includes res.body, "<form action=\"/setup\" method=\"post\">"
  assert_includes res.body, "<input type=\"hidden\" name=\"token\" value=\"#{SetupController.setup_token}\">"
  assert_includes res.body, "name=\"user[password_confirmation]\""
end

test "/setup without the token, or with a wrong one, is a 404" do
  client = new_client
  assert_equal 32, SetupController.setup_token.size
  res = client.get("/setup")
  assert_response res, :not_found
  res = client.get("/setup?token=")
  assert_response res, :not_found
  res = client.get("/setup?token=0123456789abcdef0123456789abcdef")
  assert_response res, :not_found
  res = client.get("/setup?token=#{SetupController.setup_token}x")
  assert_response res, :not_found
  refute res.body.include?(SetupController.setup_token)
end

test "/setup is a 404 to another machine, through a proxy, and once a user exists" do
  client = new_client
  client.peer_address = "203.0.113.7"
  res = client.get(setup_link)
  assert_response res, :not_found
  client.peer_address = "127.0.0.1"
  res = client.get(setup_link, { "x-forwarded-for" => "203.0.113.7" })
  assert_response res, :not_found
  res = client.get(setup_link)
  assert_response res, :ok
  AppTest.user
  res = client.get(setup_link)
  assert_response res, :not_found
end

test "POST /setup from another machine, or without the token, creates nothing" do
  client = new_client
  client.get(setup_link)
  authenticity_token = AppTest.form_token(client)
  client.peer_address = "203.0.113.7"
  res = client.post("/setup", setup_form(authenticity_token, "s3cr3t-s3cr3t", "s3cr3t-s3cr3t"))
  assert_response res, :not_found
  client.peer_address = "127.0.0.1"
  form = setup_form(authenticity_token, "s3cr3t-s3cr3t", "s3cr3t-s3cr3t")
  form["token"] = "0123456789abcdef0123456789abcdef"
  res = client.post("/setup", form)
  assert_response res, :not_found
  form.delete("token")
  res = client.post("/setup", form)
  assert_response res, :not_found
  assert_equal 0, User.count
end

test "BLOG_SETUP_OPEN opens /setup to any address with the token until a user exists" do
  client = new_client
  client.peer_address = "203.0.113.7"
  Cybertrain.config.set_bool_setting(:setup_open, true)
  res = client.get(setup_link)
  without = client.get("/setup")
  Cybertrain.config.set_bool_setting(:setup_open, false)
  assert_response res, :ok
  assert_response without, :not_found
  AppTest.user
  Cybertrain.config.set_bool_setting(:setup_open, true)
  res = client.get(setup_link)
  Cybertrain.config.set_bool_setting(:setup_open, false)
  assert_response res, :not_found
end

test "POST /setup with the token creates the first user and signs them in" do
  client = new_client
  client.get(setup_link)
  res = client.post("/setup", setup_form(AppTest.form_token(client), "s3cr3t-s3cr3t", "s3cr3t-s3cr3t"))
  assert_redirected_to res, "/"
  assert_equal 1, User.count
  assert_equal "ann@example.com", User.first.email_address
  assert_equal 1, Session.count
  res = client.get("/session/new")
  assert_includes res.body, "<span>ann@example.com</span>"
  res = client.get(setup_link)
  assert_response res, :not_found
end

test "POST /setup with a short or mismatched password re-renders the form" do
  client = new_client
  client.get(setup_link)
  res = client.post("/setup", setup_form(AppTest.form_token(client), "short", "other"))
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Password is too short (minimum is 8 characters)</li>"
  assert_includes res.body, "<li>Password confirmation doesn&#39;t match Password</li>"
  assert_includes res.body, "<input type=\"hidden\" name=\"token\" value=\"#{SetupController.setup_token}\">"
  assert_equal 0, User.count
end

test "./blog user creates a user, then sets its password" do
  new_client
  assert_equal 0, run_command(["user", "Bob@Example.com", "s3cr3t-s3cr3t"])
  assert_equal 1, User.count
  assert_equal "bob@example.com", User.first.email_address
  assert User.first.authenticate("s3cr3t-s3cr3t")
  assert_equal 0, run_command(["user", "bob@example.com", "another-s3cr3t"])
  assert_equal 1, User.count
  assert User.first.authenticate("another-s3cr3t")
  refute User.first.authenticate("s3cr3t-s3cr3t")
end

test "POST /setup and ./blog user refuse an address list or a malformed address" do
  client = new_client
  client.get(setup_link)
  form = setup_form(AppTest.form_token(client), "s3cr3t-s3cr3t", "s3cr3t-s3cr3t")
  form["user[email_address]"] = "ann@example.com,eve@evil.example"
  res = client.post("/setup", form)
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Email address is invalid</li>"
  assert_equal 0, User.count
  assert_equal 1, run_command(["user", "ann@example.com,eve@evil.example", "s3cr3t-s3cr3t"])
  assert_equal 1, run_command(["user", "ann", "s3cr3t-s3cr3t"])
  assert_equal 0, User.count
end

test "./blog user refuses bad arguments and an empty or short password" do
  new_client
  assert_equal 1, run_command(["user"])
  assert_equal 1, run_command(["user", "ann@example.com", "s3cr3t-s3cr3t", "extra"])
  assert_equal 1, run_command(["user", "--help"])
  assert_equal 1, run_command(["user", "ann@example.com", ""])
  assert_equal 1, run_command(["user", "ann@example.com", "short"])
  assert_equal 0, User.count
end

test "a password read from standard input loses one trailing newline" do
  assert_equal "s3cr3t s3cr3t", UserCommand.password_from("s3cr3t s3cr3t\n")
  assert_equal "s3cr3t", UserCommand.password_from("s3cr3t\r\n")
  assert_equal "s3cr3t\n", UserCommand.password_from("s3cr3t\n\n")
  assert_equal "", UserCommand.password_from("")
end

test "the boot warning is due while no user exists" do
  new_client
  assert UserCommand.no_user?
  reconnect
  AppTest.user
  refute UserCommand.no_user?
  reconnect
end

# User.email_address_format?: one address, whatever the mail
# standards allow beyond that.
test "an address is one address: one @, nothing around it that splits it" do
  ["ann@example.com", "ann.lee+news@mail.example.co.jp", "a@b", "o'brien@example.com"].each do |address|
    assert User.email_address_format?(address), address
  end
  ["", "ann", "@example.com", "ann@", "a@b@example.com", "ann@example.com,eve@evil.example",
   "ann@example.com eve@evil.example", "ann @example.com", "<ann@example.com>", "Ann <ann@example.com>",
   "ann@example.com\n", "ann@exa\tmple.com", "\"ann lee\"@example.com"].each do |address|
    refute User.email_address_format?(address), address
  end
end

# An address saved before the check existed (an older release's) is not
# checked again: its owner can still reset the password.
test "an address saved before the format check still saves" do
  new_client
  ann = AppTest.user
  ann.update_columns(email_address: "ann@example.com,old@example.com")
  kept = User.find(ann.id)
  kept.password = "an0ther-s3cr3t"
  assert kept.save
  kept.email_address = "ann@example.com,new@example.com"
  refute kept.save
  assert_includes kept.errors.full_messages, "Email address is invalid"
end

# Every form that signs in, out or resets carries the page's token
# (Cybertrain's CSRF check): without it, a 403 and nothing done.
test "POST /session, PUT /passwords/:token and DELETE /session without the form's token are refused" do
  client = new_client
  user = AppTest.user
  res = client.post("/session", { "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" })
  assert_response res, :forbidden
  assert_equal 0, Session.count
  token = user.password_reset_token
  res = client.put("/passwords/#{token}", { "password" => "an0ther-s3cr3t", "password_confirmation" => "an0ther-s3cr3t" })
  assert_response res, :forbidden
  refute User.find_by_password_reset_token(token).nil?
  AppTest.sign_in(client)
  assert_equal 1, Session.count
  res = client.post("/session", { "_method" => "delete" })
  assert_response res, :forbidden
  assert_equal 1, Session.count
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

# after_authentication_url is private (the Authentication concern's):
# a controller made for these tests reads it.
class ReturnPathProbeController < ApplicationController
  def probe_after_authentication_url
    after_authentication_url
  end
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
# The counts live in Cybertrain::Cache, in windows aligned to the
# epoch: travel_to holds the clock still, so the attempts share one
# window, then travel moves it a whole window on. The ten go to an address no
# user has: the limit counts per client, whatever the address, and
# there is no account for lockout (test/lockout.rb) to lock.
test "POST /session past ten attempts is refused for a while" do
  client = new_client
  AppTest.user
  Cybertrain::RateLimit.reset_all!
  travel_to(Time.at(2_000_000_000)) do
    client.get("/session/new")
    wrong_password = { "authenticity_token" => AppTest.form_token(client),
                       "email_address" => "nobody@example.com", "password" => "wrong-password" }
    right_password = { "authenticity_token" => AppTest.form_token(client),
                       "email_address" => "ann@example.com", "password" => "s3cr3t-s3cr3t" }
    10.times { client.post("/session", wrong_password) }
    res = client.post("/session", right_password)
    assert_redirected_to res, "/session/new"
    assert_equal 0, Session.count
    res = client.follow_redirect!
    assert_includes res.body, "<p class=\"alert\">Try again later.</p>"
    travel 3 * 60
    res = client.post("/session", right_password)
    assert_redirected_to res, "/"
    assert_equal 1, Session.count
  end
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

    # Keep the session cookie and its row, but move the creation time
    # to the expiration boundary. Saving updates updated_at too;
    # neither that nor a rewritten cookie extends authentication.
    row = Session.first
    row.created_at = Time.at(Time.current.to_i - Cybertrain.config.session_absolute_max_age).utc
    row.save!
    res = client.post("/session", { "_method" => "delete", "authenticity_token" => token },
                                 { "cookie" => cookie })
    assert_redirected_to res, "/session/new"
    assert_equal 0, Session.count
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
