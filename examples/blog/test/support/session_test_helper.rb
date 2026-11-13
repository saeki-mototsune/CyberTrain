# Signing in and out in tests (cybertrain generate authentication), as
# Rails 8's generator writes it: test/test_helper.rb includes it into
# ActionDispatch::IntegrationTest, so every controller and integration
# test can sign in a fixture user (test/fixtures/users.yml).
#
# Written by the generator; it is yours to change.
module SessionTestHelper
  # Signs user in through the sign-in form, as a browser would: every
  # fixture user's password is "password". `remember: true` checks the
  # form's "Keep me signed in" box.
  def sign_in_as(user, remember: false)
    post session_path, params: { email_address: user.email_address, password: "password",
                                 remember_me: remember ? "1" : "0" }
    nil
  end

  # Signs this browser out.
  def sign_out = delete(session_path)

  # Another browser, with cookies of its own, as Rails' open_session
  # gives: `phone = open_session`, then `phone.sign_in_as users(:one)`,
  # `phone.get ...` and `phone.assert_response :success`.
  def open_session = ActionDispatch::IntegrationTest.new
end
