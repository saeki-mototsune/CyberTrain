require "test_helper"

# The jobs page (config/routes.rb: jobs_page "/admin/jobs", before_action:
# :require_admin, skip_before_action: :require_authentication): the
# Authentication concern's require_admin alone decides, so anyone but a
# signed-in admin gets its 404 ("Not Found"), a visitor included.
# users(:one) is an admin, users(:two) is not.
class JobsPageTest < ActionDispatch::IntegrationTest
  test "the jobs page is 404 to a visitor and to a user who is not an admin, and renders for an admin" do
    get "/admin/jobs"
    assert_not_found
    # The token gate's header opens nothing any more.
    get "/admin/jobs", headers: { "x-admin-token" => "blog-admin-s3cret" }
    assert_not_found
    sign_in_as users(:two)
    get "/admin/jobs"
    assert_not_found

    admin = open_session
    failed = BlogTestHelper.failed_job
    admin.sign_in_as users(:one)
    admin.get "/admin/jobs"
    admin.assert_response :ok
    assert_includes admin.response.body, "<title>Blog</title>"
    assert_includes admin.response.body, "<h1>Jobs</h1>"
    assert_includes admin.response.body, "<td>NotifyCommentJob</td>"
    assert_includes admin.response.body, "action=\"/admin/jobs/#{failed}/retry\""
  end

  test "retry, discard and delete are 404 to a visitor and to a user who is not an admin" do
    failed = BlogTestHelper.failed_job
    get "/articles"
    get "/session/new"
    ["retry", "discard", "delete"].each do |action|
      post "/admin/jobs/#{failed}/#{action}"
      assert_not_found
      assert_equal "failed", BlogTestHelper.job_state(failed)
    end
    sign_in_as users(:two)
    get "/articles/new"
    ["retry", "discard", "delete"].each do |action|
      post "/admin/jobs/#{failed}/#{action}"
      assert_not_found
      assert_equal "failed", BlogTestHelper.job_state(failed)
    end
    post "/admin/jobs/retry_all"
    assert_not_found
    post "/admin/jobs/discard_all"
    assert_not_found
    assert_equal "failed", BlogTestHelper.job_state(failed)
  end

  test "an admin signs in through the sign-in form and retries a job through the session" do
    failed = BlogTestHelper.failed_job
    get "/admin/jobs"
    assert_not_found

    sign_in_as users(:one)
    assert_redirected_to "/"
    assert_response :see_other
    refute BlogTestHelper.session_of(cookies)["session_id"].to_s.empty?, "the cookie names a Session row"
    assert_equal 1, Session.count

    get "/admin/jobs"
    assert_response :ok
    assert_includes response.body, "<h1>Jobs</h1>"
    post "/admin/jobs/#{failed}/retry"
    assert_redirected_to "/admin/jobs"
    assert_response :see_other
    assert_equal "queued", BlogTestHelper.job_state(failed)
    follow_redirect!
    assert_response :ok
    assert_includes response.body, "<p class=\"notice\">Job #{failed} was queued again.</p>"

    again = BlogTestHelper.failed_job
    get "/admin/jobs"
    post "/admin/jobs/#{again}/discard"
    assert_equal "discarded", BlogTestHelper.job_state(again)
    post "/admin/jobs/#{again}/delete"
    assert_equal "(gone)", BlogTestHelper.job_state(again)
  end

  test "a wrong password signs nobody in and the jobs page stays 404" do
    get "/session/new"
    post "/session", params: { email_address: users(:one).email_address, password: "not-the-password" }
    assert_redirected_to "/session/new"
    assert_nil BlogTestHelper.session_of(cookies)["session_id"]
    assert_equal 0, Session.count
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Try another email address or password.</p>"
    get "/admin/jobs"
    assert_not_found
  end

  test "the token gate's /admin/login is gone" do
    get "/admin/login"
    assert_not_found
    get "/session/new"
    post "/admin/login", params: { token: "blog-admin-s3cret" }
    assert_not_found
    assert_nil BlogTestHelper.session_of(cookies)["admin"]
    get "/admin/jobs"
    assert_not_found
  end

  test "an admin made an ordinary user again, or signed out, gets 404" do
    sign_in_as users(:one)
    get "/admin/jobs"
    assert_response :ok
    get "/admin/articles"
    assert_response :ok
    admin = users(:one)
    admin.admin = false
    admin.save!
    get "/admin/jobs"
    assert_not_found
    get "/admin/articles"
    assert_not_found
    admin.admin = true
    admin.save!
    get "/admin/jobs"
    assert_response :ok

    delete "/session"
    assert_redirected_to "/session/new"
    assert_equal 0, Session.count
    get "/admin/jobs"
    assert_not_found
    get "/admin/articles"
    assert_redirected_to "/session/new"
  end

  private

  # The Authentication concern's require_admin answer: 404, "Not Found".
  def assert_not_found
    assert_response :not_found
    assert_equal "Not Found", response.body
    nil
  end
end
