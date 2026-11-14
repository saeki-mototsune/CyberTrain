# The account page (cybertrain generate authentication): a new address or
# password only with the current password, what a new password ends and
# keeps, deleting the account, and the limits on guessing the password.
require "stringio"
require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  WRONG_PASSWORD = "<p class=\"alert\">That is not your current password.</p>"
  UPDATED = "<p class=\"notice\">Your account has been updated.</p>"
  DELETED = "<p class=\"notice\">Your account has been deleted.</p>"
  NOT_DELETED = "<p class=\"alert\">Your account could not be deleted. Nothing has changed.</p>"
  NEW_PASSWORD = "n3w-s3cr3t-n3w"
  # with_config's `hosts` for an app that lists none (CYBERTRAIN_HOSTS unset).
  NO_HOSTS = Array.new(0) { "" }
  # What the page says after a new address, which takes effect at once.
  ADDRESS_CHANGED = UPDATED

  # A user of the test's own, ann@example.com, password "password",
  # for the tests that delete the account.
  def account_holder
    user = User.new(email_address: "ann@example.com")
    user.password = "password"
    user.save!
    user
  end

  # Nothing more to do for a new address to take effect (with
  # --confirmable, its link is opened here).
  def confirm_new_address(user)
    nil
  end

  test "changing email or password requires the current password" do
    ann = users(:one)
    sign_in_as ann
    digest = ann.password_digest
    reset_token = ann.password_reset_token
    # A wrong current password: nothing changes, and the page says why.
    update_account("wrong-password", { email_address: "one@new.example", password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
    assert_response :unprocessable_entity
    assert_includes response.body, WRONG_PASSWORD
    same = User.find(ann.id)
    assert_equal "one@example.com", same.email_address
    assert_equal digest, same.password_digest
    # None at all, for the address alone: the same.
    update_account("", { email_address: "one@new.example" })
    assert_response :unprocessable_entity
    assert_includes response.body, WRONG_PASSWORD
    assert_equal "one@example.com", User.find(ann.id).email_address
    # A wrong password ends no session.
    assert signed_in?
    assert_equal 1, Session.count
    session_id = Session.first.id
    # The right one: the new address (normalized), once it takes effect;
    # the password and the session stay as they were.
    update_account("password", { email_address: " One@New.Example ", password: "", password_confirmation: "" })
    assert_redirected_to "/account/edit"
    follow_redirect!
    assert_includes response.body, ADDRESS_CHANGED
    confirm_new_address(ann)
    get "/account/edit"
    assert_includes response.body, "<span>one@new.example</span>"
    changed = User.find(ann.id)
    assert_equal "one@new.example", changed.email_address
    assert_equal digest, changed.password_digest
    assert_equal 1, Session.count
    assert_equal session_id, Session.first.id
    # A password reset link sent to the old address no longer works.
    assert_nil User.find_by_password_reset_token(reset_token)
    # Signing in takes the new address, not the old one.
    other = open_session
    other.post "/session", params: { email_address: "one@example.com", password: "password" }
    other.assert_redirected_to "/session/new"
    other.post "/session", params: { email_address: "one@new.example", password: "password" }
    other.assert_redirected_to "/"
    # A taken address does not pass: the errors, and the nav still shows
    # the address in use.
    update_account("password", { email_address: "two@example.com" })
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Email address has already been taken</li>"
    assert_includes response.body, "<span>one@new.example</span>"
    assert_equal "one@new.example", User.find(ann.id).email_address
    # Nor does an address list (two mailboxes for one account), and no
    # link is mailed for it.
    update_account("password", { email_address: "one@new.example,eve@evil.example" })
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Email address is invalid</li>"
    assert_equal "one@new.example", User.find(ann.id).email_address
    # Nor an address the mailer would refuse (Cybertrain::Mailer.address_problem).
    ["one@new.example\u00A0", "one\u3000@new.example", "one\u0085@new.example", "one@new\u2028.example", "one;x@new.example", "one(x)@new.example"].each do |address|
      update_account("password", { email_address: address })
      assert_response :unprocessable_entity
      assert_includes response.body, "<li>Email address is invalid</li>"
      assert_equal "one@new.example", User.find(ann.id).email_address
    end
    # A new password that does not pass: nothing changes.
    update_account("password", { password: "short", password_confirmation: "short" })
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Password is too short (minimum is 8 characters)</li>"
    update_account("password", { password: NEW_PASSWORD, password_confirmation: "something-else" })
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Password confirmation doesn&#39;t match Password</li>"
    assert_equal digest, User.find(ann.id).password_digest
    # The right current password and a new one: only the new one signs in.
    update_account("password", { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
    assert_redirected_to "/account/edit"
    refute User.find(ann.id).password_digest == digest
    other.post "/session", params: { email_address: "one@new.example", password: "password" }
    other.assert_redirected_to "/session/new"
    other.post "/session", params: { email_address: "one@new.example", password: NEW_PASSWORD }
    other.assert_redirected_to "/"
  end

  test "a password change ends other sessions and keeps this one" do
    ann = users(:one)
    bob = users(:two)
    # This browser (a laptop) asked to stay signed in; the phone did not.
    sign_in_as ann, remember: true
    laptop_id = Session.first.id
    assert_equal true, Session.first.remember
    phone = open_session
    phone.sign_in_as ann
    bobs = open_session
    bobs.sign_in_as bob
    assert_equal 2, Session.where(user_id: ann.id).count
    token = ann.password_reset_token
    refute User.find_by_password_reset_token(token).nil?
    update_account("password", { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD })
    assert_redirected_to "/account/edit"
    # This browser is signed in again at once, still remembered (the
    # cookie keeps its Max-Age), on a new Session row with the new
    # password key.
    assert session_cookie_of(response).end_with?("; Max-Age=2592000"), session_cookie_of(response)
    follow_redirect!
    assert_includes response.body, UPDATED
    rows = Session.where(user_id: ann.id).to_a
    assert_equal 1, rows.size
    refute rows[0].id == laptop_id
    assert_equal true, rows[0].remember
    assert signed_in?
    refute browser_signed_in?(phone)
    assert browser_signed_in?(bobs, "two@example.com")
    assert_equal 1, Session.where(user_id: bob.id).count
    # A reset link sent before no longer works.
    assert_nil User.find_by_password_reset_token(token)
    # A browser that did not ask to stay signed in still has not: no Max-Age.
    phone.post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
    assert browser_signed_in?(phone)
    Cybertrain::RateLimit.reset_all!
    phone.patch "/account", params: { user: { current_password: NEW_PASSWORD, password: "th1rd-s3cr3t", password_confirmation: "th1rd-s3cr3t" } }
    phone.assert_redirected_to "/account/edit"
    refute session_cookie_of(phone.response).empty?
    refute session_cookie_of(phone.response).include?("Max-Age")
    rows = Session.where(user_id: ann.id).to_a
    assert_equal 1, rows.size
    assert_equal false, rows[0].remember
    assert browser_signed_in?(phone)
    refute signed_in?
    # A new address alone ends no session.
    post "/session", params: { email_address: "one@example.com", password: "th1rd-s3cr3t" }
    assert_equal 2, Session.where(user_id: ann.id).count
    Cybertrain::RateLimit.reset_all!
    phone.patch "/account", params: { user: { current_password: "th1rd-s3cr3t", email_address: "one@new.example" } }
    phone.assert_redirected_to "/account/edit"
    confirm_new_address(ann)
    assert_equal 2, Session.where(user_id: ann.id).count
    assert signed_in?("one@new.example")
    assert browser_signed_in?(phone, "one@new.example")
  end

  # The user deleted here is one the test makes (account_holder): a
  # fixture of the app's own may point at users(:one) (a scaffold's
  # `user:references` writes `user: one`), and the database keeps a
  # user that rows point at.
  test "deleting the account requires the password and removes the user and sessions" do
    ann = account_holder
    sign_in_as ann
    phone = open_session
    phone.sign_in_as ann
    bobs = open_session
    bobs.sign_in_as users(:two)
    assert_equal 3, Session.count
    # A wrong password, or none: nothing is deleted.
    delete_account("wrong-password")
    assert_response :unprocessable_entity
    assert_includes response.body, WRONG_PASSWORD
    delete_account("")
    assert_response :unprocessable_entity
    assert_includes response.body, WRONG_PASSWORD
    refute User.find_by(id: ann.id).nil?
    assert_equal 3, Session.count
    assert signed_in?("ann@example.com")
    # The right one: the user, every session of theirs, and this
    # browser's cookie session.
    delete_account("password")
    assert_redirected_to "/"
    get "/session/new"
    assert_includes response.body, DELETED
    assert_nil User.find_by(id: ann.id)
    assert_equal 0, Session.where(user_id: ann.id).count
    assert_equal 1, Session.count
    # The fixtures' users are still there.
    assert_equal 2, User.all.count
    refute signed_in?("ann@example.com")
    refute browser_signed_in?(phone, "ann@example.com")
    assert browser_signed_in?(bobs, "two@example.com")
    # The address signs in no more.
    sign_in_as ann
    assert_redirected_to "/session/new"
    get "/account/edit"
    assert_redirected_to "/session/new"
  end

  test "a visitor is sent to sign in" do
    ann = users(:one)
    get "/account/edit"
    assert_redirected_to "/session/new"
    # The forms' requests too, with the right password: nothing changes.
    patch "/account", params: { user: { current_password: "password", email_address: "eve@example.com" } }
    assert_redirected_to "/session/new"
    delete "/account", params: { password: "password" }
    assert_redirected_to "/session/new"
    assert_equal "one@example.com", User.find(ann.id).email_address
    assert_equal 2, User.all.count
    # Signed in, the browser comes back to the page it asked for, which
    # the nav links to.
    sign_in_as ann
    assert_redirected_to "/account/edit"
    get "/account/edit"
    assert_response :ok
    assert_includes response.body, "<h1>Account</h1>"
    assert_includes response.body, "<a href=\"/account/edit\">Account</a>"
    assert_includes response.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"patch\">"
    assert_includes response.body, "<input type=\"email\" name=\"user[email_address]\" id=\"user_email_address\" value=\"one@example.com\" autocomplete=\"username\">"
    assert_includes response.body, "<label for=\"user_current_password\">Current password</label>"
    assert_includes response.body, "<form action=\"/account\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"delete\">"
  end

  test "PATCH /account past ten requests is refused for a while" do
    ann = users(:one)
    sign_in_as ann
    Cybertrain::RateLimit.reset_all!
    count = 0
    while count < 10
      patch "/account", params: { user: { current_password: "wrong-password" } }
      assert_response :unprocessable_entity
      count += 1
    end
    # Wrong passwords here do not count toward the lockout, which guards
    # signing in (a stolen session could lock the owner out).
    assert_equal 0, User.find(ann.id).failed_attempts
    assert_nil User.find(ann.id).locked_until
    # The right password now gets the limit's answer and changes nothing;
    # a deletion counts in the same window.
    patch "/account", params: { user: { current_password: "password", email_address: "one@new.example" } }
    assert_redirected_to "/account/edit"
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
    assert_equal "one@example.com", User.find(ann.id).email_address
    delete "/account", params: { password: "password" }
    assert_redirected_to "/account/edit"
    refute User.find_by(id: ann.id).nil?
    # Once the window is over (its counts forgotten), the same change passes.
    Cybertrain::RateLimit.reset_all!
    patch "/account", params: { user: { current_password: "password", email_address: "one@new.example" } }
    assert_redirected_to "/account/edit"
    confirm_new_address(ann)
    assert_equal "one@new.example", User.find(ann.id).email_address
    Cybertrain::RateLimit.reset_all!
  end

  # The browsers here are Cybertrain::Test::Clients, the client under an
  # integration test: each request of ann's comes from another address,
  # which an integration test cannot set. Their responses are checked by
  # status and Location.
  test "wrong current passwords are limited per user too, from any address" do
    ann = users(:one)
    browser = Cybertrain::Test::Client.new(Cybertrain::Test.app)
    browser.post("/session", { "email_address" => "one@example.com", "password" => "password" })
    bobs = Cybertrain::Test::Client.new(Cybertrain::Test.app)
    bobs.post("/session", { "email_address" => "two@example.com", "password" => "password" })
    Cybertrain::RateLimit.reset_all!
    # Ten wrong guesses, each from another address: the per-address limit
    # never fills.
    count = 0
    while count < 10
      browser.peer_address = "203.0.113.#{count + 1}"
      res = browser.patch("/account", { "user[current_password]" => "wrong-password" })
      assert_equal 422, res.status
      count += 1
    end
    # The eleventh, from yet another address and with the right password:
    # the per-user limit answers, and nothing changes.
    browser.peer_address = "203.0.113.99"
    res = browser.patch("/account", { "user[current_password]" => "password", "user[email_address]" => "one@new.example" })
    assert_equal 303, res.status
    assert_equal "/account/edit", res.header("Location")
    assert_includes browser.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
    assert_equal "one@example.com", User.find(ann.id).email_address
    # Another user, from that same address, is not held back by ann's count.
    bobs.peer_address = "203.0.113.99"
    res = bobs.patch("/account", { "user[current_password]" => "password",
                                   "user[password]" => NEW_PASSWORD, "user[password_confirmation]" => NEW_PASSWORD })
    assert_equal 303, res.status
    assert_equal "/account/edit", res.header("Location")
    assert_includes bobs.follow_redirect!.body, UPDATED
    Cybertrain::RateLimit.reset_all!
  end

  # users(:two) is not an admin, has no failed attempt and no lock.
  test "the form's fields are the only ones a change takes" do
    two = users(:two)
    sign_in_as two
    # Fields the form does not have, sent with the right password: ignored.
    update_account("password", { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD,
                                 admin: "1", failed_attempts: "7", locked_until: "2099-01-01 00:00:00" })
    assert_redirected_to "/account/edit"
    changed = User.find(two.id)
    assert changed.authenticate(NEW_PASSWORD)
    assert_equal false, changed.admin?
    assert_equal 0, changed.failed_attempts
    assert_nil changed.locked_until
  end

  test "PATCH and DELETE /account without the form's token are refused" do
    ann = users(:one)
    sign_in_as ann
    with_forgery_protection do
      patch "/account", params: { user: { current_password: "password", email_address: "eve@example.com" } }
      assert_response :forbidden
      delete "/account", params: { password: "password" }
      assert_response :forbidden
      # Nor with another browser's token.
      other = open_session
      other.get "/session/new"
      foreign = authenticity_token_in(other.response.body)
      patch "/account", params: { authenticity_token: foreign, user: { current_password: "password", email_address: "eve@example.com" } }
      assert_response :forbidden
      delete "/account", params: { authenticity_token: foreign, password: "password" }
      assert_response :forbidden
    end
    assert_equal "one@example.com", User.find(ann.id).email_address
    refute User.find_by(id: ann.id).nil?
    assert signed_in?
  end

  test "a new hash of the password stays with this browser when the change fails" do
    ann = users(:one)
    sign_in_as ann
    digest = ann.password_digest
    begin
      # The cost raised since the fixture's digest was made: checking
      # the password saves a new hash of it (User#authenticate).
      Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS + 1
      update_account("password", { email_address: "two@example.com" })
      assert_response :unprocessable_entity
      assert_includes response.body, "<li>Email address has already been taken</li>"
      rehashed = User.find(ann.id).password_digest
      refute rehashed == digest
      assert Cybertrain::Password.verify?("password", rehashed)
      # This browser is still signed in on its row.
      assert signed_in?
      assert_equal 1, Session.where(user_id: ann.id).count
    ensure
      Cybertrain::Password.iterations = Cybertrain::Password::TEST_ITERATIONS
    end
  end

  test "a deletion the database refuses changes nothing and says so" do
    ann = account_holder
    sign_in_as ann
    phone = open_session
    phone.sign_in_as ann
    add_note_for(ann)
    log = StringIO.new
    begin
      with_config("test", NO_HOSTS, "", log) do
        delete_account("password")
        assert_response :unprocessable_entity
        assert_includes response.body, NOT_DELETED
      end
      # The user and both sessions are kept (one transaction), and the
      # log says why.
      refute User.find_by(id: ann.id).nil?
      assert_equal 2, Session.where(user_id: ann.id).count
      assert signed_in?("ann@example.com")
      assert browser_signed_in?(phone, "ann@example.com")
      assert_includes log.string, " ERROR "
      assert_includes log.string, "account not deleted: FOREIGN KEY constraint failed"
    ensure
      drop_notes
    end
    # Once nothing refers to the user, the same deletion passes.
    delete_account("password")
    assert_redirected_to "/"
    assert_nil User.find_by(id: ann.id)
    assert_equal 0, Session.where(user_id: ann.id).count
  end

  private

  # Sends the account form as a browser would: the current password and
  # the fields given, each as user[name]. The rate limit's counts are
  # forgotten first.
  def update_account(current_password, fields)
    Cybertrain::RateLimit.reset_all!
    form = { current_password: current_password }
    fields.each { |name, value| form[name] = value }
    patch "/account", params: { user: form }
    nil
  end

  # Sends the delete form with this password.
  def delete_account(password)
    Cybertrain::RateLimit.reset_all!
    delete "/account", params: { password: password }
    nil
  end

  # Whether this browser is signed in as email_address: the nav names them.
  def signed_in?(email_address = "one@example.com")
    get "/session/new"
    response.body.include?("<span>#{email_address}</span>")
  end

  # The Set-Cookie line of the session cookie in res ("" when none).
  def session_cookie_of(res)
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

  # Runs the block with Config#env, hosts_from_env and the base_url
  # setting given, text log lines (and Cybertrain.logger writing errors to
  # log, unless it is nil), then puts them back, also when the block fails.
  def with_config(env, hosts, base_url, log = nil)
    c = Cybertrain.config
    saved_env = c.env
    saved_hosts = c.hosts_from_env
    saved_base_url = c.string_setting(:base_url)
    saved_logger = Cybertrain.logger
    saved_json_lines = Cybertrain::Logger.json_lines
    begin
      c.env = env
      c.hosts_from_env = hosts
      c.set_string_setting(:base_url, base_url)
      Cybertrain.logger = Cybertrain::Logger.new(log, :error) unless log.nil?
      Cybertrain::Logger.json_lines = false
      yield
    ensure
      c.env = saved_env
      c.hosts_from_env = saved_hosts
      c.set_string_setting(:base_url, saved_base_url)
      Cybertrain.logger = saved_logger
      Cybertrain::Logger.json_lines = saved_json_lines
    end
    nil
  end

  # The first http:// or https:// link in the text of the last mail
  # sent (Cybertrain::Mailer.deliveries, where the test environment
  # keeps it); "" when none was.
  def last_mail_link
    mail = Cybertrain::Mailer.deliveries.last
    text = mail.nil? ? "" : mail.mail_body
    start = text.index("https://")
    plain = text.index("http://")
    start = plain if start.nil? || (!plain.nil? && plain < start)
    found = ""
    unless start.nil?
      stop = start
      while stop < text.size && text[stop] != " " && text[stop] != "\r" && text[stop] != "\n"
        stop += 1
      end
      found = text[start, stop - start].to_s
    end
    found
  end

  # Whether another browser (open_session) is signed in as
  # email_address: the nav names them.
  def browser_signed_in?(browser, email_address = "one@example.com")
    browser.get "/session/new"
    browser.response.body.include?("<span>#{email_address}</span>")
  end
end
