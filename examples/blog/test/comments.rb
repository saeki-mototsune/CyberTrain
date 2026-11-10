# Integration tests for comments: nested under articles, created from the
# form on the article page and destroyed from the list beside it.
require "stringio"
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
  assert_includes res.body, "<strong class=\"comment-author\">Alice</strong> wrote:"
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

# The token a <turbo-stream-source src="/cybertrain/stream?s=TOKEN"> element
# carries.
def stream_token(body)
  marker = "<turbo-stream-source src=\"/cybertrain/stream?s="
  at = body.index(marker)
  raise "no turbo-stream-source in the page" if at.nil?

  start = at + marker.size
  stop = body.index("\"", start)
  raise "unterminated turbo-stream-source" if stop.nil?

  body[start, stop - start].to_s
end

# The last row Cybertrain::Stream.broadcast wrote: [stream, payload].
def last_message
  rows = Cybertrain::DB.with { |c| c.execute("SELECT stream, payload FROM cybertrain_messages ORDER BY id DESC LIMIT 1") }
  return ["", ""] if rows.empty?

  [Cybertrain::Cast.str(rows[0]["stream"]), Cybertrain::Cast.str(rows[0]["payload"])]
end

test "the article page renders each comment with CommentComponent and subscribes to the article's stream" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  comment = BlogTest.comment(article, "Alice", "Great post!")
  res = client.get(BlogTest.article_path(article))
  assert_response res, :ok
  assert_includes res.body, "<div id=\"comments\">"
  assert_includes res.body, "<div class=\"comment\" id=\"comment_#{comment.id}\">"
  assert_includes res.body, "<p><strong class=\"comment-author\">Alice</strong> wrote:</p>"
  names = Cybertrain::Stream.verified_names(stream_token(res.body))
  assert_equal 1, names.size
  assert_equal "articles:#{article.id}", names[0]
  # The layout loads Turbo, which makes <turbo-stream-source> live.
  assert_includes res.body, "<script type=\"module\" src=\"https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js\""
  assert_nil res.body.index("asset pipeline")
end

test "a new comment is broadcast as a Turbo Stream append to the article's stream" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  before = Cybertrain::Stream.max_id
  client.post(comments_path(article), { "authenticity_token" => BlogTest.form_token(client),
                                        "comment[commenter]" => "Dave",
                                        "comment[body]" => "Live <i>now</i>" })
  comment = Comment.last
  refute comment.nil?, "expected the comment to be saved"
  assert Cybertrain::Stream.max_id > before, "expected a cybertrain_messages row"
  message = last_message
  stream = message[0]
  payload = message[1]
  assert_equal "articles:#{article.id}", stream
  assert_includes payload, "<turbo-stream action=\"append\" target=\"comments\"><template>"
  assert_includes payload, "<div class=\"comment\" id=\"comment_#{comment.id}\">"
  assert_includes payload, "<strong class=\"comment-author\">Dave</strong> wrote:"
  assert_includes payload, "Live &lt;i&gt;now&lt;/i&gt;"
  assert_includes payload, "action=\"#{comments_path(article)}/#{comment.id}\""
end

test "a destroyed comment is broadcast as a Turbo Stream remove of its element" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  doomed = BlogTest.comment(article, "Bob", "Delete me")
  client.get(BlogTest.article_path(article))
  before = Cybertrain::Stream.max_id
  client.post("#{comments_path(article)}/#{doomed.id}", { "_method" => "delete",
                                                          "authenticity_token" => BlogTest.form_token(client) })
  assert_equal 0, Comment.count
  assert Cybertrain::Stream.max_id > before, "expected a cybertrain_messages row"
  message = last_message
  assert_equal "articles:#{article.id}", message[0]
  assert_equal "<turbo-stream action=\"remove\" target=\"comment_#{doomed.id}\"></turbo-stream>", message[1]
end

test "a comment that is not saved broadcasts nothing" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  before = Cybertrain::Stream.max_id
  client.post(comments_path(article), { "authenticity_token" => BlogTest.form_token(client),
                                        "comment[commenter]" => "",
                                        "comment[body]" => "Anonymous words" })
  assert_equal before, Cybertrain::Stream.max_id
end

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

test "a new comment enqueues a NotifyCommentJob, which logs it when performed" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  assert_no_enqueued_jobs
  client.post(comments_path(article), { "authenticity_token" => BlogTest.form_token(client),
                                        "comment[commenter]" => "Dave",
                                        "comment[body]" => "First!" })
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
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get(BlogTest.article_path(article))
  client.post(comments_path(article), { "authenticity_token" => BlogTest.form_token(client),
                                        "comment[commenter]" => "",
                                        "comment[body]" => "Anonymous words" })
  assert_no_enqueued_jobs
end

Cybertrain::Test.run!
