# Password reset (cybertrain generate authentication): the address form,
# the mail (through an SMTP receiver in this process), the link's token
# (15 minutes, bound to the password and the address) and what a reset
# ends. Run with `cybertrain spin test`; its snapshot comes from the
# compiled binary (the database is FFI).
require "stringio"
require_relative "support/app_test"
require_relative "support/authentication_helpers"

SENT = "<p class=\"notice\">If that address is registered, a link to reset the password was sent to it.</p>"
INVALID = "<p class=\"alert\">That password reset link is invalid or has expired.</p>"
UPDATED = "<p class=\"notice\">Your password has been reset. Sign in with the new one.</p>"
NEW_PASSWORD = "n3w-s3cr3t-n3w"

def new_client
  Session.all.delete_all
  User.all.delete_all
  clear_enqueued_jobs
  Cybertrain::Test::Client.new(APP)
end

# Sends the address form as a browser would, with the Host header
# given. The rate limit's counts are forgotten first, as AppTest.sign_in
# does.
def request_reset(client, email_address, host = "www.example.com")
  Cybertrain::RateLimit.reset_all!
  client.get("/passwords/new")
  fields = { "authenticity_token" => AppTest.form_token(client), "email_address" => email_address }
  client.post("/passwords", fields, { "host" => host })
end

# Sends the new-password form of the link with this token.
def reset_with(client, token, password, confirmation = password)
  client.get("/passwords/new")
  fields = { "authenticity_token" => AppTest.form_token(client),
             "password" => password, "password_confirmation" => confirmation }
  client.put("/passwords/#{token}", fields)
end

# The token in a link ("https://.../passwords/<token>/edit").
def token_in(link)
  start = link.index("/passwords/").to_i + 11
  stop = link.index("/edit").to_i
  link[start, stop - start].to_s
end

# Whether client is signed in as email_address: the nav names them.
def signed_in?(client, email_address = "ann@example.com")
  client.get("/session/new").body.include?("<span>#{email_address}</span>")
end

test "reset answers the same for unknown addresses and links to base_url" do
  client = new_client
  AppTest.user
  with_config("test", NO_HOSTS, "https://shop.example") do
    # A forged Host on both: the link takes base_url, never the header.
    known = request_reset(client, "Ann@Example.com", "evil.example")
    known_status = known.status
    known_location = known.header("Location")
    known_body = known.body
    known_page = client.follow_redirect!.body
    assert_enqueued_jobs 1, "cybertrain mail"
    unknown = request_reset(client, "nobody@example.com", "evil.example")
    assert_equal 303, known_status
    assert_equal known_status, unknown.status
    assert_equal "/session/new", known_location
    assert_equal known_location, unknown.header("Location")
    assert_equal known_body, unknown.body
    unknown_page = client.follow_redirect!.body
    assert_includes known_page, SENT
    assert_includes unknown_page, SENT
    # One mail, for the registered address only.
    assert_enqueued_jobs 1, "cybertrain mail"
  end
  with_smtp_receiver do |receiver|
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link(receiver)
    assert link.start_with?("https://shop.example/passwords/"), link
    assert link.end_with?("/edit"), link
    refute link.include?("evil.example")
    # The link works once.
    token = token_in(link)
    res = client.get("/passwords/#{token}/edit")
    assert_response res, :ok
    assert_redirected_to reset_with(client, token, NEW_PASSWORD), "/session/new"
    res = client.get("/passwords/#{token}/edit")
    assert_redirected_to res, "/passwords/new"
  end
end

