require "test_helper"

# Articles: the Rails Getting Started flows, through the full middleware
# stack (session, CSRF, method override, router). Every test starts from
# test/fixtures: articles(:one) "Hello Rails" with comments(:one), and
# articles(:two) "Second article"; users(:one) is an admin, users(:two)
# writes articles but is not one.
class ArticlesControllerTest < ActionDispatch::IntegrationTest
  test "GET / renders the articles index" do
    get "/"
    assert_response :ok
    assert_includes response.body, "<h1>Articles</h1>"
    assert_includes response.body, "Hello Rails"
    assert_includes response.body, "<a href=\"/articles/new\">New article</a>"
  end

  test "GET /articles lists every article with a link to it" do
    first = articles(:one)
    second = articles(:two)
    get "/articles"
    assert_response :ok
    assert_includes response.body, "Hello Rails"
    assert_includes response.body, "Second article"
    assert_includes response.body, "<a href=\"/articles/#{first.id}\">Show</a>"
    assert_includes response.body, "<a href=\"/articles/#{second.id}\">Show</a>"
  end

  test "GET /articles/new renders the form with a CSRF token" do
    sign_in_as users(:two)
    get "/articles/new"
    assert_response :ok
    assert_includes response.body, "<form action=\"/articles\" method=\"post\" enctype=\"multipart/form-data\">"
    assert_includes response.body, "name=\"article[title]\""
    assert_includes response.body, "<textarea name=\"article[body]\""
    assert_includes response.body, "value=\"Create Article\""
    assert_includes response.body, "<meta name=\"csrf-token\""
    assert_equal 64, BlogTestHelper.form_token(response.body).size
  end

  test "POST /articles creates an article and redirects to it with a notice" do
    sign_in_as users(:two)
    get "/articles/new"
    post "/articles", params: { article: { title: "Getting Started", body: "I am on Rails! This is my first article." } }
    article = Article.last
    refute article.nil?, "expected the article to be saved"
    assert_equal "Getting Started", article.title
    assert_redirected_to "/articles/#{article.id}"
    assert_response :see_other

    follow_redirect!
    assert_response :ok
    assert_includes response.body, "<p class=\"notice\">Article was successfully created.</p>"
    assert_includes response.body, "Getting Started"
    assert_includes response.body, "I am on Rails! This is my first article."

    get "/articles/#{article.id}"
    assert_nil response.body.index("successfully created")
  end

  # Forgery protection is off in tests unless config/app.rb sets csrf, as
  # in Rails; the block turns it on for its requests.
  test "POST /articles without the CSRF token is rejected" do
    sign_in_as users(:two)
    get "/articles/new"
    token = BlogTestHelper.form_token(response.body)
    before = Article.count
    with_forgery_protection do
      post "/articles", params: { article: { title: "Sneaky", body: "Posted from another site." } }
      assert_response :forbidden
      assert_equal before, Article.count
      # The token of the form the page rendered is accepted.
      post "/articles", params: { authenticity_token: token, article: { title: "From the form", body: "Posted from the new article page." } }
      assert_response :see_other
      assert_equal before + 1, Article.count
    end
  end

  test "POST /articles with a blank title re-renders the form with errors" do
    sign_in_as users(:two)
    get "/articles/new"
    before = Article.count
    post "/articles", params: { article: { title: "", body: "A body that is long enough." } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<h1>New article</h1>"
    assert_includes response.body, "1 error prohibited this article from being saved:"
    assert_includes response.body, "<li>Title can&#39;t be blank</li>"
    assert_includes response.body, "A body that is long enough."
    assert_equal before, Article.count
  end

  test "POST /articles with a short body reports the length error" do
    sign_in_as users(:two)
    get "/articles/new"
    post "/articles", params: { article: { title: "Short", body: "Too short" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Body is too short (minimum is 10 characters)</li>"
    assert_includes response.body, "value=\"Short\""

    post "/articles", params: { article: { title: "", body: "" } }
    assert_response :unprocessable_entity
    assert_includes response.body, "3 errors prohibited this article from being saved:"
    assert_includes response.body, "<li>Body can&#39;t be blank</li>"
  end

  test "GET /articles/:id shows the article" do
    article = articles(:one)
    article.update_columns(body: "I am on Rails! <script>alert(1)</script>")
    get "/articles/#{article.id}"
    assert_response :ok
    assert_includes response.body, "<h1>Hello Rails</h1>"
    assert_includes response.body, "I am on Rails! &lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes response.body, "<a href=\"/articles/#{article.id}/edit\">Edit</a>"
    assert_includes response.body, "<h2>Comments</h2>"
  end

  test "GET /articles/:id/edit renders the form with the article's values" do
    sign_in_as users(:two)
    article = articles(:one)
    get "/articles/#{article.id}/edit"
    assert_response :ok
    assert_includes response.body, "<form action=\"/articles/#{article.id}\" method=\"post\" enctype=\"multipart/form-data\">"
    assert_includes response.body, "<input type=\"hidden\" name=\"_method\" value=\"patch\">"
    assert_includes response.body, "value=\"Hello Rails\""
    assert_includes response.body, "value=\"Update Article\""
  end

  test "PATCH /articles/:id (POST with _method) updates and redirects with a notice" do
    sign_in_as users(:two)
    article = articles(:one)
    get "/articles/#{article.id}/edit"
    post "/articles/#{article.id}", params: { _method: "patch",
                                              article: { title: "Hello again", body: "An updated body for the article." } }
    assert_redirected_to "/articles/#{article.id}"
    follow_redirect!
    assert_includes response.body, "<p class=\"notice\">Article was successfully updated.</p>"
    assert_includes response.body, "<h1>Hello again</h1>"
    assert_equal "An updated body for the article.", Article.find(article.id).body
  end

  test "PATCH /articles/:id with invalid values re-renders the edit form" do
    sign_in_as users(:two)
    article = articles(:one)
    get "/articles/#{article.id}/edit"
    patch "/articles/#{article.id}", params: { article: { title: "", body: "Still a long enough body." } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<h1>Editing article</h1>"
    assert_includes response.body, "<li>Title can&#39;t be blank</li>"
    assert_equal "Hello Rails", Article.find(article.id).title
  end

  test "DELETE /articles/:id (POST with _method) destroys and redirects to the index" do
    sign_in_as users(:two)
    article = Article.create(title: "Doomed article", body: "I am on Rails! This is my first article.")
    Comment.create(commenter: "Alice", body: "Great post!", article_id: article.id)
    get "/articles/#{article.id}"
    post "/articles/#{article.id}", params: { _method: "delete" }
    assert_redirected_to "/articles"
    assert_response :see_other
    # The fixtures are what is left: the article and its comment are gone.
    assert_equal 2, Article.count
    assert_equal 1, Comment.count

    follow_redirect!
    assert_includes response.body, "<p class=\"notice\">Article was successfully destroyed.</p>"
    assert_nil response.body.index("Doomed article")
  end

  test "a missing article is 404" do
    sign_in_as users(:two)
    get "/articles/999"
    assert_response :not_found
    get "/articles/999/edit"
    assert_response :not_found
    get "/nowhere"
    assert_response :not_found
  end

  test "a visitor reads articles but is sent to sign in to write, edit or delete one" do
    article = articles(:one)
    get "/articles"
    assert_response :ok
    get "/articles/#{article.id}"
    assert_response :ok
    ["/articles/new", "/articles/#{article.id}/edit"].each do |path|
      get path
      assert_redirected_to "/session/new"
      assert_response :see_other
    end
    post "/articles", params: { article: { title: "By a visitor", body: "Nobody signed in wrote this." } }
    assert_redirected_to "/session/new"
    patch "/articles/#{article.id}", params: { article: { title: "Defaced", body: "Nobody signed in wrote this." } }
    assert_redirected_to "/session/new"
    delete "/articles/#{article.id}"
    assert_redirected_to "/session/new"
    # Nothing written: the two fixtures, unchanged.
    assert_equal 2, Article.count
    assert_equal "Hello Rails", Article.find(article.id).title

    # Signed in, the form the visitor asked for is where the browser goes back to.
    get "/articles/new"
    sign_in_as users(:two)
    assert_redirected_to "/articles/new"
    follow_redirect!
    assert_response :ok
    assert_includes response.body, "<h1>New article</h1>"
    assert_includes response.body, "<span>two@example.com</span>"
  end

  # articles(:one) has comments(:one) and the comment below: 2.
  test "the index shows each article's comment count from one preload" do
    article = articles(:one)
    Comment.create(commenter: "Bob", body: "Second!", article_id: article.id)
    # A first request fills the cached article count; after it the count is
    # one SELECT of cybertrain_cache.
    get "/articles"
    before = BlogTestHelper.statements_run_total
    get "/articles"
    two_articles = BlogTestHelper.statements_run_total - before
    assert_response :ok
    assert_includes response.body, "<th>Comments</th>"
    assert_includes response.body, "<td class=\"comment-count\">2</td>"

    Article.create(title: "Third article", body: "I am on Rails! This is my first article.")
    Article.create(title: "Fourth article", body: "I am on Rails! This is my first article.")
    before = BlogTestHelper.statements_run_total
    get "/articles"
    assert_equal two_articles, BlogTestHelper.statements_run_total - before
    # The articles, their comments, and the cached count.
    assert_equal 3, two_articles
    assert_includes response.body, "<td class=\"comment-count\">0</td>"
  end

  test "a duplicate title is refused with has already been taken" do
    sign_in_as users(:two)
    get "/articles/new"
    post "/articles", params: { article: { title: "Hello Rails", body: "Another article with the same title." } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Title has already been taken</li>"
    # Only the fixtures: articles(:one) has the title.
    assert_equal 2, Article.count
  end

  test "the date filter leaves out articles created outside the range" do
    early = Article.create(title: "Early article", body: "I am on Rails! This is my first article.")
    inside = Article.create(title: "Inside article", body: "I am on Rails! This is my first article.")
    last_day = Article.create(title: "Last day article", body: "I am on Rails! This is my first article.")
    late = Article.create(title: "Late article", body: "I am on Rails! This is my first article.")
    early.update_columns(created_at: Time.utc(2024, 3, 9, 23, 59, 59))
    inside.update_columns(created_at: Time.utc(2024, 3, 10, 0, 0, 0))
    last_day.update_columns(created_at: Time.utc(2024, 3, 20, 23, 59, 59))
    late.update_columns(created_at: Time.utc(2024, 3, 21, 0, 0, 0))

    get "/articles"
    assert_includes response.body, "<form action=\"/articles\" method=\"get\">"
    assert_includes response.body, "<input type=\"date\" name=\"from\" id=\"from\">"
    assert_includes response.body, "<input type=\"date\" name=\"to\" id=\"to\">"
    assert_includes response.body, "Early article"

    get "/articles?from=2024-03-10&to=2024-03-20"
    assert_response :ok
    assert_nil response.body.index("Early article")
    assert_includes response.body, "Inside article"
    assert_includes response.body, "Last day article"
    assert_nil response.body.index("Late article")
    assert_includes response.body, "<input type=\"date\" name=\"from\" id=\"from\" value=\"2024-03-10\">"

    get "/articles?from=2024-03-21"
    assert_nil response.body.index("Inside article")
    assert_includes response.body, "Late article"

    get "/articles?to=2024-03-09"
    assert_includes response.body, "Early article"
    assert_nil response.body.index("Inside article")

    get "/articles?from=not-a-date&to="
    assert_includes response.body, "Early article"
    assert_includes response.body, "Late article"
  end

  # One article, so the count is in its singular form: articles(:two) is
  # deleted first.
  test "the index shows the article count, cached for a minute" do
    articles(:two).destroy
    get "/articles"
    assert_includes response.body, "<p class=\"article-count\">1 article</p>"
    Article.create(title: "Third article", body: "I am on Rails! This is my first article.")
    get "/articles"
    assert_includes response.body, "Third article"
    assert_includes response.body, "<p class=\"article-count\">1 article</p>"
    Cybertrain::Cache.delete("articles/count")
    get "/articles"
    assert_includes response.body, "<p class=\"article-count\">2 articles</p>"
  end

  # The fixtures are dated (2024-03-10 and 2024-03-11 09:00 UTC), so their
  # JSON does not depend on the clock; the newer comes first.
  test "/articles.json and /articles/:id.json answer JSON through respond_to; /articles.xml is 406" do
    first = articles(:one)
    second = articles(:two)
    get "/articles.json"
    assert_response :ok
    assert_equal "application/json; charset=utf-8", response.header("Content-Type").to_s
    assert_equal "[#{article_json(second, "Second article", "Another article, with no comments.", "2024-03-11")}," \
                 "#{article_json(first, "Hello Rails", "I am on Rails! This is my first article.", "2024-03-10")}]", response.body

    get "/articles/#{first.id}.json"
    assert_response :ok
    assert_equal "application/json; charset=utf-8", response.header("Content-Type").to_s
    assert_equal article_json(first, "Hello Rails", "I am on Rails! This is my first article.", "2024-03-10"), response.body

    get "/articles", headers: { "Accept" => "application/json" }
    assert_equal "application/json; charset=utf-8", response.header("Content-Type").to_s

    get "/articles.xml"
    assert_response :not_acceptable
    assert_equal "Not Acceptable", response.body
    get "/articles/#{first.id}.xml"
    assert_response :not_acceptable
    get "/articles/999.json"
    assert_response :not_found
  end

  test "the order select puts the oldest first with ?order=old" do
    older = Article.create(title: "Older article", body: "I am on Rails! This is my first article.")
    newer = Article.create(title: "Newer article", body: "I am on Rails! This is my first article.")
    older.update_columns(created_at: Time.utc(2024, 1, 1, 0, 0, 0))
    newer.update_columns(created_at: Time.utc(2024, 6, 1, 0, 0, 0))

    get "/articles"
    assert_includes response.body, "<select name=\"order\" id=\"order\"><option selected=\"selected\" value=\"new\">Newest first</option>\n" \
                                   "<option value=\"old\">Oldest first</option></select>"
    assert response.body.index("Newer article").to_i < response.body.index("Older article").to_i, "newest first by default"

    get "/articles?order=old"
    assert_includes response.body, "<option value=\"new\">Newest first</option>\n<option selected=\"selected\" value=\"old\">Oldest first</option>"
    assert response.body.index("Older article").to_i < response.body.index("Newer article").to_i, "oldest first"

    get "/articles?order=sideways"
    assert_includes response.body, "<option selected=\"selected\" value=\"new\">Newest first</option>"
  end

  # articles(:two) has no comments: its count is 0.
  test "counts go through number_with_delimiter and dates through time_tag" do
    article = articles(:one)
    Cybertrain::Cache.write("articles/count", "1234", expires_in: 60)
    get "/articles"
    assert_includes response.body, "<p class=\"article-count\">1,234 articles</p>"
    assert_includes response.body, "<td class=\"comment-count\">0</td>"

    get "/articles/#{article.id}"
    assert_includes response.body, "<time datetime=\"2024-03-10T09:00:00Z\">March 10, 2024 09:00</time>"
  end

  private

  # The JSON of a fixture article, both timestamps at 09:00 UTC on day.
  def article_json(article, title, body, day)
    "{\"id\":#{article.id},\"title\":\"#{title}\",\"body\":\"#{body}\"," \
      "\"created_at\":\"#{day}T09:00:00.000Z\",\"updated_at\":\"#{day}T09:00:00.000Z\"," \
      "\"cover_url\":\"\"}"
  end
end
