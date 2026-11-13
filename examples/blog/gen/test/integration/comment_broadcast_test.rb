

# The live comment list: the article page subscribes to its stream
# (`turbo_stream_from @article`, Server-Sent Events on "articles:<id>"),
# CommentsController broadcasts each new comment (an append of its
# CommentComponent) and each destroyed one (a remove), and a comment
# Turbo posts is answered by create.turbo_stream.erb. comments(:one) is
# Alice's "Great post!" on articles(:one).
class CommentBroadcastTest < ActionDispatch::IntegrationTest
  TURBO_STREAM_ACCEPT = { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" }.freeze

  def test_the_article_page_renders_each_comment_with_CommentComponent_and_subscribes_to_the_article_s_stream; begin
    article = articles(:one)
    comment = comments(:one)
    get "/articles/#{article.id}"
    assert_response :ok
    assert_includes response.body, "<div id=\"comments\">"
    assert_includes response.body, "<div class=\"comment\" id=\"comment_#{comment.id}\">"
    assert_includes response.body, "<p><strong class=\"comment-author\">Alice</strong> wrote:</p>"
    names = Cybertrain::Stream.verified_names(BlogTestHelper.stream_token(response.body))
    assert_equal 1, names.size
    assert_equal "articles:#{article.id}", names[0]
    # The layout loads Turbo through the import map (config/importmap.rb),
    # which makes <turbo-stream-source> live.
    assert_includes response.body, "\"@hotwired/turbo\":\"https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js\""
    assert_includes response.body, "<script type=\"module\" nonce=\""
  end; nil; end

  def test_a_new_comment_is_broadcast_as_a_Turbo_Stream_append_to_the_article_s_stream; begin
    article = articles(:one)
    get "/articles/#{article.id}"
    before = Cybertrain::Stream.max_id
    payloads = assert_broadcasts(article, 1) do
      post "/articles/#{article.id}/comments", params: { comment: { commenter: "Dave", body: "Live <i>now</i>" } }
    end
    comment = Comment.last
    refute comment.nil?, "expected the comment to be saved"
    assert Cybertrain::Stream.max_id > before, "expected a cybertrain_messages row"
    message = BlogTestHelper.last_broadcast
    stream = message[0]
    payload = message[1]
    assert_equal "articles:#{article.id}", stream
    assert_equal payload, payloads[0]
    assert_includes payload, "<turbo-stream action=\"append\" target=\"comments\"><template>"
    assert_includes payload, "<div class=\"comment\" id=\"comment_#{comment.id}\">"
    assert_includes payload, "<strong class=\"comment-author\">Dave</strong> wrote:"
    assert_includes payload, "Live &lt;i&gt;now&lt;/i&gt;"
    assert_includes payload, "action=\"/articles/#{article.id}/comments/#{comment.id}\""
  end; nil; end

  # doomed is comments(:one), the article's only comment.
  def test_a_destroyed_comment_is_broadcast_as_a_Turbo_Stream_remove_of_its_element; begin
    sign_in_as users(:two)
    article = articles(:one)
    doomed = comments(:one)
    get "/articles/#{article.id}"
    before = Cybertrain::Stream.max_id
    assert_broadcasts(article, 1) do
      post "/articles/#{article.id}/comments/#{doomed.id}", params: { _method: "delete" }
    end
    assert_equal 0, Comment.count
    assert Cybertrain::Stream.max_id > before, "expected a cybertrain_messages row"
    message = BlogTestHelper.last_broadcast
    assert_equal "articles:#{article.id}", message[0]
    assert_equal "<turbo-stream action=\"remove\" target=\"comment_#{doomed.id}\"></turbo-stream>", message[1]
  end; nil; end

  def test_a_comment_that_is_not_saved_broadcasts_nothing; begin
    article = articles(:one)
    get "/articles/#{article.id}"
    before = Cybertrain::Stream.max_id
    assert_no_broadcasts(article) do
      post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "Anonymous words" } }
    end
    assert_equal before, Cybertrain::Stream.max_id
  end; nil; end

  def test_a_comment_posted_by_Turbo_answers_create_turbo_stream_erb__the_comment_appended_and_the_form_reset; begin
    article = articles(:one)
    get "/articles/#{article.id}"
    assert_includes response.body, "<div id=\"comment_form\">"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "Dave", body: "Streamed <i>in</i>" } }, headers: TURBO_STREAM_ACCEPT
    assert_response :ok
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.header("Content-Type").to_s
    assert_turbo_stream action: "append", target: "comments"
    assert_turbo_stream action: "update", target: "comment_form"
    comment = Comment.last
    refute comment.nil?, "expected the comment to be saved"
    assert_equal "Dave", comment.commenter
    assert_includes response.body, "<turbo-stream action=\"append\" target=\"comments\"><template>" \
                                   "<div class=\"comment\" id=\"comment_#{comment.id}\">"
    assert_includes response.body, "<strong class=\"comment-author\">Dave</strong> wrote:"
    assert_includes response.body, "Streamed &lt;i&gt;in&lt;/i&gt;"
    assert_includes response.body, "<turbo-stream action=\"update\" target=\"comment_form\"><template>" \
                                   "<form action=\"/articles/#{article.id}/comments\" method=\"post\">"
    assert_includes response.body, "<textarea name=\"comment[body]\" id=\"comment_body\">\n</textarea>"
    assert_nil response.body.index("<html")
    assert_enqueued_with "NotifyCommentJob", { "comment_id" => comment.id, "article_id" => article.id }

    # No flash is left for the next page: the stream already showed the comment.
    get "/articles/#{article.id}"
    assert_nil response.body.index("successfully created")
  end; nil; end

  def test_a_comment_posted_without_the_Turbo_Stream_Accept_header_still_redirects_with_303; begin
    article = articles(:one)
    before = Comment.count
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "Erin", body: "Plain form" } }, headers: { "Accept" => "text/html" }
    assert_redirected_to "/articles/#{article.id}"
    assert_response :see_other
    assert_equal before + 1, Comment.count
  end; nil; end

  def test_an_invalid_comment_posted_by_Turbo_redirects_back_with_the_alert; begin
    article = articles(:one)
    before = Comment.count
    get "/articles/#{article.id}"
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "", body: "Anonymous words" } }, headers: TURBO_STREAM_ACCEPT
    assert_redirected_to "/articles/#{article.id}"
    assert_response :see_other
    assert_equal before, Comment.count
    follow_redirect!
    assert_includes response.body, "<p class=\"alert\">Comment could not be saved: Commenter can&#39;t be blank</p>"
  end; nil; end
end
# Generated by `spin run gen` from test/integration/comment_broadcast_test.rb. Do not edit.