test "without base_url a link takes the request's address only where that is safe" do
  client = new_client
  AppTest.user
  # Tests: the address the request came to.
  with_config("test", NO_HOSTS, "") do
    request_reset(client, "ann@example.com", "www.example.com")
  end
  with_smtp_receiver do |receiver|
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link(receiver)
    assert link.start_with?("http://www.example.com/passwords/"), link
  end
  # Development checks the Host header: the request's address.
  with_config("development", NO_HOSTS, "") do
    assert Cybertrain.config.host_check?
    assert_redirected_to request_reset(client, "ann@example.com", "localhost:3000"), "/session/new"
  end
  with_smtp_receiver do |receiver|
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link(receiver)
    assert link.start_with?("http://localhost:3000/passwords/"), link
  end
  # Production with CYBERTRAIN_HOSTS (the Host header is checked): the
  # request's address too.
  with_config("production", ["shop.example"], "") do
    assert Cybertrain.config.host_check?
    assert_redirected_to request_reset(client, "ann@example.com", "shop.example"), "/session/new"
  end
  with_smtp_receiver do |receiver|
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link(receiver)
    assert link.start_with?("http://shop.example/passwords/"), link
  end
  # Production with base_url: base_url, whatever the Host.
  with_config("production", NO_HOSTS, "https://shop.example") do
    assert_redirected_to request_reset(client, "ann@example.com", "evil.example"), "/session/new"
  end
  with_smtp_receiver do |receiver|
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link(receiver)
    assert link.start_with?("https://shop.example/passwords/"), link
  end
  # Production with neither: no mail, an [ERROR] line, the same answer.
  log = StringIO.new
  with_config("production", NO_HOSTS, "", log) do
    refute Cybertrain.config.host_check?
    res = request_reset(client, "ann@example.com", "evil.example")
    assert_redirected_to res, "/session/new"
    assert_includes client.follow_redirect!.body, SENT
  end
  assert_no_enqueued_jobs "cybertrain mail"
  assert_includes log.string, "[ERROR] password reset mail not sent: set BLOG_BASE_URL (or CYBERTRAIN_HOSTS)\n"
end

test "any other environment without base_url sends no mail and answers the same" do
  client = new_client
  AppTest.user
  log = StringIO.new
  # A staging server reached with a forged Host: not production, but
  # nothing checks its Host header either.
  with_config("staging", NO_HOSTS, "", log) do
    refute Cybertrain.config.host_check?
    known = request_reset(client, "ann@example.com", "evil.example")
    known_status = known.status
    known_location = known.header("Location")
    known_body = known.body
    assert_includes client.follow_redirect!.body, SENT
    unknown = request_reset(client, "nobody@example.com", "evil.example")
    assert_equal 303, known_status
    assert_equal known_status, unknown.status
    assert_equal "/session/new", known_location
    assert_equal known_location, unknown.header("Location")
    assert_equal known_body, unknown.body
    assert_includes client.follow_redirect!.body, SENT
  end
  assert_no_enqueued_jobs "cybertrain mail"
  assert_includes log.string, "[ERROR] password reset mail not sent: set BLOG_BASE_URL (or CYBERTRAIN_HOSTS)\n"
  assert log.string.index("evil.example").nil?
end

# Such an address is refused at entry now (User.email_address_format?),
# so this one was saved before that check existed.
test "an address the mailer refuses gets the same answer, and the log says why" do
  client = new_client
  AppTest.user("jose@example.com").update_columns(email_address: "josé@example.com")
  log = StringIO.new
  with_config("test", NO_HOSTS, "https://shop.example", log) do
    refused = request_reset(client, "josé@example.com")
    refused_status = refused.status
    refused_location = refused.header("Location")
    refused_body = refused.body
    assert_includes client.follow_redirect!.body, SENT
    unknown = request_reset(client, "nobody@example.com")
    assert_equal 303, refused_status
    assert_equal refused_status, unknown.status
    assert_equal "/session/new", refused_location
    assert_equal refused_location, unknown.header("Location")
    assert_equal refused_body, unknown.body
  end
  assert_no_enqueued_jobs "cybertrain mail"
  assert_includes log.string, "[ERROR] password reset mail not sent: the to address contains a space, a control character or a non-ASCII byte\n"
end

