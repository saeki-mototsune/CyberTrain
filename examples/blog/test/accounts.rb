# The account page (cybertrain generate authentication): a new address or
# password only with the current password, what a new password ends and
# keeps, deleting the account, and the limits on guessing the password.
# Run with `cybertrain spin test`; its snapshot comes from the compiled
# binary (the database is FFI).
require "stringio"
require_relative "support/app_test"
require_relative "support/authentication_helpers"

WRONG_PASSWORD = "<p class=\"alert\">That is not your current password.</p>"
UPDATED = "<p class=\"notice\">Your account has been updated.</p>"
DELETED = "<p class=\"notice\">Your account has been deleted.</p>"
NOT_DELETED = "<p class=\"alert\">Your account could not be deleted. Nothing has changed.</p>"
NEW_PASSWORD = "n3w-s3cr3t-n3w"
# What the page says after a new address, which takes effect at once.
ADDRESS_CHANGED = UPDATED

# Nothing more to do for a new address to take effect (with
# --confirmable, its link is opened here).
def confirm_new_address(user)
  nil
end

def new_client
  Session.all.delete_all
  User.all.delete_all
  Cybertrain::Test::Client.new(APP)
end

# Sends the account form as a browser would: the current password and the
# fields given, each as user[name]. The rate limit's counts are forgotten
# first, as AppTest.sign_in does.
def update_account(client, current_password, fields)
  Cybertrain::RateLimit.reset_all!
  client.get("/account/edit")
  form = { "authenticity_token" => AppTest.form_token(client), "user[current_password]" => current_password }
  fields.each { |name, value| form["user[#{name}]"] = value }
  client.patch("/account", form)
end

# Sends the delete form with this password.
def delete_account(client, password)
  Cybertrain::RateLimit.reset_all!
  client.get("/account/edit")
  client.delete("/account", { "authenticity_token" => AppTest.form_token(client), "password" => password })
end

# Whether client is signed in as email_address: the nav names them.
def signed_in?(client, email_address = "ann@example.com")
  client.get("/session/new").body.include?("<span>#{email_address}</span>")
end

# The Set-Cookie line of the session cookie in res ("" when none).
def session_cookie(res)
  prefix = "#{Cybertrain.config.session_cookie_name}="
  found = ""
  res.cookies.each { |line| found = line if line.start_with?(prefix) }
  found
end

# A table of the app's own whose rows refer to users (as a migration's
# `t.references :user` makes one), with a row for user: the database
# then refuses to delete that user.
def add_note_for(user)
  Cybertrain::DB.with do |c|
    c.execute("CREATE TABLE account_notes (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users (id))")
    c.execute("INSERT INTO account_notes (user_id) VALUES (#{user.id})")
  end
  nil
end

def drop_notes
  Cybertrain::DB.with { |c| c.execute("DROP TABLE IF EXISTS account_notes") }
  nil
end

