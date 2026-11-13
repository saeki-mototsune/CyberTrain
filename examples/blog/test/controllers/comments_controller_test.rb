require "test_helper"
require "stringio"

# Comments: nested under articles, created from the form on the article
# page and destroyed from the list beside it. Every test starts from
# test/fixtures: comments(:one) is Alice's "Great post!" on
# articles(:one) "Hello Rails"; articles(:two) has no comments.
class CommentsControllerTest < ActionDispatch::IntegrationTest
  test "the article page lists its comments and has a comment form" do
    article = articles(:one)
    other = articles(:two)
    Comment.create(commenter: "Bob", body: "Thanks <b>a lot</b>", article_id: article.id)
    Comment.create(commenter: "Carol", body: "Wrong article", article_id: other.id)
    get "/articles/#{article.id}"
    assert_response :ok
    assert_includes response.body, "<strong class=\"comment-author\">Alice</strong> wrote:"
    assert_includes response.body, "Great post!"
    assert_includes response.body, "Bob"
    assert_includes response.body, "Thanks &lt;b&gt;a lot&lt;/b&gt;"
    assert_nil response.body.index("Wrong article")
    assert_includes response.body, "<h2>Add a comment:</h2>"
    assert_includes response.body, "<form action=\"/articles/#{article.id}/comments\" method=\"post\">"
    assert_includes response.body, "name=\"comment[commenter]\""
    assert_includes response.body, "<textarea name=\"comment[body]\""
    assert_includes response.body, "value=\"Create Comment\""
  end

  test "POST /articles/:article_id/comments adds a comment and redirects back to the article" do
    article = articles(:one)
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "Dave", body: "First!" } }
    assert_redirected_to "/articles/#{article.id}"
    assert_response :see_other
    comment = Comment.last
    refute comment.nil?, "expected the comment to be saved"
    assert_equal article.id, comment.article_id
    assert_equal "Dave", comment.commenter

    follow_redirect!
    assert_includes response.body, "<p class=\"notice\">Comment was successfully created.</p>"
    assert_includes response.body, "Dave"
    assert_includes response.body, "First!"
  end

  test "a commenter's name with markup is shown as text" do
    article = articles(:one)
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "<b>Eve</b><script>alert(1)</script>", body: "Hi" } }
    assert_equal "<b>Eve</b><script>alert(1)</script>", Comment.last.commenter
    get "/articles/#{article.id}"
    assert_includes response.body, "<strong class=\"comment-author\">&lt;b&gt;Eve&lt;/b&gt;&lt;script&gt;alert(1)&lt;/script&gt;</strong> wrote:"
    assert_nil response.body.index("<b>Eve</b>")
    assert_nil response.body.index("<script>alert(1)")
  end

  test "a comment without a commenter is not saved and the article page says why" do
    article = articles(:one)
    get "/articles/#{article.id}"
    before = Comment.count
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "Anonymous words" } }
    assert_redirected_to "/articles/#{article.id}"
    assert_equal before, Comment.count
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Comment could not be saved: Commenter can&#39;t be blank</p>"
  end

  # kept is comments(:one): with the visitor's, two comments.
  test "a visitor comments without signing in, but is sent to sign in to delete a comment" do
    article = articles(:one)
    kept = comments(:one)
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "Visitor", body: "No account needed" } }
    assert_redirected_to "/articles/#{article.id}"
    assert_equal 2, Comment.count
    assert_equal 0, Session.count
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments/#{kept.id}", params: { _method: "delete" }
    assert_redirected_to "/session/new"
    assert_response :see_other
    assert_equal 2, Comment.count
  end

  test "a comment that does not save says why in Japanese" do
    article = articles(:one)
    before = Comment.count
    get "/articles/#{article.id}?locale=ja"
    assert_includes response.body, "<h2>コメントを書く</h2>"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "" } }
    assert_redirected_to "/articles/#{article.id}"
    assert_equal before, Comment.count
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">コメントを保存できませんでした: 名前を入力してください、本文を入力してください</p>"

    # In English, the same post.
    get "/articles/#{article.id}?locale=en"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "" } }
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Comment could not be saved: Commenter can&#39;t be blank, Body can&#39;t be blank</p>"
  end

  test "a saved comment is shown and noticed in Japanese" do
    article = articles(:one)
    get "/articles/#{article.id}?locale=ja"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "花子", body: "素敵な記事です" } }
    follow_redirect!
    assert_includes response.body, "<p class=\"notice\">コメントを投稿しました。</p>"
    assert_includes response.body, "<p><strong class=\"comment-author\">花子</strong>さんのコメント:</p>"
    assert_includes response.body, "<button type=\"submit\">コメントを削除</button>"
    get "/articles/#{article.id}?locale=en"
    assert_includes response.body, "<p><strong class=\"comment-author\">花子</strong> wrote:</p>"
    assert_includes response.body, "<button type=\"submit\">Destroy comment</button>"
  end

  # Forgery protection is off in tests unless config/app.rb sets csrf, as
  # in Rails; the block turns it on for its requests.
  test "a comment posted without the CSRF token is rejected" do
    article = articles(:one)
    get "/articles/#{article.id}"
    token = BlogTestHelper.form_token(response.body)
    before = Comment.count
    with_forgery_protection do
      post "/articles/#{article.id}/comments", params: { comment: { commenter: "Mallory", body: "Forged" } }
      assert_response :forbidden
      assert_equal before, Comment.count
      # The token of the page's form is accepted.
      post "/articles/#{article.id}/comments", params: { authenticity_token: token, comment: { commenter: "Dave", body: "From the form" } }
      assert_response :see_other
      assert_equal before + 1, Comment.count
    end
  end

  # keep is comments(:one); after the delete it is the only comment.
  test "DELETE /articles/:article_id/comments/:id (POST with _method) removes the comment" do
    sign_in_as users(:two)
    article = articles(:one)
    keep = comments(:one)
    doomed = Comment.create(commenter: "Bob", body: "Delete me", article_id: article.id)
    get "/articles/#{article.id}"
    assert_includes response.body, "<form class=\"button_to\" method=\"post\" action=\"/articles/#{article.id}/comments/#{doomed.id}\">"
    post "/articles/#{article.id}/comments/#{doomed.id}", params: { _method: "delete" }
    assert_redirected_to "/articles/#{article.id}"
    assert_response :see_other
    assert_equal 1, Comment.count
    assert_equal keep.id, Comment.first.id

    follow_redirect!
    assert_includes response.body, "<p class=\"notice\">Comment was successfully destroyed.</p>"
    assert_includes response.body, "Great post!"
    assert_nil response.body.index("Delete me")
  end

  test "a comment is only reachable through its own article" do
    sign_in_as users(:two)
    article = articles(:one)
    other = articles(:two)
    comment = Comment.create(commenter: "Carol", body: "Not yours", article_id: other.id)
    before = Comment.count
    get "/articles/#{article.id}"
    delete "/articles/#{article.id}/comments/#{comment.id}"
    assert_response :not_found
    assert_equal before, Comment.count
  end

  test "comments on a missing article are 404" do
    article = articles(:one)
    before = Comment.count
    get "/articles/#{article.id}"
    post "/articles/999/comments", params: { comment: { commenter: "Eve", body: "Into the void" } }
    assert_response :not_found
    assert_equal before, Comment.count
  end

  test "comments have no pages of their own" do
    article = articles(:one)
    comment = comments(:one)
    get "/comments"
    assert_response :not_found
    get "/comments/#{comment.id}"
    assert_response :not_found
    get "/articles/#{article.id}/comments/new"
    assert_response :not_found
    get "/articles/#{article.id}/comments/#{comment.id}"
    assert_response :not_found
  end

  test "a new comment enqueues a NotifyCommentJob, which logs it when performed" do
    article = articles(:one)
    get "/articles/#{article.id}"
    assert_no_enqueued_jobs
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "Dave", body: "First!" } }
    comment = Comment.last
    refute comment.nil?, "expected the comment to be saved"
    assert_enqueued_jobs 1, "NotifyCommentJob"
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => comment.id, "article_id" => article.id }

    log = StringIO.new
    ran = perform_jobs_logging_to(log)
    assert_equal 1, ran
    assert_no_enqueued_jobs
    assert_includes log.string, "new comment #{comment.id} on article #{article.id}"
  end

  test "a comment that is not saved enqueues no job" do
    article = articles(:one)
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "Anonymous words" } }
    assert_no_enqueued_jobs
  end

  private

  # perform_enqueued_jobs with Cybertrain.logger writing to `io`, restored
  # afterwards even if a job raises (a method that does not yield: NOTES
  # rules 32/45).
  def perform_jobs_logging_to(io)
    saved = Cybertrain.logger
    Cybertrain.logger = Cybertrain::Logger.new(io)
    perform_enqueued_jobs
  ensure
    Cybertrain.logger = saved
  end
end
