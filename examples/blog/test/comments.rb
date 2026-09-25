# Integration tests for comments: nested under articles, created from the
# form on the article page and destroyed from the list beside it.
require_relative "support/blog_test"

def new_client
  BlogTest.reset
  Cybertrain::Test::Client.new(BLOG)
end

def comments_path(article)
  "#{BlogTest.article_path(article)}/comments"
end

test "the article page lists its comments and has a comment form" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  other = BlogTest.article("Another article")
  BlogTest.comment(article, "Alice", "Great post!")
  BlogTest.comment(article, "Bob", "Thanks <b>a lot</b>")
  BlogTest.comment(other, "Carol", "Wrong article")
  res = client.get(BlogTest.article_path(article))
  assert_response res, :ok
  assert_includes res.body, "<strong>Commenter:</strong>\n    Alice"
  assert_includes res.body, "Great post!"
  assert_includes res.body, "Bob"
  assert_includes res.body, "Thanks &lt;b&gt;a lot&lt;/b&gt;"
  assert_nil res.body.index("Wrong article")
  assert_includes res.body, "<h2>Add a comment:</h2>"
  assert_includes res.body, "<form action=\"#{comments_path(article)}\" method=\"post\">"
  assert_includes res.body, "name=\"comment[commenter]\""
  assert_includes res.body, "<textarea name=\"comment[body]\""
  assert_includes res.body, "value=\"Create Comment\""
end

test "POST /articles/:article_id/comments adds a comment and redirects back to the article" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  res = client.post(comments_path(article), { "authenticity_token" => BlogTest.form_token(client),
                                              "comment[commenter]" => "Dave",
                                              "comment[body]" => "First!" })
  assert_redirected_to res, BlogTest.article_path(article)
  assert_response res, :see_other
  comment = Comment.last
  refute comment.nil?, "expected the comment to be saved"
  assert_equal article.id, comment.article_id
  assert_equal "Dave", comment.commenter

  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"notice\">Comment was successfully created.</p>"
  assert_includes res.body, "Dave"
  assert_includes res.body, "First!"
end

test "a comment without a commenter is not saved and the article page says why" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  res = client.post(comments_path(article), { "authenticity_token" => BlogTest.form_token(client),
                                              "comment[commenter]" => "",
                                              "comment[body]" => "Anonymous words" })
  assert_redirected_to res, BlogTest.article_path(article)
  assert_equal 0, Comment.count
  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"alert\">Comment could not be saved: Commenter can&#39;t be blank</p>"
end

test "a comment posted without the CSRF token is rejected" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  res = client.post(comments_path(article), { "comment[commenter]" => "Mallory", "comment[body]" => "Forged" })
  assert_response res, :forbidden
  assert_equal 0, Comment.count
end

test "DELETE /articles/:article_id/comments/:id (POST with _method) removes the comment" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  keep = BlogTest.comment(article, "Alice", "Keep me")
  doomed = BlogTest.comment(article, "Bob", "Delete me")
  res = client.get(BlogTest.article_path(article))
  assert_includes res.body, "<form class=\"button_to\" method=\"post\" action=\"#{comments_path(article)}/#{doomed.id}\">"
  res = client.post("#{comments_path(article)}/#{doomed.id}", { "_method" => "delete",
                                                                "authenticity_token" => BlogTest.form_token(client) })
  assert_redirected_to res, BlogTest.article_path(article)
  assert_response res, :see_other
  assert_equal 1, Comment.count
  assert_equal keep.id, Comment.first.id

  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"notice\">Comment was successfully destroyed.</p>"
  assert_includes res.body, "Keep me"
  assert_nil res.body.index("Delete me")
end

test "a comment is only reachable through its own article" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  other = BlogTest.article("Another article")
  comment = BlogTest.comment(other, "Carol", "Not yours")
  client.get(BlogTest.article_path(article))
  res = client.delete("#{comments_path(article)}/#{comment.id}", { "authenticity_token" => BlogTest.form_token(client) })
  assert_response res, :not_found
  assert_equal 1, Comment.count
end

test "comments on a missing article are 404" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  res = client.post("/articles/999/comments", { "authenticity_token" => BlogTest.form_token(client),
                                                "comment[commenter]" => "Eve",
                                                "comment[body]" => "Into the void" })
  assert_response res, :not_found
  assert_equal 0, Comment.count
end

test "comments have no pages of their own" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  comment = BlogTest.comment(article)
  assert_response client.get("/comments"), :not_found
  assert_response client.get("/comments/#{comment.id}"), :not_found
  assert_response client.get("#{comments_path(article)}/new"), :not_found
  assert_response client.get("#{comments_path(article)}/#{comment.id}"), :not_found
end

Cybertrain::Test.run!