test "changing email or password requires the current password" do
  client = new_client
  ann = AppTest.user
  AppTest.user("bob@example.com")
  AppTest.sign_in(client)
  digest = ann.password_digest
  reset_token = ann.password_reset_token
  # A wrong current password: nothing changes, and the page says why.
  res = update_account(client, "wrong-password", { "email_address" => "ann@new.example", "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD })
  assert_response res, :unprocessable_entity
  assert_includes res.body, WRONG_PASSWORD
  same = User.find(ann.id)
  assert_equal "ann@example.com", same.email_address
  assert_equal digest, same.password_digest
  # None at all, for the address alone: the same.
  res = update_account(client, "", { "email_address" => "ann@new.example" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, WRONG_PASSWORD
  assert_equal "ann@example.com", User.find(ann.id).email_address
  # A wrong password ends no session.
  assert signed_in?(client)
  assert_equal 1, Session.count
  session_id = Session.first.id
  # The right one: the new address (normalized), once it takes effect;
  # the password and the session stay as they were.
  res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => " Ann@New.Example ", "password" => "", "password_confirmation" => "" })
  assert_redirected_to res, "/account/edit"
  assert_includes client.follow_redirect!.body, ADDRESS_CHANGED
  confirm_new_address(ann)
  assert_includes client.get("/account/edit").body, "<span>ann@new.example</span>"
  changed = User.find(ann.id)
  assert_equal "ann@new.example", changed.email_address
  assert_equal digest, changed.password_digest
  assert_equal 1, Session.count
  assert_equal session_id, Session.first.id
  # A password reset link sent to the old address no longer works.
  assert_nil User.find_by_password_reset_token(reset_token)
  # Signing in takes the new address, not the old one.
  other = Cybertrain::Test::Client.new(APP)
  assert_redirected_to AppTest.sign_in(other, "ann@example.com"), "/session/new"
  assert_redirected_to AppTest.sign_in(other, "ann@new.example"), "/"
  # A taken address does not pass: the errors, and the nav still shows
  # the address in use.
  res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => "bob@example.com" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Email address has already been taken</li>"
  assert_includes res.body, "<span>ann@new.example</span>"
  assert_equal "ann@new.example", User.find(ann.id).email_address
  # A new password that does not pass: nothing changes.
  res = update_account(client, "s3cr3t-s3cr3t", { "password" => "short", "password_confirmation" => "short" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Password is too short (minimum is 8 characters)</li>"
  res = update_account(client, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => "something-else" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Password confirmation doesn&#39;t match Password</li>"
  assert_equal digest, User.find(ann.id).password_digest
  # The right current password and a new one: only the new one signs in.
  res = update_account(client, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD })
  assert_redirected_to res, "/account/edit"
  refute User.find(ann.id).password_digest == digest
  assert_redirected_to AppTest.sign_in(other, "ann@new.example"), "/session/new"
  assert_redirected_to AppTest.sign_in(other, "ann@new.example", NEW_PASSWORD), "/"
end

test "a password change ends other sessions and keeps this one" do
  laptop = new_client
  ann = AppTest.user
  bob = AppTest.user("bob@example.com")
  # The laptop asked to stay signed in; the phone did not.
  Cybertrain::RateLimit.reset_all!
  laptop.get("/session/new")
  laptop.post("/session", { "authenticity_token" => AppTest.form_token(laptop), "email_address" => "ann@example.com",
                            "password" => "s3cr3t-s3cr3t", "remember_me" => "1" })
  laptop_id = Session.first.id
  assert_equal true, Session.first.remember
  phone = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(phone)
  bobs = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(bobs, "bob@example.com")
  assert_equal 2, Session.where(user_id: ann.id).count
  token = ann.password_reset_token
  refute User.find_by_password_reset_token(token).nil?
  res = update_account(laptop, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD })
  assert_redirected_to res, "/account/edit"
  # This browser is signed in again at once, still remembered (the cookie
  # keeps its Max-Age), on a new Session row with the new password key.
  assert session_cookie(res).end_with?("; Max-Age=2592000"), session_cookie(res)
  assert_includes laptop.follow_redirect!.body, UPDATED
  rows = Session.where(user_id: ann.id).to_a
  assert_equal 1, rows.size
  refute rows[0].id == laptop_id
  assert_equal true, rows[0].remember
  assert signed_in?(laptop)
  refute signed_in?(phone)
  assert signed_in?(bobs, "bob@example.com")
  assert_equal 1, Session.where(user_id: bob.id).count
  # A reset link sent before no longer works.
  assert_nil User.find_by_password_reset_token(token)
  # A browser that did not ask to stay signed in still has not: no Max-Age.
  AppTest.sign_in(phone, "ann@example.com", NEW_PASSWORD)
  assert signed_in?(phone)
  res = update_account(phone, NEW_PASSWORD, { "password" => "th1rd-s3cr3t", "password_confirmation" => "th1rd-s3cr3t" })
  assert_redirected_to res, "/account/edit"
  refute session_cookie(res).empty?
  refute session_cookie(res).include?("Max-Age")
  rows = Session.where(user_id: ann.id).to_a
  assert_equal 1, rows.size
  assert_equal false, rows[0].remember
  assert signed_in?(phone)
  refute signed_in?(laptop)
  # A new address alone ends no session.
  AppTest.sign_in(laptop, "ann@example.com", "th1rd-s3cr3t")
  assert_equal 2, Session.where(user_id: ann.id).count
  res = update_account(phone, "th1rd-s3cr3t", { "email_address" => "ann@new.example" })
  assert_redirected_to res, "/account/edit"
  confirm_new_address(ann)
  assert_equal 2, Session.where(user_id: ann.id).count
  assert signed_in?(laptop, "ann@new.example")
  assert signed_in?(phone, "ann@new.example")
end

test "deleting the account requires the password and removes the user and sessions" do
  client = new_client
  ann = AppTest.user
  AppTest.user("bob@example.com")
  AppTest.sign_in(client)
  phone = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(phone)
  bobs = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(bobs, "bob@example.com")
  assert_equal 3, Session.count
  # A wrong password, or none: nothing is deleted.
  res = delete_account(client, "wrong-password")
  assert_response res, :unprocessable_entity
  assert_includes res.body, WRONG_PASSWORD
  res = delete_account(client, "")
  assert_response res, :unprocessable_entity
  assert_includes res.body, WRONG_PASSWORD
  refute User.find_by(id: ann.id).nil?
  assert_equal 3, Session.count
  assert signed_in?(client)
  # The right one: the user, every session of theirs, and this browser's
  # cookie session.
  res = delete_account(client, "s3cr3t-s3cr3t")
  assert_redirected_to res, "/"
  assert_includes client.get("/session/new").body, DELETED
  assert_nil User.find_by(id: ann.id)
  assert_equal 0, Session.where(user_id: ann.id).count
  assert_equal 1, Session.count
  assert_equal 1, User.all.count
  refute signed_in?(client)
  refute signed_in?(phone)
  assert signed_in?(bobs, "bob@example.com")
  # The address signs in no more.
  assert_redirected_to AppTest.sign_in(client), "/session/new"
  assert_redirected_to client.get("/account/edit"), "/session/new"
end

test "a visitor is sent to sign in" do
  client = new_client
  ann = AppTest.user
  assert_redirected_to client.get("/account/edit"), "/session/new"
  # The forms' requests too, with a valid token and the right password:
  # nothing changes.
  client.get("/session/new")
  token = AppTest.form_token(client)
  res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                   "user[email_address]" => "eve@example.com" })
  assert_redirected_to res, "/session/new"
  res = client.delete("/account", { "authenticity_token" => token, "password" => "s3cr3t-s3cr3t" })
  assert_redirected_to res, "/session/new"
  assert_equal "ann@example.com", User.find(ann.id).email_address
  assert_equal 1, User.all.count
  # Signed in, the browser comes back to the page it asked for, which the
  # nav links to.
  assert_redirected_to AppTest.sign_in(client), "/account/edit"
  res = client.get("/account/edit")
  assert_response res, :ok
  assert_includes res.body, "<h1>Account</h1>"
  assert_includes res.body, "<a href=\"/account/edit\">Account</a>"
  assert_includes res.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\">"
  assert_includes res.body, "<input type=\"email\" name=\"user[email_address]\" id=\"user_email_address\" value=\"ann@example.com\" autocomplete=\"username\">"
  assert_includes res.body, "<label for=\"user_current_password\">Current password</label>"
  assert_includes res.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"delete\">"
end

test "PATCH /account past ten requests is refused for a while" do
  client = new_client
  ann = AppTest.user
  AppTest.sign_in(client)
  client.get("/account/edit")
  token = AppTest.form_token(client)
  Cybertrain::RateLimit.reset_all!
  count = 0
  while count < 10
    res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "wrong-password" })
    assert_response res, :unprocessable_entity
    count += 1
  end
  # Wrong passwords here do not count toward the lockout, which guards
  # signing in (a stolen session could lock the owner out).
  assert_equal 0, User.find(ann.id).failed_attempts
  assert_nil User.find(ann.id).locked_until
  # The right password now gets the limit's answer and changes nothing; a
  # deletion counts in the same window.
  res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                   "user[email_address]" => "ann@new.example" })
  assert_redirected_to res, "/account/edit"
  assert_includes client.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
  assert_equal "ann@example.com", User.find(ann.id).email_address
  res = client.delete("/account", { "authenticity_token" => token, "password" => "s3cr3t-s3cr3t" })
  assert_redirected_to res, "/account/edit"
  refute User.find_by(id: ann.id).nil?
  # Once the window is over (its counts forgotten), the same change passes.
  Cybertrain::RateLimit.reset_all!
  res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                   "user[email_address]" => "ann@new.example" })
  assert_redirected_to res, "/account/edit"
  confirm_new_address(ann)
  assert_equal "ann@new.example", User.find(ann.id).email_address
  Cybertrain::RateLimit.reset_all!
