# Password reset (cybertrain generate authentication): the address form,
# the mail (kept in Cybertrain::Mailer.deliveries, as the test
# environment does), the link's token (15 minutes, bound to the password
# and the address) and what a reset ends.
require "stringio"


class PasswordsControllerTest < ActionDispatch::IntegrationTest
  SENT = "<p class=\"notice\">If that address is registered, a link to reset the password was sent to it.</p>"
  INVALID = "<p class=\"alert\">That password reset link is invalid or has expired.</p>"
  UPDATED = "<p class=\"notice\">Your password has been reset. Sign in with the new one.</p>"
  NEW_PASSWORD = "n3w-s3cr3t-n3w"
  # with_config's `hosts` for an app that lists none (CYBERTRAIN_HOSTS unset).
  NO_HOSTS = Array.new(0) { "" }

  def test_a_reset_mail_is_sent_once_and_its_link_expires_after_15_minutes; begin
    freeze_time
    assert_emails(1) do
      request_reset("one@example.com")
    end
    assert_redirected_to "/session/new"
    assert_equal "one@example.com", Cybertrain::Mailer.deliveries.last.mail_to
    token = token_in(last_mail_link)
    travel 14.minutes do
      get "/passwords/#{token}/edit"
      assert_response :ok
    end
    travel 16.minutes do
      get "/passwords/#{token}/edit"
      assert_redirected_to "/passwords/new"
      reset_with(token, NEW_PASSWORD)
      assert_redirected_to "/passwords/new"
    end
    assert Cybertrain::Password.verify?("password", User.find(users(:one).id).password_digest)
  end; nil; end

  def test_reset_answers_the_same_for_unknown_addresses_and_links_to_base_url; begin
    with_config("test", NO_HOSTS, "https://shop.example") do
      # A forged Host on both: the link takes base_url, never the header.
      request_reset("One@Example.com", "evil.example")
      known = response
      follow_redirect!
      known_page = response.body
      assert_enqueued_jobs 1, "cybertrain mail"
      request_reset("nobody@example.com", "evil.example")
      unknown = response
      assert_equal 303, known.status
      assert_equal known.status, unknown.status
      assert_equal "/session/new", known.header("Location")
      assert_equal known.header("Location"), unknown.header("Location")
      assert_equal known.body, unknown.body
      follow_redirect!
      assert_includes known_page, SENT
      assert_includes response.body, SENT
      # One mail, for the registered address only.
      assert_enqueued_jobs 1, "cybertrain mail"
    end
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link
    assert link.start_with?("https://shop.example/passwords/"), link
    assert link.end_with?("/edit"), link
    refute link.include?("evil.example")
    # The link works once.
    token = token_in(link)
    get "/passwords/#{token}/edit"
    assert_response :ok
    reset_with(token, NEW_PASSWORD)
    assert_redirected_to "/session/new"
    get "/passwords/#{token}/edit"
    assert_redirected_to "/passwords/new"
  end; nil; end

  def test_without_base_url_a_link_takes_the_request_s_address_only_where_that_is_safe; begin
    # Tests: the address the request came to.
    with_config("test", NO_HOSTS, "") do
      request_reset("one@example.com", "www.example.com")
    end
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link
    assert link.start_with?("http://www.example.com/passwords/"), link
    # Development checks the Host header: the request's address.
    with_config("development", NO_HOSTS, "") do
      assert Cybertrain.config.host_check?
      request_reset("one@example.com", "localhost:3000")
      assert_redirected_to "/session/new"
    end
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link
    assert link.start_with?("http://localhost:3000/passwords/"), link
    # Production with CYBERTRAIN_HOSTS (the Host header is checked): the
    # request's address too.
    with_config("production", ["shop.example"], "") do
      assert Cybertrain.config.host_check?
      request_reset("one@example.com", "shop.example")
      assert_redirected_to "/session/new"
    end
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link
    assert link.start_with?("http://shop.example/passwords/"), link
    # Production with base_url: base_url, whatever the Host.
    with_config("production", NO_HOSTS, "https://shop.example") do
      request_reset("one@example.com", "evil.example")
      assert_redirected_to "/session/new"
    end
    assert_equal 1, perform_enqueued_jobs
    link = last_mail_link
    assert link.start_with?("https://shop.example/passwords/"), link
    # Production with neither: no mail, an [ERROR] line, the same answer.
    log = StringIO.new
    with_config("production", NO_HOSTS, "", log) do
      refute Cybertrain.config.host_check?
      request_reset("one@example.com", "evil.example")
      assert_redirected_to "/session/new"
      follow_redirect!
      assert_includes response.body, SENT
    end
    assert_no_enqueued_jobs "cybertrain mail"
    assert_includes log.string, "[ERROR] password reset mail not sent: set BLOG_BASE_URL (or CYBERTRAIN_HOSTS)\n"
  end; nil; end

  def test_any_other_environment_without_base_url_sends_no_mail_and_answers_the_same; begin
    log = StringIO.new
    # A staging server reached with a forged Host: not production, but
    # nothing checks its Host header either.
    with_config("staging", NO_HOSTS, "", log) do
      refute Cybertrain.config.host_check?
      request_reset("one@example.com", "evil.example")
      known = response
      follow_redirect!
      assert_includes response.body, SENT
      request_reset("nobody@example.com", "evil.example")
      unknown = response
      assert_equal 303, known.status
      assert_equal known.status, unknown.status
      assert_equal "/session/new", known.header("Location")
      assert_equal known.header("Location"), unknown.header("Location")
      assert_equal known.body, unknown.body
      follow_redirect!
      assert_includes response.body, SENT
    end
    assert_no_enqueued_jobs "cybertrain mail"
    assert_includes log.string, "[ERROR] password reset mail not sent: set BLOG_BASE_URL (or CYBERTRAIN_HOSTS)\n"
    assert log.string.index("evil.example").nil?
  end; nil; end

  # Such an address is refused at entry now (User.email_address_format?),
  # so this one was saved before that check existed.
  def test_an_address_the_mailer_refuses_gets_the_same_answer__and_the_log_says_why; begin
    users(:two).update_columns(email_address: "josé@example.com")
    log = StringIO.new
    with_config("test", NO_HOSTS, "https://shop.example", log) do
      request_reset("josé@example.com")
      refused = response
      follow_redirect!
      assert_includes response.body, SENT
      request_reset("nobody@example.com")
      assert_equal 303, refused.status
      assert_equal refused.status, response.status
      assert_equal "/session/new", refused.header("Location")
      assert_equal refused.header("Location"), response.header("Location")
      assert_equal refused.body, response.body
    end
    assert_no_enqueued_jobs "cybertrain mail"
    assert_includes log.string, "[ERROR] password reset mail not sent: the to address contains a space, a control character or a non-ASCII byte\n"
  end; nil; end

  def test_the_token_expires_after_15_minutes; begin
    user = users(:one)
    now = Time.current.to_i
    assert user.password_reset_token(now).start_with?("#{user.id}--#{now + 15 * 60}--")
    stale = user.password_reset_token(now - 16 * 60)
    fresh = user.password_reset_token(now - 14 * 60)
    assert_nil User.find_by_password_reset_token(stale)
    found = User.find_by_password_reset_token(fresh)
    refute found.nil?
    assert_equal user.id, found.id
    get "/passwords/#{stale}/edit"
    assert_redirected_to "/passwords/new"
    assert_equal "no-referrer", response.header("Referrer-Policy")
    follow_redirect!
    assert_includes response.body, INVALID
    reset_with(stale, NEW_PASSWORD)
    assert_redirected_to "/passwords/new"
    assert_equal "no-referrer", response.header("Referrer-Policy")
    assert_equal user.password_digest, User.find_by(id: user.id).password_digest
    get "/passwords/#{fresh}/edit"
    assert_response :ok
    page = response
    # The page's address holds the token: no Referer leaves it.
    assert_equal "no-referrer", page.header("Referrer-Policy")
    # The address form's page is not the link's.
    get "/passwords/new"
    assert_nil response.header("Referrer-Policy")
    assert_includes page.body, "<form action=\"/passwords/#{fresh}\" method=\"post\"><input type=\"hidden\" name=\"_method\" value=\"put\">"
  end; nil; end

  def test_the_token_stops_working_once_the_password_changed; begin
    ann = users(:one)
    bob = users(:two)
    token = ann.password_reset_token
    earlier = ann.password_reset_token(Time.current.to_i - 60)
    # A token names its user and is bound to that user's password and
    # address: one with bob's id and ann's binding, ann's id and her
    # password alone, or another purpose, is no one's.
    assert_equal "#{ann.password_digest}:one@example.com", ann.password_reset_binding
    assert_equal ann.id, User.find_by_password_reset_token(token).id
    assert_equal bob.id, User.find_by_password_reset_token(bob.password_reset_token).id
    assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", bob.id, 15 * 60, ann.password_reset_binding))
    assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("password_reset", ann.id, 15 * 60, ann.password_digest))
    assert_nil User.find_by_password_reset_token(Cybertrain::Token.issue("confirmation", ann.id, 15 * 60, ann.password_reset_binding))
    assert_nil User.find_by_password_reset_token("")
    # A new password that does not pass: the token still holds.
    reset_with(token, NEW_PASSWORD, "something-else")
    assert_redirected_to "/passwords/#{token}/edit"
    assert_equal "no-referrer", response.header("Referrer-Policy")
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Password confirmation doesn&#39;t match Password</p>"
    refute User.find_by_password_reset_token(token).nil?
    reset_with(token, NEW_PASSWORD)
    assert_redirected_to "/session/new"
    # Used once, the link is spent, and so is every link sent before.
    get "/passwords/#{token}/edit"
    assert_redirected_to "/passwords/new"
    reset_with(earlier, "an0ther-s3cr3t")
    assert_redirected_to "/passwords/new"
    follow_redirect!
    assert_includes response.body, INVALID
    post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
    assert_redirected_to "/"
    # bob's link is not ann's change: it still works.
    refute User.find_by_password_reset_token(bob.password_reset_token).nil?
    # A password changed any other way ends a link too.
    changed = User.find_by(email_address: "one@example.com")
    fresh = changed.password_reset_token
    changed.password = "th1rd-s3cr3t-x"
    changed.save!
    assert_nil User.find_by_password_reset_token(fresh)
    # And so does a new address (accounts_controller_test.rb changes it
    # through the page).
    fresh = changed.password_reset_token
    refute User.find_by_password_reset_token(fresh).nil?
    changed.email_address = "one@new.example"
    changed.save!
    assert_nil User.find_by_password_reset_token(fresh)
  end; nil; end

  def test_updating_the_password_ends_every_other_session; begin
    ann = users(:one)
    # The laptop (this browser) signed in a day ago.
    travel_to 1.day.ago do
      sign_in_as ann
    end
    assert Session.first.created_at.to_i <= Time.current.to_i - 24 * 60 * 60
    phone = open_session
    phone.sign_in_as ann
    bobs = open_session
    bobs.sign_in_as users(:two)
    assert_equal 2, Session.where(user_id: ann.id).count
    assert signed_in?
    assert browser_signed_in?(phone)
    stranger = open_session
    stranger.put "/passwords/#{ann.password_reset_token}", params: { password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD }
    stranger.assert_redirected_to "/session/new"
    stranger.follow_redirect!
    assert_includes stranger.response.body, UPDATED
    assert_equal 0, Session.where(user_id: ann.id).count
    refute signed_in?
    refute browser_signed_in?(phone)
    # Another user's sessions are left alone.
    assert_equal 1, Session.count
    assert browser_signed_in?(bobs, "two@example.com")
    # The old password no longer signs in; the new one does.
    stranger.sign_in_as ann
    stranger.assert_redirected_to "/session/new"
    stranger.post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
    stranger.assert_redirected_to "/"
  end; nil; end

  def test_a_reset_clears_a_lockout; begin
    ann = users(:one)
    attempts = 0
    while attempts < Cybertrain.config.auth_lockout_attempts
      Cybertrain::RateLimit.reset_all!
      post "/session", params: { email_address: "one@example.com", password: "wrong-password" }
      attempts += 1
    end
    locked = User.find_by(id: ann.id)
    assert locked.locked?
    # While locked, the right password is refused.
    Cybertrain::RateLimit.reset_all!
    sign_in_as ann
    assert_redirected_to "/session/new"
    reset_with(locked.password_reset_token, NEW_PASSWORD)
    assert_redirected_to "/session/new"
    cleared = User.find_by(id: ann.id)
    assert_nil cleared.locked_until
    assert_equal 0, cleared.failed_attempts
    refute cleared.locked?
    post "/session", params: { email_address: "one@example.com", password: NEW_PASSWORD }
    assert_redirected_to "/"
  end; nil; end

  def test_the_mail_is_stored_with_the_dictionary_s_subject; begin
    with_config("test", NO_HOSTS, "https://shop.example/") do
      request_reset("one@example.com")
    end
    assert_enqueued_jobs 1, "cybertrain mail"
    assert_equal 1, perform_enqueued_jobs
    mail = Cybertrain::Mailer.deliveries.last
    refute mail.nil?
    assert_equal "Reset your password", mail.mail_subject
    assert_equal I18n.t("passwords_mailer.reset.subject"), mail.mail_subject
    assert_equal "one@example.com", mail.mail_to
    assert_equal Cybertrain.config.smtp_from, mail.mail_from
    link = last_mail_link
    # base_url's trailing slash is not doubled.
    assert link.start_with?("https://shop.example/passwords/"), link
    assert_equal "Hello one@example.com,\n\nYou can choose a new password within the next 15 minutes at this address:\n" \
                 "#{link}\n\nIf you did not ask for this, ignore this mail: your password stays as it is.\n", mail.mail_body
    assert_includes mail.mail_html, "<p>Hello one@example.com,</p>"
    assert_includes mail.mail_html, "<p><a href=\"#{link}\">Choose a new password</a></p>"
  end; nil; end

  def test_POST__passwords_past_ten_requests_is_refused_for_a_while; begin
    Cybertrain::RateLimit.reset_all!
    count = 0
    while count < 10
      post "/passwords", params: { email_address: "nobody@example.com" }
      assert_redirected_to "/session/new"
      count += 1
    end
    post "/passwords", params: { email_address: "one@example.com" }
    assert_redirected_to "/passwords/new"
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Try again later.</p>"
    assert_no_enqueued_jobs "cybertrain mail"
    Cybertrain::RateLimit.reset_all!
  end; nil; end

  private

  # Sends the address form as a browser would, with the Host header
  # given. The rate limit's counts are forgotten first.
  def request_reset(email_address, host = "www.example.com")
    Cybertrain::RateLimit.reset_all!
    post "/passwords", params: { email_address: email_address }, headers: { "host" => host }
    nil
  end

  # Sends the new-password form of the link with this token.
  def reset_with(token, password, confirmation = password)
    put "/passwords/#{token}", params: { password: password, password_confirmation: confirmation }
    nil
  end

  # The token in a link ("https://.../passwords/<token>/edit").
  def token_in(link)
    start = link.index("/passwords/").to_i + 11
    stop = link.index("/edit").to_i
    link[start, stop - start].to_s
  end

  # Whether this browser is signed in as email_address: the nav names them.
  def signed_in?(email_address = "one@example.com")
    get "/session/new"
    response.body.include?("<span>#{email_address}</span>")
  end

  # Runs the block with Config#env, hosts_from_env and the base_url
  # setting given (and Cybertrain.logger writing errors to log, unless
  # it is nil), then puts them back, also when the block fails.
  def with_config(env, hosts, base_url, log = nil)
    c = Cybertrain.config
    saved_env = c.env
    saved_hosts = c.hosts_from_env
    saved_base_url = c.string_setting(:base_url)
    saved_logger = Cybertrain.logger
    begin
      c.env = env
      c.hosts_from_env = hosts
      c.set_string_setting(:base_url, base_url)
      Cybertrain.logger = Cybertrain::Logger.new(log, :error) unless log.nil?
      yield
    ensure
      c.env = saved_env
      c.hosts_from_env = saved_hosts
      c.set_string_setting(:base_url, saved_base_url)
      Cybertrain.logger = saved_logger
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
# Generated by `spin run gen` from test/controllers/passwords_controller_test.rb. Do not edit.
