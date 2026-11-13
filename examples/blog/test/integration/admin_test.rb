# The admin flag (cybertrain generate authentication): User#admin?,
# require_admin (the Authentication concern's before_action, which the
# jobs page in config/routes.rb names) and `./blog user admin EMAIL`.
require "test_helper"
require_relative "../../app/commands/user_command"

# require_admin is private (the Authentication concern's): a controller
# made for this test calls it, as a before_action would.
class AdminProbeController < ApplicationController
  def probe_require_admin
    require_admin
  end
end

class AdminTest < ActionDispatch::IntegrationTest
  test "user.admin? is false for a new user" do
    user = User.new(email_address: "new@example.com")
    user.password = "s3cr3t-s3cr3t"
    user.save!
    assert_equal false, user.admin?
    assert_equal false, User.find(user.id).admin?
    user.admin = true
    user.save!
    assert_equal true, User.find(user.id).admin?
  end

  test "require_admin answers 404 to a visitor and a non-admin and 200 to an admin" do
    # A visitor (no @current_user): require_admin itself answers 404.
    ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/admin/jobs", {}, ""))
    ctx.session = Cybertrain::Session.new
    probe = AdminProbeController.new(ctx)
    probe.probe_require_admin
    assert probe.performed?
    assert_equal 404, ctx.response.status
    assert_equal "Not Found", ctx.response.body
    # Through the full stack the same: the jobs page runs require_admin
    # alone (no redirect to sign in, which would show the page exists).
    get "/admin/jobs"
    assert_response :not_found
    assert_equal "Not Found", response.body
    # Signed in, not an admin: 404, as if there were no such page; the
    # same body and type as a path no route has.
    user = users(:two)
    sign_in_as user
    get "/admin/jobs"
    assert_response :not_found
    assert_equal "Not Found", response.body
    refute response.body.include?("<h1>Jobs</h1>")
    jobs = response
    get "/admin/no-such-page"
    assert_response :not_found
    assert_equal response.body, jobs.body
    assert_equal response.header("content-type"), jobs.header("content-type")
    # Made an admin, the same browser sees the page.
    user.admin = true
    user.save!
    get "/admin/jobs"
    assert_response :ok
    assert_includes response.body, "<h1>Jobs</h1>"
    # And no more once that is taken back.
    user.admin = false
    user.save!
    get "/admin/jobs"
    assert_response :not_found
  end

  # users(:two) is not an admin; users(:one) is, and stays so.
  test "./blog user admin and unadmin print what they did" do
    two = users(:two)
    assert_equal "admin two@example.com", UserCommand.admin_change("Two@Example.com", true)
    assert_equal true, User.find(two.id).admin?
    assert_equal "unadmin two@example.com", UserCommand.admin_change("two@example.com", false)
    assert_equal false, User.find(two.id).admin?
    assert_equal "error: no user bob@example.com", UserCommand.admin_change("bob@example.com", true)
    assert_equal 2, User.count
  end

  test "./blog user admin and unadmin set the flag of an existing user" do
    two = users(:two)
    assert_equal 0, UserCommand.run(["admin", "Two@Example.com"])
    assert_equal true, User.find(two.id).admin?
    assert_equal 0, UserCommand.run(["unadmin", "two@example.com"])
    assert_equal false, User.find(two.id).admin?
    assert_equal 1, UserCommand.run(["admin", "bob@example.com"])
    assert_equal 1, UserCommand.run(["admin"])
    assert_equal 1, UserCommand.run(["unadmin", "two@example.com", "extra"])
    assert_equal 2, User.count
    assert_equal false, User.find(two.id).admin?
  end
end
