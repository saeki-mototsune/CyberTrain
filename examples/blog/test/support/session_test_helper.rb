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
    fields = { email_address: user.email_address, password: "password" }
    # A browser sends an unchecked box not at all.
    fields[:remember_me] = "1" if remember
    post session_path, params: fields
    nil
  end

  # Signs this browser out.
  def sign_out = delete(session_path)

  # The authenticity_token of the first form in a page (body), for a
  # request sent inside with_forgery_protection.
  def authenticity_token_in(body)
    marker = "name=\"authenticity_token\" value=\""
    at = body.index(marker)
    raise "no authenticity_token in the page" if at.nil?

    start = at + marker.size
    stop = body.index("\"", start).to_i
    body[start, stop - start].to_s
  end

  # Another browser, with cookies of its own, as Rails' open_session
  # gives: `phone = open_session`, then `phone.sign_in_as users(:one)`,
  # `phone.get ...` and `phone.assert_response :success`.
  def open_session = ActionDispatch::IntegrationTest.new
end