end

test "wrong current passwords are limited per user too, from any address" do
  client = new_client
  ann = AppTest.user
  AppTest.user("bob@example.com")
  AppTest.sign_in(client)
  bobs = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(bobs, "bob@example.com")
  client.get("/account/edit")
  token = AppTest.form_token(client)
  Cybertrain::RateLimit.reset_all!
  # Ten wrong guesses, each from another address: the per-address limit
  # never fills.
  count = 0
  while count < 10
    client.peer_address = "203.0.113.#{count + 1}"
    res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "wrong-password" })
    assert_response res, :unprocessable_entity
    count += 1
  end
  # The eleventh, from yet another address and with the right password:
  # the per-user limit answers, and nothing changes.
  client.peer_address = "203.0.113.99"
  res = client.patch("/account", { "authenticity_token" => token, "user[current_password]" => "s3cr3t-s3cr3t",
                                   "user[email_address]" => "ann@new.example" })
  assert_redirected_to res, "/account/edit"
  assert_includes client.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
  assert_equal "ann@example.com", User.find(ann.id).email_address
  # Another user, from that same address, is not held back by ann's count.
  bobs.get("/account/edit")
  bobs.peer_address = "203.0.113.99"
  res = bobs.patch("/account", { "authenticity_token" => AppTest.form_token(bobs), "user[current_password]" => "s3cr3t-s3cr3t",
                                 "user[password]" => NEW_PASSWORD, "user[password_confirmation]" => NEW_PASSWORD })
  assert_redirected_to res, "/account/edit"
  assert_includes bobs.follow_redirect!.body, UPDATED
  Cybertrain::RateLimit.reset_all!
