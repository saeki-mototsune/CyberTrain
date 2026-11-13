

# The jobs page (config/routes.rb: jobs_page "/admin/jobs", before_action:
# :require_admin, skip_before_action: :require_authentication): the
# Authentication concern's require_admin alone decides, so anyone but a
# signed-in admin gets its 404 ("Not Found"), a visitor included.
# users(:one) is an admin, users(:two) is not.
class JobsPageTest < ActionDispatch::IntegrationTest
  def test_the_jobs_page_is_404_to_a_visitor_and_to_a_user_who_is_not_an_admin__and_renders_for_an_admin; begin
    get "/admin/jobs"
    assert_not_found
    # The token gate's header opens nothing any more.
    get "/admin/jobs", headers: { "x-admin-token" => "blog-admin-s3cret" }
    assert_not_found
    sign_in_as users(:two)
    assert_signed_in_as_two
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
  end; nil; end

  def test_retry__discard_and_delete_are_404_to_a_visitor_and_to_a_user_who_is_not_an_admin; begin
    failed = BlogTestHelper.failed_job
    get "/articles"
    get "/session/new"
    ["retry", "discard", "delete"].each do |action|
      post "/admin/jobs/#{failed}/#{action}"
      assert_not_found
      assert_equal "failed", BlogTestHelper.job_state(failed)
    end
    sign_in_as users(:two)
    assert_signed_in_as_two
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
  end; nil; end

  def test_an_admin_signs_in_through_the_sign_in_form_and_retries_a_job_through_the_session; begin
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
  end; nil; end

  def test_a_wrong_password_signs_nobody_in_and_the_jobs_page_stays_404; begin
    get "/session/new"
    post "/session", params: { email_address: users(:one).email_address, password: "not-the-password" }
    assert_redirected_to "/session/new"
    assert_nil BlogTestHelper.session_of(cookies)["session_id"]
    assert_equal 0, Session.count
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Try another email address or password.</p>"
    get "/admin/jobs"
    assert_not_found
  end; nil; end

  def test_the_token_gate_s__admin_login_is_gone; begin
    get "/admin/login"
    assert_not_found
    get "/session/new"
    post "/admin/login", params: { token: "blog-admin-s3cret" }
    assert_not_found
    assert_nil BlogTestHelper.session_of(cookies)["admin"]
    get "/admin/jobs"
    assert_not_found
  end; nil; end

  def test_an_admin_made_an_ordinary_user_again__or_signed_out__gets_404; begin
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
  end; nil; end

  private

  # The sign-in of users(:two) took: the account page, which only a
  # signed-in user gets, is theirs. So the 404s after it are the answer
  # to a user who is not an admin, not to a visitor.
  def assert_signed_in_as_two
    assert_redirected_to "/"
    get "/account/edit"
    assert_response :ok
    assert_includes response.body, "<span>two@example.com</span>"
    nil
  end

  # The Authentication concern's require_admin answer: 404, "Not Found".
  def assert_not_found
    assert_response :not_found
    assert_equal "Not Found", response.body
    nil
  end
end
# Generated by `spin run gen` from test/integration/jobs_page_test.rb. Do not edit.