test "the token expires after 15 minutes" do
  client = new_client
  user = AppTest.user
  now = Time.now.to_i
  assert user.password_reset_token(now).start_with?("#{user.id}--#{now + 15 * 60}--")
  stale = user.password_reset_token(now - 16 * 60)
  fresh = user.password_reset_token(now - 14 * 60)
  assert_nil User.find_by_password_reset_token(stale)
  found = User.find_by_password_reset_token(fresh)
  refute found.nil?
  assert_equal user.id, found.id
  res = client.get("/passwords/#{stale}/edit")
  assert_redirected_to res, "/passwords/new"
  assert_equal "no-referrer", res.header("Referrer-Policy")
  assert_includes client.follow_redirect!.body, INVALID
  res = reset_with(client, stale, NEW_PASSWORD)
  assert_redirected_to res, "/passwords/new"
  assert_equal "no-referrer", res.header("Referrer-Policy")
  assert_equal user.password_digest, User.find_by(id: user.id).password_digest
  res = client.get("/passwords/#{fresh}/edit")
  assert_response res, :ok
  # The page's address holds the token: no Referer leaves it.
  assert_equal "no-referrer", res.header("Referrer-Policy")
  # The address form's page is not the link's.
  assert_nil client.get("/passwords/new").header("Referrer-Policy")
  assert_includes res.body, "<form action=\"/passwords/#{fresh}\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"put\">"
end

test "the token stops working once the password changed" do
  client = new_client
  ann = AppTest.user
  bob = AppTest.user("bob@example.com")
  token = ann.password_reset_token
  earlier = ann.password_reset_token(Time.now.to_i - 60)
  # A token names its user and is bound to that user's password and
  # address: one with bob's id and ann's binding, ann's id and her
  # password alone, or another purpose, is no one's.
  assert_equal "#{ann.password_digest}:ann@example.com", ann.password_reset_binding
  assert_equal ann.id, User.find_by_password_reset_token(token).id
  assert_equal bob.id, User.find_by_password_reset_token(bob.password_reset_token).id
  assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", bob.id, 15 * 60, ann.password_reset_binding))
  assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", ann.id, 15 * 60, ann.password_digest))
  assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("confirmation", ann.id, 15 * 60, ann.password_reset_binding))
  assert_nil User.find_by_password_reset_token("")
  # A new password that does not pass: the token still holds.
  res = reset_with(client, token, NEW_PASSWORD, "something-else")
  assert_redirected_to res, "/passwords/#{token}/edit"
  assert_equal "no-referrer", res.header("Referrer-Policy")
  assert_includes client.follow_redirect!.body, "<p class=\"alert\">Password confirmation doesn&#39;t match Password</p>"
  refute User.find_by_password_reset_token(token).nil?
  assert_redirected_to reset_with(client, token, NEW_PASSWORD), "/session/new"
  # Used once, the link is spent, and so is every link sent before.
  assert_redirected_to client.get("/passwords/#{token}/edit"), "/passwords/new"
  assert_redirected_to reset_with(client, earlier, "an0ther-s3cr3t"), "/passwords/new"
  assert_includes client.follow_redirect!.body, INVALID
  assert_redirected_to AppTest.sign_in(client, "ann@example.com", NEW_PASSWORD), "/"
  # bob's link is not ann's change: it still works.
  refute User.find_by_password_reset_token(bob.password_reset_token).nil?
  # A password changed any other way ends a link too.
  changed = User.find_by(email_address: "ann@example.com")
  fresh = changed.password_reset_token
  changed.password = "th1rd-s3cr3t-x"
  changed.save!
  assert_nil User.find_by_password_reset_token(fresh)
  # And so does a new address (test/accounts.rb changes it through the page).
  fresh = changed.password_reset_token
  refute User.find_by_password_reset_token(fresh).nil?
  changed.email_address = "ann@new.example"
  changed.save!
  assert_nil User.find_by_password_reset_token(fresh)
end

