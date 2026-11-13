
require "stringio"

# Comments: nested under articles, created from the form on the article
# page and destroyed from the list beside it. Every test starts from
# test/fixtures: comments(:one) is Alice's "Great post!" on
# articles(:one) "Hello Rails"; articles(:two) has no comments.
class CommentsControllerTest < ActionDispatch::IntegrationTest
  def test_the_article_page_lists_its_comments_and_has_a_comment_form; begin
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
  end; nil; end

  def test_POST__articles__article_id_comments_adds_a_comment_and_redirects_back_to_the_article; begin
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
  end; nil; end

  def test_a_commenter_s_name_with_markup_is_shown_as_text; begin
    article = articles(:one)
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "<b>Eve</b><script>alert(1)</script>", body: "Hi" } }
    assert_equal "<b>Eve</b><script>alert(1)</script>", Comment.last.commenter
    get "/articles/#{article.id}"
    assert_includes response.body, "<strong class=\"comment-author\">&lt;b&gt;Eve&lt;/b&gt;&lt;script&gt;alert(1)&lt;/script&gt;</strong> wrote:"
    assert_nil response.body.index("<b>Eve</b>")
    assert_nil response.body.index("<script>alert(1)")
  end; nil; end

  def test_a_comment_without_a_commenter_is_not_saved_and_the_article_page_says_why; begin
    article = articles(:one)
    get "/articles/#{article.id}"
    before = Comment.count
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "Anonymous words" } }
    assert_redirected_to "/articles/#{article.id}"
    assert_equal before, Comment.count
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Comment could not be saved: Commenter can&#39;t be blank</p>"
  end; nil; end

  # kept is comments(:one): with the visitor's, two comments.
  def test_a_visitor_comments_without_signing_in__but_is_sent_to_sign_in_to_delete_a_comment; begin
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
  end; nil; end

  def test_a_comment_that_does_not_save_says_why_in_Japanese; begin
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
  end; nil; end

  def test_a_saved_comment_is_shown_and_noticed_in_Japanese; begin
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
  end; nil; end

  # Forgery protection is off in tests unless config/app.rb sets csrf, as
  # in Rails; the block turns it on for its requests.
  def test_a_comment_posted_without_the_CSRF_token_is_rejected; begin
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
  end; nil; end

  # keep is comments(:one); after the delete it is the only comment.
  def test_DELETE__articles__article_id_comments__id__POST_with__method__removes_the_comment; begin
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
  end; nil; end

  def test_a_comment_is_only_reachable_through_its_own_article; begin
    sign_in_as users(:two)
    article = articles(:one)
    other = articles(:two)
    comment = Comment.create(commenter: "Carol", body: "Not yours", article_id: other.id)
    before = Comment.count
    get "/articles/#{article.id}"
    delete "/articles/#{article.id}/comments/#{comment.id}"
    assert_response :not_found
    assert_equal before, Comment.count
  end; nil; end

  def test_comments_on_a_missing_article_are_404; begin
    article = articles(:one)
    before = Comment.count
    get "/articles/#{article.id}"
    post "/articles/999/comments", params: { comment: { commenter: "Eve", body: "Into the void" } }
    assert_response :not_found
    assert_equal before, Comment.count
  end; nil; end

  def test_comments_have_no_pages_of_their_own; begin
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
  end; nil; end

  def test_a_new_comment_enqueues_a_NotifyCommentJob__which_logs_it_when_performed; begin
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
  end; nil; end

  def test_a_comment_that_is_not_saved_enqueues_no_job; begin
    article = articles(:one)
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "Anonymous words" } }
    assert_no_enqueued_jobs
  end; nil; end

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
# Generated by `spin run gen` from test/controllers/comments_controller_test.rb. Do not edit.