end

test "the form's fields are the only ones a change takes" do
  client = new_client
  ann = AppTest.user
  AppTest.sign_in(client)
  # Fields the form does not have, sent with the right password: ignored.
  res = update_account(client, "s3cr3t-s3cr3t", { "password" => NEW_PASSWORD, "password_confirmation" => NEW_PASSWORD,
                                                  "admin" => "1", "failed_attempts" => "7", "locked_until" => "2099-01-01 00:00:00" })
  assert_redirected_to res, "/account/edit"
  changed = User.find(ann.id)
  assert changed.authenticate(NEW_PASSWORD)
  assert_equal false, changed.admin?
  assert_equal 0, changed.failed_attempts
  assert_nil changed.locked_until
end

test "PATCH and DELETE /account without the form's token are refused" do
  client = new_client
  ann = AppTest.user
  AppTest.sign_in(client)
  res = client.patch("/account", { "user[current_password]" => "s3cr3t-s3cr3t", "user[email_address]" => "eve@example.com" })
  assert_response res, :forbidden
  res = client.delete("/account", { "password" => "s3cr3t-s3cr3t" })
  assert_response res, :forbidden
  # Nor with another browser's token.
  other = Cybertrain::Test::Client.new(APP)
  other.get("/session/new")
  foreign = AppTest.form_token(other)
  res = client.patch("/account", { "authenticity_token" => foreign, "user[current_password]" => "s3cr3t-s3cr3t",
                                   "user[email_address]" => "eve@example.com" })
  assert_response res, :forbidden
  res = client.delete("/account", { "authenticity_token" => foreign, "password" => "s3cr3t-s3cr3t" })
  assert_response res, :forbidden
  assert_equal "ann@example.com", User.find(ann.id).email_address
  refute User.find_by(id: ann.id).nil?
  assert signed_in?(client)
end

test "a new hash of the password stays with this browser when the change fails" do
  client = new_client
  ann = AppTest.user
  AppTest.user("bob@example.com")
  AppTest.sign_in(client)
  digest = ann.password_digest
  begin
    # The cost raised since ann's digest was made: checking her password
    # saves a new hash of it (User#authenticate).
    Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS + 1
    res = update_account(client, "s3cr3t-s3cr3t", { "email_address" => "bob@example.com" })
    assert_response res, :unprocessable_entity
    assert_includes res.body, "<li>Email address has already been taken</li>"
    rehashed = User.find(ann.id).password_digest
    refute rehashed == digest
    assert Cybertrain::Password.verify?("s3cr3t-s3cr3t", rehashed)
    # This browser is still signed in on its row.
    assert signed_in?(client)
    assert_equal 1, Session.where(user_id: ann.id).count
  ensure
    Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS
  end
end

test "a deletion the database refuses changes nothing and says so" do
  client = new_client
  ann = AppTest.user
  AppTest.sign_in(client)
  phone = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(phone)
  add_note_for(ann)
  log = StringIO.new
  begin
    with_config("test", NO_HOSTS, "", log) do
      refused = delete_account(client, "s3cr3t-s3cr3t")
      assert_response refused, :unprocessable_entity
      assert_includes refused.body, NOT_DELETED
    end
    # The user and both sessions are kept (one transaction), and the
    # log says why.
    refute User.find_by(id: ann.id).nil?
    assert_equal 2, Session.where(user_id: ann.id).count
    assert signed_in?(client)
    assert signed_in?(phone)
    assert_includes log.string, "[ERROR] account not deleted: FOREIGN KEY constraint failed"
  ensure
    drop_notes
  end
  # Once nothing refers to the user, the same deletion passes.
  res = delete_account(client, "s3cr3t-s3cr3t")
  assert_redirected_to res, "/"
  assert_nil User.find_by(id: ann.id)
  assert_equal 0, Session.where(user_id: ann.id).count
end

Cybertrain::Test.run!
