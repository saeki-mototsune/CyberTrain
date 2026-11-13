# The admin flag (cybertrain generate authentication): User#admin?,
# require_admin (the Authentication concern's before_action, which the
# jobs page in config/routes.rb names) and `./blog user admin EMAIL`.
# Run with `cybertrain spin test`; its snapshot comes from the compiled
# binary (the database is FFI).
require_relative "support/app_test"
require_relative "../app/commands/user_command"

def new_client
  Session.all.delete_all
  User.all.delete_all
  Cybertrain::Test::Client.new(APP)
end

# require_admin is private (the Authentication concern's): a controller
# made for this test calls it, as a before_action would.
class AdminProbeController < ApplicationController
  def probe_require_admin
    require_admin
  end
end

test "user.admin? is false for a new user" do
  new_client
  user = AppTest.user
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
  client = new_client
  res = client.get("/admin/jobs")
  assert_response res, :not_found
  assert_equal "Not Found", res.body
  # Signed in, not an admin: 404, as if there were no such page; the
  # same body and type as a path no route has.
  user = AppTest.user
  AppTest.sign_in(client)
  res = client.get("/admin/jobs")
  assert_response res, :not_found
  assert_equal "Not Found", res.body
  refute res.body.include?("<h1>Jobs</h1>")
  missing = client.get("/admin/no-such-page")
  assert_response missing, :not_found
  assert_equal missing.body, res.body
  assert_equal missing.header("content-type"), res.header("content-type")
  # Made an admin, the same browser sees the page.
  user.admin = true
  user.save!
  res = client.get("/admin/jobs")
  assert_response res, :ok
  assert_includes res.body, "<h1>Jobs</h1>"
  # And no more once that is taken back.
  user.admin = false
  user.save!
  res = client.get("/admin/jobs")
  assert_response res, :not_found
end

test "./blog user admin and unadmin print what they did" do
  new_client
  AppTest.user
  assert_equal "admin ann@example.com", UserCommand.admin_change("Ann@Example.com", true)
  assert_equal true, User.first.admin?
  assert_equal "unadmin ann@example.com", UserCommand.admin_change("ann@example.com", false)
  assert_equal false, User.first.admin?
  assert_equal "error: no user bob@example.com", UserCommand.admin_change("bob@example.com", true)
  assert_equal 1, User.count
end

test "./blog user admin and unadmin set the flag of an existing user" do
  new_client
  AppTest.user
  assert_equal 0, UserCommand.run(["admin", "Ann@Example.com"])
  assert_equal true, User.first.admin?
  assert_equal 0, UserCommand.run(["unadmin", "ann@example.com"])
  assert_equal false, User.first.admin?
  assert_equal 1, UserCommand.run(["admin", "bob@example.com"])
  assert_equal 1, UserCommand.run(["admin"])
  assert_equal 1, UserCommand.run(["unadmin", "ann@example.com", "extra"])
  assert_equal 1, User.count
  assert_equal false, User.first.admin?
end

Cybertrain::Test.run!
