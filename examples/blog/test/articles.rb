# Integration tests for articles: the Rails Getting Started flows, through
# the full middleware stack (session, CSRF, method override, router).
require_relative "support/blog_test"

def new_client
  BlogTest.reset
  Cybertrain::Test::Client.new(BLOG)
end

test "GET / renders the articles index" do
  client = new_client
  BlogTest.article("Hello Rails")
  res = client.get("/")
  assert_response res, :ok
  assert_includes res.body, "<h1>Articles</h1>"
  assert_includes res.body, "Hello Rails"
  assert_includes res.body, "<a href=\"/articles/new\">New article</a>"
end

test "GET /articles lists every article with a link to it" do
  client = new_client
  first = BlogTest.article("First article")
  second = BlogTest.article("Second article")
  res = client.get("/articles")
  assert_response res, :ok
  assert_includes res.body, "First article"
  assert_includes res.body, "Second article"
  assert_includes res.body, "<a href=\"#{BlogTest.article_path(first)}\">Show</a>"
  assert_includes res.body, "<a href=\"#{BlogTest.article_path(second)}\">Show</a>"
end

test "GET /articles/new renders the form with a CSRF token" do
  client = new_client
  res = client.get("/articles/new")
  assert_response res, :ok
  assert_includes res.body, "<form action=\"/articles\" method=\"post\">"
  assert_includes res.body, "name=\"article[title]\""
  assert_includes res.body, "<textarea name=\"article[body]\""
  assert_includes res.body, "value=\"Create Article\""
  assert_includes res.body, "<meta name=\"csrf-token\""
  assert_equal 64, BlogTest.form_token(client).size
end

test "POST /articles creates an article and redirects to it with a notice" do
  client = new_client
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  article = Article.last
  refute article.nil?, "expected the article to be saved"
  assert_equal "Hello Rails", article.title
  assert_redirected_to res, BlogTest.article_path(article)
  assert_response res, :see_other

  res = client.follow_redirect!
  assert_response res, :ok
  assert_includes res.body, "<p class=\"notice\">Article was successfully created.</p>"
  assert_includes res.body, "Hello Rails"
  assert_includes res.body, "I am on Rails! This is my first article."

  res = client.get(BlogTest.article_path(article))
  assert_nil res.body.index("successfully created")
end

test "POST /articles without the CSRF token is rejected" do
  client = new_client
  client.get("/articles/new")
  res = client.post("/articles", { "article[title]" => "Sneaky", "article[body]" => "Posted from another site." })
  assert_response res, :forbidden
  assert_equal 0, Article.count
end

test "POST /articles with a blank title re-renders the form with errors" do
  client = new_client
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "",
                                   "article[body]" => "A body that is long enough." })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<h1>New article</h1>"
  assert_includes res.body, "1 error prohibited this article from being saved:"
  assert_includes res.body, "<li>Title can&#39;t be blank</li>"
  assert_includes res.body, "A body that is long enough."
  assert_equal 0, Article.count
end

test "POST /articles with a short body reports the length error" do
  client = new_client
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Short",
                                   "article[body]" => "Too short" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Body is too short (minimum is 10 characters)</li>"
  assert_includes res.body, "value=\"Short\""

  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "",
                                   "article[body]" => "" })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "3 errors prohibited this article from being saved:"
  assert_includes res.body, "<li>Body can&#39;t be blank</li>"
end

test "GET /articles/:id shows the article" do
  client = new_client
  article = BlogTest.article("Hello Rails", "I am on Rails! <script>alert(1)</script>")
  res = client.get(BlogTest.article_path(article))
  assert_response res, :ok
  assert_includes res.body, "<h1>Hello Rails</h1>"
  assert_includes res.body, "I am on Rails! &lt;script&gt;alert(1)&lt;/script&gt;"
  assert_includes res.body, "<a href=\"#{BlogTest.article_path(article)}/edit\">Edit</a>"
  assert_includes res.body, "<h2>Comments</h2>"
end

test "GET /articles/:id/edit renders the form with the article's values" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  res = client.get("#{BlogTest.article_path(article)}/edit")
  assert_response res, :ok
  assert_includes res.body, "<form action=\"#{BlogTest.article_path(article)}\" method=\"post\">"
  assert_includes res.body, "<input type=\"hidden\" name=\"_method\" value=\"patch\">"
  assert_includes res.body, "value=\"Hello Rails\""
  assert_includes res.body, "value=\"Update Article\""
end

test "PATCH /articles/:id (POST with _method) updates and redirects with a notice" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get("#{BlogTest.article_path(article)}/edit")
  res = client.post(BlogTest.article_path(article), { "_method" => "patch",
                                                      "authenticity_token" => BlogTest.form_token(client),
                                                      "article[title]" => "Hello again",
                                                      "article[body]" => "An updated body for the article." })
  assert_redirected_to res, BlogTest.article_path(article)
  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"notice\">Article was successfully updated.</p>"
  assert_includes res.body, "<h1>Hello again</h1>"
  assert_equal "An updated body for the article.", Article.find(article.id).body
end

test "PATCH /articles/:id with invalid values re-renders the edit form" do
  client = new_client
  article = BlogTest.article("Hello Rails")
  client.get("#{BlogTest.article_path(article)}/edit")
  res = client.patch(BlogTest.article_path(article), { "authenticity_token" => BlogTest.form_token(client),
                                                       "article[title]" => "",
                                                       "article[body]" => "Still a long enough body." })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<h1>Editing article</h1>"
  assert_includes res.body, "<li>Title can&#39;t be blank</li>"
  assert_equal "Hello Rails", Article.find(article.id).title
end

test "DELETE /articles/:id (POST with _method) destroys and redirects to the index" do
  client = new_client
  article = BlogTest.article("Doomed article")
  BlogTest.comment(article)
  client.get(BlogTest.article_path(article))
  res = client.post(BlogTest.article_path(article), { "_method" => "delete",
                                                      "authenticity_token" => BlogTest.form_token(client) })
  assert_redirected_to res, "/articles"
  assert_response res, :see_other
  assert_equal 0, Article.count
  assert_equal 0, Comment.count

  res = client.follow_redirect!
  assert_includes res.body, "<p class=\"notice\">Article was successfully destroyed.</p>"
  assert_nil res.body.index("Doomed article")
end

test "a missing article is 404" do
  client = new_client
  assert_response client.get("/articles/999"), :not_found
  assert_response client.get("/articles/999/edit"), :not_found
  assert_response client.get("/nowhere"), :not_found
end

Cybertrain::Test.run!
