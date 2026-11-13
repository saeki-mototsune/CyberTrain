

# Articles: the Rails Getting Started flows, through the full middleware
# stack (session, CSRF, method override, router). Every test starts from
# test/fixtures: articles(:one) "Hello Rails" with comments(:one), and
# articles(:two) "Second article"; users(:one) is an admin, users(:two)
# writes articles but is not one.
class ArticlesControllerTest < ActionDispatch::IntegrationTest
  def test_GET___renders_the_articles_index; begin
    get "/"
    assert_response :ok
    assert_includes response.body, "<h1>Articles</h1>"
    assert_includes response.body, "Hello Rails"
    assert_includes response.body, "<a href=\"/articles/new\">New article</a>"
  end; nil; end

  def test_GET__articles_lists_every_article_with_a_link_to_it; begin
    first = articles(:one)
    second = articles(:two)
    get "/articles"
    assert_response :ok
    assert_includes response.body, "Hello Rails"
    assert_includes response.body, "Second article"
    assert_includes response.body, "<a href=\"/articles/#{first.id}\">Show</a>"
    assert_includes response.body, "<a href=\"/articles/#{second.id}\">Show</a>"
  end; nil; end

  def test_GET__articles_new_renders_the_form_with_a_CSRF_token; begin
    sign_in_as users(:two)
    get "/articles/new"
    assert_response :ok
    assert_includes response.body, "<form action=\"/articles\" method=\"post\" enctype=\"multipart/form-data\">"
    assert_includes response.body, "name=\"article[title]\""
    assert_includes response.body, "<textarea name=\"article[body]\""
    assert_includes response.body, "value=\"Create Article\""
    assert_includes response.body, "<meta name=\"csrf-token\""
    assert_equal 64, BlogTestHelper.form_token(response.body).size
  end; nil; end

  def test_POST__articles_creates_an_article_and_redirects_to_it_with_a_notice; begin
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
  end; nil; end

  # Forgery protection is off in tests unless config/app.rb sets csrf, as
  # in Rails; the block turns it on for its requests.
  def test_POST__articles_without_the_CSRF_token_is_rejected; begin
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
  end; nil; end

  def test_POST__articles_with_a_blank_title_re_renders_the_form_with_errors; begin
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
  end; nil; end

  def test_POST__articles_with_a_short_body_reports_the_length_error; begin
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
  end; nil; end

  def test_GET__articles__id_shows_the_article; begin
    article = articles(:one)
    article.update_columns(body: "I am on Rails! <script>alert(1)</script>")
    get "/articles/#{article.id}"
    assert_response :ok
    assert_includes response.body, "<h1>Hello Rails</h1>"
    assert_includes response.body, "I am on Rails! &lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes response.body, "<a href=\"/articles/#{article.id}/edit\">Edit</a>"
    assert_includes response.body, "<h2>Comments</h2>"
  end; nil; end

  def test_GET__articles__id_edit_renders_the_form_with_the_article_s_values; begin
    sign_in_as users(:two)
    article = articles(:one)
    get "/articles/#{article.id}/edit"
    assert_response :ok
    assert_includes response.body, "<form action=\"/articles/#{article.id}\" method=\"post\" enctype=\"multipart/form-data\">"
    assert_includes response.body, "<input type=\"hidden\" name=\"_method\" value=\"patch\">"
    assert_includes response.body, "value=\"Hello Rails\""
    assert_includes response.body, "value=\"Update Article\""
  end; nil; end

  def test_PATCH__articles__id__POST_with__method__updates_and_redirects_with_a_notice; begin
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
  end; nil; end

  def test_PATCH__articles__id_with_invalid_values_re_renders_the_edit_form; begin
    sign_in_as users(:two)
    article = articles(:one)
    get "/articles/#{article.id}/edit"
    patch "/articles/#{article.id}", params: { article: { title: "", body: "Still a long enough body." } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<h1>Editing article</h1>"
    assert_includes response.body, "<li>Title can&#39;t be blank</li>"
    assert_equal "Hello Rails", Article.find(article.id).title
  end; nil; end

  def test_DELETE__articles__id__POST_with__method__destroys_and_redirects_to_the_index; begin
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
  end; nil; end

  def test_a_missing_article_is_404; begin
    sign_in_as users(:two)
    get "/articles/999"
    assert_response :not_found
    get "/articles/999/edit"
    assert_response :not_found
    get "/nowhere"
    assert_response :not_found
  end; nil; end

  def test_a_visitor_reads_articles_but_is_sent_to_sign_in_to_write__edit_or_delete_one; begin
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
  end; nil; end

  # articles(:one) has comments(:one) and the comment below: 2.
  def test_the_index_shows_each_article_s_comment_count_from_one_preload; begin
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
  end; nil; end

  def test_a_duplicate_title_is_refused_with_has_already_been_taken; begin
    sign_in_as users(:two)
    get "/articles/new"
    post "/articles", params: { article: { title: "Hello Rails", body: "Another article with the same title." } }
    assert_response :unprocessable_entity
    assert_includes response.body, "<li>Title has already been taken</li>"
    # Only the fixtures: articles(:one) has the title.
    assert_equal 2, Article.count
  end; nil; end

  def test_the_date_filter_leaves_out_articles_created_outside_the_range; begin
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
  end; nil; end

  # One article, so the count is in its singular form: articles(:two) is
  # deleted first.
  def test_the_index_shows_the_article_count__cached_for_a_minute; begin
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
  end; nil; end

  # The fixtures are dated (2024-03-10 and 2024-03-11 09:00 UTC), so their
  # JSON does not depend on the clock; the newer comes first.
  def test__articles_json_and__articles__id_json_answer_JSON_through_respond_to___articles_xml_is_406; begin
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
  end; nil; end

  def test_the_order_select_puts_the_oldest_first_with__order_old; begin
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
  end; nil; end

  # articles(:two) has no comments: its count is 0.
  def test_counts_go_through_number_with_delimiter_and_dates_through_time_tag; begin
    article = articles(:one)
    Cybertrain::Cache.write("articles/count", "1234", expires_in: 60)
    get "/articles"
    assert_includes response.body, "<p class=\"article-count\">1,234 articles</p>"
    assert_includes response.body, "<td class=\"comment-count\">0</td>"

    get "/articles/#{article.id}"
    assert_includes response.body, "<time datetime=\"2024-03-10T09:00:00Z\">March 10, 2024 09:00</time>"
  end; nil; end

  private

  # The JSON of a fixture article, both timestamps at 09:00 UTC on day.
  def article_json(article, title, body, day)
    "{\"id\":#{article.id},\"title\":\"#{title}\",\"body\":\"#{body}\"," \
      "\"created_at\":\"#{day}T09:00:00.000Z\",\"updated_at\":\"#{day}T09:00:00.000Z\"," \
      "\"cover_url\":\"\"}"
  end
end
# Generated by `spin run gen` from test/controllers/articles_controller_test.rb. Do not edit.
