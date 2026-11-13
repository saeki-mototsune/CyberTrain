# Account lockout (cybertrain generate authentication):
# auth_lockout_attempts (10) wrong passwords in a row lock the account
# for auth_lockout_period (an hour); while it is locked even the right
# password gets the wrong-password message; a successful sign-in clears
# the count. SessionsController's rate_limit (ten attempts per address
# in three minutes) would answer the eleventh attempt first, so every
# attempt here forgets its counts (AppTest.sign_in calls
# Cybertrain::RateLimit.reset_all!). Run with `cybertrain spin test`;
# its snapshot comes from the compiled binary (the database is FFI).
require_relative "support/app_test"
require_relative "../app/commands/user_command"

WRONG = "<p class=\"alert\">Try another email address or password.</p>"

def new_client
  Session.all.delete_all
  User.all.delete_all
  Cybertrain::Test::Client.new(APP)
end

# One sign-in attempt through the form, the rate limit's counts
# forgotten first; returns the page the redirect leads to.
def attempt(client, password)
  res = AppTest.sign_in(client, "ann@example.com", password)
  assert_response res, :see_other
  client.follow_redirect!
end

# Ten wrong passwords: the account is locked.
def lock(client)
  10.times { attempt(client, "wrong-password") }
  nil
end

test "10 failures lock the account for an hour with the wrong-password message" do
  client = new_client
  user = AppTest.user
  assert_equal 0, user.failed_attempts
  9.times do |i|
    page = attempt(client, "wrong-password")
    assert_includes page.body, WRONG
    assert_equal i + 1, User.find(user.id).failed_attempts
    assert_nil User.find(user.id).locked_until
    refute User.find(user.id).locked?
  end
  before = Time.now.to_i
  page = attempt(client, "wrong-password")
  after = Time.now.to_i
  assert_includes page.body, WRONG
  locked = User.find(user.id)
  assert locked.locked?
  refute locked.locked_until.nil?
  assert locked.locked_until.to_i >= before + 3600
  assert locked.locked_until.to_i <= after + 3600
  assert_equal 0, locked.failed_attempts
  assert_equal 0, Session.count
end

test "a locked account refuses the right password until locked_until passes" do
  client = new_client
  user = AppTest.user
  lock(client)
  ends = User.find(user.id).locked_until.to_i
  # The eleventh attempt, the right password: the rate limit's counts
  # are forgotten (AppTest.sign_in), so it is the lock that answers,
  # with the wrong-password message.
  res = AppTest.sign_in(client)
  assert_redirected_to res, "/session/new"
  page = client.follow_redirect!
  assert_includes page.body, WRONG
  refute page.body.include?("Try again later.")
  assert_equal 0, Session.count
  # Refused while locked, neither counted nor extended.
  assert_equal 0, User.find(user.id).failed_attempts
  assert_equal ends, User.find(user.id).locked_until.to_i
  # A minute before the lock ends: still refused.
  User.find(user.id).update_columns(locked_until: Time.at(Time.now.to_i + 60).utc)
  page = attempt(client, "s3cr3t-s3cr3t")
  assert_includes page.body, WRONG
  assert_equal 0, Session.count
  # Once it has passed, the right password signs in and the lock is gone.
  User.find(user.id).update_columns(locked_until: Time.at(Time.now.to_i - 1).utc)
  res = AppTest.sign_in(client)
  assert_redirected_to res, "/"
  assert_equal 1, Session.count
  assert_nil User.find(user.id).locked_until
  assert_equal 0, User.find(user.id).failed_attempts
end

test "a successful sign-in clears the count" do
  client = new_client
  user = AppTest.user
  3.times { attempt(client, "wrong-password") }
  assert_equal 3, User.find(user.id).failed_attempts
  res = AppTest.sign_in(client)
  assert_redirected_to res, "/"
  assert_equal 0, User.find(user.id).failed_attempts
  assert_nil User.find(user.id).locked_until
  # The count starts again: nine more wrong passwords do not lock.
  9.times { attempt(client, "wrong-password") }
  assert_equal 9, User.find(user.id).failed_attempts
  assert_nil User.find(user.id).locked_until
  refute User.find(user.id).locked?
end

test "./APP user EMAIL PASSWORD clears a lock" do
  client = new_client
  user = AppTest.user
  lock(client)
  assert User.find(user.id).locked?
  assert_equal 0, UserCommand.run(["ann@example.com", "an0ther-s3cr3t"])
  assert_nil User.find(user.id).locked_until
  assert_equal 0, User.find(user.id).failed_attempts
  res = AppTest.sign_in(client, "ann@example.com", "an0ther-s3cr3t")
  assert_redirected_to res, "/"
  assert_equal 1, Session.count
  # Some failures, no lock: the count is cleared too.
  client = new_client
  user = AppTest.user
  3.times { attempt(client, "wrong-password") }
  assert_equal 0, UserCommand.run(["ann@example.com", "an0ther-s3cr3t"])
  assert_equal 0, User.find(user.id).failed_attempts
end

test "with auth_lockout_attempts 0 an existing lock is not enforced" do
  client = new_client
  user = AppTest.user
  lock(client)
  attempts = Cybertrain.config.auth_lockout_attempts
  begin
    Cybertrain.config.auth_lockout_attempts = 0
    # Lockout off: the lock no longer refuses the right password, and
    # the sign-in clears it.
    refute User.find(user.id).locked_until.nil?
    res = AppTest.sign_in(client)
    assert_redirected_to res, "/"
    assert_equal 1, Session.count
    assert_nil User.find(user.id).locked_until
  ensure
    Cybertrain.config.auth_lockout_attempts = attempts
  end
  # Lockout on again, the same lock is enforced (made afresh).
  client = new_client
  user = AppTest.user
  lock(client)
  res = AppTest.sign_in(client)
  assert_redirected_to res, "/session/new"
  assert_equal 0, Session.count
end

test "auth_lockout_attempts 0 never locks" do
  attempts = Cybertrain.config.auth_lockout_attempts
  begin
    Cybertrain.config.auth_lockout_attempts = 0
    client = new_client
    user = AppTest.user
    11.times { attempt(client, "wrong-password") }
    assert_equal 0, User.find(user.id).failed_attempts
    assert_nil User.find(user.id).locked_until
    res = AppTest.sign_in(client)
    assert_redirected_to res, "/"
    assert_equal 1, Session.count
  ensure
    Cybertrain.config.auth_lockout_attempts = attempts
  end
end

Cybertrain::Test.run!
