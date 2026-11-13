require "test_helper"

# /admin/articles: Admin::ArticlesController, behind the AdminGate concern
# (its before_action is the Authentication concern's require_admin, as the
# jobs page's): require_authentication runs first and sends a visitor to
# sign in; a signed-in user who is not an admin gets 404. users(:one) is
# an admin, users(:two) is not.
class Admin::ArticlesControllerTest < ActionDispatch::IntegrationTest
  test "/admin/articles sends a visitor to sign in, is 404 to a user who is not an admin, and lists the articles to an admin" do
    first = articles(:one)
    get "/admin/articles"
    assert_redirected_to "/session/new"
    assert_response :see_other
    get "/admin/articles", headers: { "x-admin-token" => "blog-admin-s3cret" }
    assert_redirected_to "/session/new"
    sign_in_as users(:two)
    get "/admin/articles"
    assert_not_found

    admin = open_session
    admin.sign_in_as users(:one)
    admin.get "/admin/articles"
    admin.assert_response :ok
    assert_includes admin.response.body, "<title>Blog</title>"
    assert_includes admin.response.body, "<h1>Admin: articles</h1>"
    assert_includes admin.response.body, "<p class=\"admin-count\">2 articles</p>"
    assert_includes admin.response.body, "Hello Rails"
    assert_includes admin.response.body, "Second article"
    assert_includes admin.response.body, "<time datetime=\"2024-03-10T09:00:00Z\">March 10, 2024 09:00</time>"
    assert_includes admin.response.body, "<form class=\"button_to\" method=\"post\" action=\"/admin/articles/#{first.id}\">"
    assert_includes admin.response.body, "<a href=\"/admin/jobs\">Jobs</a>"

    # The jobs page, drawn inside the namespace, keeps its gate.
    admin.get "/admin/jobs"
    admin.assert_response :ok
    visitor = open_session
    visitor.get "/admin/jobs"
    assert_not_found_in visitor
    # Only index and destroy are drawn.
    admin.get "/admin/articles/#{first.id}"
    admin.assert_response :not_found
  end

  # The 21 articles made here are newer than the two fixtures (2024).
  test "the admin list shows at most per_page (20) articles, newest first" do
    sign_in_as users(:one)
    i = 1
    while i <= 21
      article = Article.create(title: "Numbered article #{i}", body: "I am on Rails! This is my first article.")
      article.update_columns(created_at: Time.utc(2025, 1, i, 0, 0, 0))
      i += 1
    end
    assert_equal 20, Admin::ArticlesController.per_page
    get "/admin/articles"
    assert_includes response.body, "<p class=\"admin-count\">23 articles</p>"
    assert_includes response.body, "Numbered article 21"
    assert_includes response.body, "Numbered article 2<"
    assert_nil response.body.index("Numbered article 1<")
    assert response.body.index("Numbered article 21").to_i < response.body.index("Numbered article 20").to_i, "newest first"
  end

  test "DELETE /admin/articles/:id by an admin deletes the article; by anyone else, nothing" do
    doomed = Article.create(title: "Doomed article", body: "I am on Rails! This is my first article.")
    Comment.create(commenter: "Alice", body: "Great post!", article_id: doomed.id)
    kept = articles(:two)
    before = Article.count
    get "/articles/#{kept.id}"
    # A visitor is sent to sign in; a user who is not an admin gets 404.
    delete "/admin/articles/#{doomed.id}"
    assert_redirected_to "/session/new"
    sign_in_as users(:two)
    get "/articles/#{kept.id}"
    delete "/admin/articles/#{doomed.id}"
    assert_not_found
    assert_equal before, Article.count

    admin = open_session
    admin.sign_in_as users(:one)
    admin.get "/admin/articles"
    admin.post "/admin/articles/#{doomed.id}", params: { _method: "delete" }
    admin.assert_redirected_to "/admin/articles"
    admin.assert_response :see_other
    assert_equal before - 1, Article.count
    assert_nil Article.find_by(id: doomed.id)
    # Its comment went with it: comments(:one) is the one left.
    assert_equal 1, Comment.count
    admin.follow_redirect!
    assert_includes admin.response.body, "<p class=\"notice\">Article was successfully deleted.</p>"
    admin.delete "/admin/articles/#{doomed.id}"
    admin.assert_response :not_found
    assert_equal kept.id, Article.find(kept.id).id
  end

  # Forgery protection is off in tests unless config/app.rb sets csrf;
  # the block turns it on for its requests.
  test "DELETE /admin/articles/:id by an admin but without the authenticity_token is 403" do
    sign_in_as users(:one)
    doomed = Article.create(title: "Protected article", body: "I am on Rails! This is my first article.")
    get "/admin/articles"
    before = Article.count
    with_forgery_protection do
      delete "/admin/articles/#{doomed.id}"
      assert_response :forbidden
    end
    assert_equal before, Article.count
  end

  test "a signed-in admin reaches /admin/articles, and the article page links to it" do
    article = articles(:one)
    get "/articles/#{article.id}"
    assert_nil response.body.index("/admin/articles")
    sign_in_as users(:one)
    get "/admin/articles"
    assert_response :ok
    assert_includes response.body, "Hello Rails"
    get "/articles/#{article.id}"
    assert_includes response.body, "<a href=\"/admin/articles\">Manage articles</a>"
    admin = users(:one)
    admin.admin = false
    admin.save!
    get "/admin/articles"
    assert_not_found
    get "/articles/#{article.id}"
    assert_nil response.body.index("/admin/articles")
  end

  test "a signed-in user who is not an admin gets the concern's 404 on every admin page" do
    article = articles(:one)
    failed = BlogTestHelper.failed_job
    sign_in_as users(:two)
    get "/articles/#{article.id}"
    assert_response :ok
    assert_nil response.body.index("Manage articles")
    get "/admin/articles"
    assert_not_found
    delete "/admin/articles/#{article.id}"
    assert_not_found
    get "/admin/jobs"
    assert_not_found
    post "/admin/jobs/#{failed}/retry"
    assert_not_found
    # Nothing deleted: the two fixtures are there.
    assert_equal 2, Article.count
    assert_equal "failed", BlogTestHelper.job_state(failed)
    # The same answer as a page that does not exist.
    get "/admin/no-such-page"
    missing = response
    get "/admin/articles"
    assert_equal missing.status, response.status
    get "/admin/articles"
    assert_equal missing.body, response.body
  end

  private

  # The Authentication concern's require_admin answer: 404, "Not Found".
  def assert_not_found
    assert_response :not_found
    assert_equal "Not Found", response.body
    nil
  end

  # The same, for another browser (open_session).
  def assert_not_found_in(browser)
    browser.assert_response :not_found
    assert_equal "Not Found", browser.response.body
    nil
  end
end