test "updating the password ends every other session" do
  laptop = new_client
  ann = AppTest.user
  AppTest.user("bob@example.com")
  AppTest.sign_in(laptop)
  # The laptop signed in a day ago.
  backdate_session(Session.first, 24 * 60 * 60)
  assert Session.first.created_at.to_i <= Time.now.to_i - 24 * 60 * 60
  phone = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(phone)
  bobs = Cybertrain::Test::Client.new(APP)
  AppTest.sign_in(bobs, "bob@example.com")
  assert_equal 2, Session.where(user_id: ann.id).count
  assert signed_in?(laptop)
  assert signed_in?(phone)
  stranger = Cybertrain::Test::Client.new(APP)
  res = reset_with(stranger, ann.password_reset_token, NEW_PASSWORD)
  assert_redirected_to res, "/session/new"
  assert_includes stranger.follow_redirect!.body, UPDATED
  assert_equal 0, Session.where(user_id: ann.id).count
  refute signed_in?(laptop)
  refute signed_in?(phone)
  # Another user's sessions are left alone.
  assert_equal 1, Session.count
  assert signed_in?(bobs, "bob@example.com")
  # The old password no longer signs in; the new one does.
  assert_redirected_to AppTest.sign_in(stranger), "/session/new"
  assert_redirected_to AppTest.sign_in(stranger, "ann@example.com", NEW_PASSWORD), "/"
end

test "a reset clears a lockout" do
  client = new_client
  ann = AppTest.user
  attempts = 0
  while attempts < Cybertrain.config.auth_lockout_attempts
    AppTest.sign_in(client, "ann@example.com", "wrong-password")
    attempts += 1
  end
  locked = User.find_by(id: ann.id)
  assert locked.locked?
  # While locked, the right password is refused.
  assert_redirected_to AppTest.sign_in(client), "/session/new"
  res = reset_with(client, locked.password_reset_token, NEW_PASSWORD)
  assert_redirected_to res, "/session/new"
  cleared = User.find_by(id: ann.id)
  assert_nil cleared.locked_until
  assert_equal 0, cleared.failed_attempts
  refute cleared.locked?
  assert_redirected_to AppTest.sign_in(client, "ann@example.com", NEW_PASSWORD), "/"
end

test "the mail arrives through the SMTP receiver with the dictionary's subject" do
  client = new_client
  AppTest.user
  with_config("test", NO_HOSTS, "https://shop.example/") do
    request_reset(client, "ann@example.com")
  end
  assert_enqueued_jobs 1, "cybertrain mail"
  with_smtp_receiver do |receiver|
    assert_equal 1, perform_enqueued_jobs
    mail = receiver.received_message
    refute mail.nil?
    assert_equal "Reset your password", mail.message_header("Subject")
    assert_equal I18n.t("passwords_mailer.reset.subject"), mail.message_header("Subject")
    assert_equal ["ann@example.com"], mail.envelope_recipients
    assert_equal "noreply@example.com", mail.envelope_from
    link = last_mail_link(receiver)
    # base_url's trailing slash is not doubled.
    assert link.start_with?("https://shop.example/passwords/"), link
    parts = mail.message_parts
    assert_equal "Hello ann@example.com,\r\n\r\nYou can choose a new password within the next 15 minutes at this address:\r\n" \
                 "#{link}\r\n\r\nIf you did not ask for this, ignore this mail: your password stays as it is.\r\n", parts["text"]
    assert_includes parts["html"], "<p>Hello ann@example.com,</p>"
    assert_includes parts["html"], "<p><a href=\"#{link}\">Choose a new password</a></p>"
  end
end

test "POST /passwords past ten requests is refused for a while" do
  client = new_client
  AppTest.user
  Cybertrain::RateLimit.reset_all!
  client.get("/passwords/new")
  token = AppTest.form_token(client)
  count = 0
  while count < 10
    res = client.post("/passwords", { "authenticity_token" => token, "email_address" => "nobody@example.com" })
    assert_redirected_to res, "/session/new"
    count += 1
  end
  res = client.post("/passwords", { "authenticity_token" => token, "email_address" => "ann@example.com" })
  assert_redirected_to res, "/passwords/new"
  assert_includes client.follow_redirect!.body, "<p class=\"alert\">Try again later.</p>"
  assert_no_enqueued_jobs "cybertrain mail"
  Cybertrain::RateLimit.reset_all!
end

Cybertrain::Test.run!
