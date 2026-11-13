# Account lockout (cybertrain generate authentication):
# auth_lockout_attempts (10) wrong passwords in a row lock the account
# for auth_lockout_period (an hour); while it is locked even the right
# password gets the wrong-password message; a successful sign-in clears
# the count. SessionsController's rate_limit (ten attempts per address
# in three minutes) would answer the eleventh attempt first, so every
# attempt here forgets its counts (Cybertrain::RateLimit.reset_all!).
require "test_helper"
require_relative "../../app/commands/user_command"

class LockoutTest < ActionDispatch::IntegrationTest
  WRONG = "<p class=\"alert\">Try another email address or password.</p>"

  setup do
    @user = users(:one)
  end

  test "10 failures lock the account for an hour with the wrong-password message" do
    assert_equal 0, @user.failed_attempts
    9.times do |i|
      attempt_sign_in("wrong-password")
      assert_includes response.body, WRONG
      assert_equal i + 1, User.find(@user.id).failed_attempts
      assert_nil User.find(@user.id).locked_until
      refute User.find(@user.id).locked?
    end
    before = Time.current.to_i
    attempt_sign_in("wrong-password")
    after = Time.current.to_i
    assert_includes response.body, WRONG
    locked = User.find(@user.id)
    assert locked.locked?
    refute locked.locked_until.nil?
    assert locked.locked_until.to_i >= before + 3600
    assert locked.locked_until.to_i <= after + 3600
    assert_equal 0, locked.failed_attempts
    assert_equal 0, Session.count
  end

  test "ten failures lock the account until the hour passes" do
    freeze_time
    lock_out("one@example.com")
    ends = User.find(@user.id).locked_until.to_i
    # The eleventh attempt, the right password: the rate limit's counts
    # are forgotten, so it is the lock that answers, with the
    # wrong-password message.
    Cybertrain::RateLimit.reset_all!
    sign_in_as @user
    assert_redirected_to "/session/new"
    follow_redirect!
    assert_includes response.body, WRONG
    refute response.body.include?("Try again later.")
    assert_equal 0, Session.count
    # Refused while locked, neither counted nor extended.
    assert_equal 0, User.find(@user.id).failed_attempts
    assert_equal ends, User.find(@user.id).locked_until.to_i
    # A minute before the hour is over: still refused.
    travel 59.minutes do
      attempt_sign_in("password")
      assert_includes response.body, WRONG
      assert_equal 0, Session.count
    end
    # Once it has passed, the right password signs in and the lock is gone.
    travel 1.hour do
      Cybertrain::RateLimit.reset_all!
      sign_in_as @user
      assert_redirected_to "/"
      assert_equal 1, Session.count
      assert_nil User.find(@user.id).locked_until
      assert_equal 0, User.find(@user.id).failed_attempts
    end
  end

  test "a successful sign-in clears the count" do
    3.times { attempt_sign_in("wrong-password") }
    assert_equal 3, User.find(@user.id).failed_attempts
    Cybertrain::RateLimit.reset_all!
    sign_in_as @user
    assert_redirected_to "/"
    assert_equal 0, User.find(@user.id).failed_attempts
    assert_nil User.find(@user.id).locked_until
    # The count starts again: nine more wrong passwords do not lock.
    9.times { attempt_sign_in("wrong-password") }
    assert_equal 9, User.find(@user.id).failed_attempts
    assert_nil User.find(@user.id).locked_until
    refute User.find(@user.id).locked?
  end

  test "./APP user EMAIL PASSWORD clears a lock" do
    lock_out("one@example.com")
    assert User.find(@user.id).locked?
    assert_equal 0, UserCommand.run(["one@example.com", "an0ther-s3cr3t"])
    assert_nil User.find(@user.id).locked_until
    assert_equal 0, User.find(@user.id).failed_attempts
    Cybertrain::RateLimit.reset_all!
    post "/session", params: { email_address: "one@example.com", password: "an0ther-s3cr3t" }
    assert_redirected_to "/"
    assert_equal 1, Session.count
    # Some failures, no lock: the count is cleared too.
    two = users(:two)
    3.times { attempt_sign_in("wrong-password", "two@example.com") }
    assert_equal 0, UserCommand.run(["two@example.com", "an0ther-s3cr3t"])
    assert_equal 0, User.find(two.id).failed_attempts
  end

  test "with auth_lockout_attempts 0 an existing lock is not enforced" do
    lock_out("one@example.com")
    attempts = Cybertrain.config.auth_lockout_attempts
    begin
      Cybertrain.config.auth_lockout_attempts = 0
      # Lockout off: the lock no longer refuses the right password, and
      # the sign-in clears it.
      refute User.find(@user.id).locked_until.nil?
      Cybertrain::RateLimit.reset_all!
      sign_in_as @user
      assert_redirected_to "/"
      assert_equal 1, Session.count
      assert_nil User.find(@user.id).locked_until
    ensure
      Cybertrain.config.auth_lockout_attempts = attempts
    end
    # Lockout on again, a lock is enforced (made afresh, on two).
    two = users(:two)
    lock_out("two@example.com")
    Cybertrain::RateLimit.reset_all!
    sign_in_as two
    assert_redirected_to "/session/new"
    assert_equal 0, Session.where(user_id: two.id).count
  end

  test "auth_lockout_attempts 0 never locks" do
    attempts = Cybertrain.config.auth_lockout_attempts
    begin
      Cybertrain.config.auth_lockout_attempts = 0
      11.times { attempt_sign_in("wrong-password") }
      assert_equal 0, User.find(@user.id).failed_attempts
      assert_nil User.find(@user.id).locked_until
      Cybertrain::RateLimit.reset_all!
      sign_in_as @user
      assert_redirected_to "/"
      assert_equal 1, Session.count
    ensure
      Cybertrain.config.auth_lockout_attempts = attempts
    end
  end

  private

  # One sign-in attempt through the form, the rate limit's counts
  # forgotten first; the page the redirect leads to is the response.
  def attempt_sign_in(password, email_address = "one@example.com")
    Cybertrain::RateLimit.reset_all!
    post "/session", params: { email_address: email_address, password: password }
    assert_response :see_other
    follow_redirect!
    nil
  end

  # Ten wrong passwords: the account is locked.
  def lock_out(email_address)
    10.times { attempt_sign_in("wrong-password", email_address) }
    nil
  end
end
