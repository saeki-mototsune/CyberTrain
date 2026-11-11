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

# Every statement run so far, over the pool's connections (requests and
# the test share them).
def statements
  pool = Cybertrain::DB.pool
  total = 0
  i = 0
  while i < pool.size
    total += pool.connection_at(i).statements_run
    i += 1
  end
  total
end

test "the index shows each article's comment count from one preload" do
  client = new_client
  article = BlogTest.article("Commented article")
  BlogTest.comment(article, "Alice", "First!")
  BlogTest.comment(article, "Bob", "Second!")
  # A first request fills the cached article count; after it the count is
  # one SELECT of cybertrain_cache.
  client.get("/articles")
  before = statements
  res = client.get("/articles")
  one_article = statements - before
  assert_response res, :ok
  assert_includes res.body, "<th>Comments</th>"
  assert_includes res.body, "<td class=\"comment-count\">2</td>"

  BlogTest.article("Second article")
  BlogTest.article("Third article")
  before = statements
  res = client.get("/articles")
  assert_equal one_article, statements - before
  # The articles, their comments, and the cached count.
  assert_equal 3, one_article
  assert_includes res.body, "<td class=\"comment-count\">0</td>"
end

test "destroying an article destroys its comments" do
  BlogTest.reset
  article = BlogTest.article("Doomed article")
  kept = BlogTest.article("Kept article")
  BlogTest.comment(article, "Alice", "Going")
  BlogTest.comment(article, "Bob", "Going too")
  BlogTest.comment(kept, "Carol", "Staying")
  article.destroy
  assert_equal 1, Article.count
  assert_equal 1, Comment.count
  assert_equal "Staying", Comment.first.body
end

test "a duplicate title is refused with has already been taken" do
  client = new_client
  BlogTest.article("Hello Rails")
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "Another article with the same title." })
  assert_response res, :unprocessable_entity
  assert_includes res.body, "<li>Title has already been taken</li>"
  assert_equal 1, Article.count
end

test "the date filter leaves out articles created outside the range" do
  client = new_client
  early = BlogTest.article("Early article")
  inside = BlogTest.article("Inside article")
  last_day = BlogTest.article("Last day article")
  late = BlogTest.article("Late article")
  early.update_columns(created_at: Time.utc(2024, 3, 9, 23, 59, 59))
  inside.update_columns(created_at: Time.utc(2024, 3, 10, 0, 0, 0))
  last_day.update_columns(created_at: Time.utc(2024, 3, 20, 23, 59, 59))
  late.update_columns(created_at: Time.utc(2024, 3, 21, 0, 0, 0))

  res = client.get("/articles")
  assert_includes res.body, "<form action=\"/articles\" method=\"get\">"
  assert_includes res.body, "<input type=\"date\" name=\"from\" id=\"from\">"
  assert_includes res.body, "<input type=\"date\" name=\"to\" id=\"to\">"
  assert_includes res.body, "Early article"

  res = client.get("/articles?from=2024-03-10&to=2024-03-20")
  assert_response res, :ok
  assert_nil res.body.index("Early article")
  assert_includes res.body, "Inside article"
  assert_includes res.body, "Last day article"
  assert_nil res.body.index("Late article")
  assert_includes res.body, "<input type=\"date\" name=\"from\" id=\"from\" value=\"2024-03-10\">"

  res = client.get("/articles?from=2024-03-21")
  assert_nil res.body.index("Inside article")
  assert_includes res.body, "Late article"

  res = client.get("/articles?to=2024-03-09")
  assert_includes res.body, "Early article"
  assert_nil res.body.index("Inside article")

  res = client.get("/articles?from=not-a-date&to=")
  assert_includes res.body, "Early article"
  assert_includes res.body, "Late article"
end

test "Article.recent puts the newest first" do
  BlogTest.reset
  older = BlogTest.article("Older article")
  newer = BlogTest.article("Newer article")
  older.update_columns(created_at: Time.utc(2024, 1, 1, 0, 0, 0))
  newer.update_columns(created_at: Time.utc(2024, 6, 1, 0, 0, 0))
  assert_equal newer.id, Article.recent.first.id
  assert_equal ["Newer article", "Older article"], Article.recent.to_a.map { |a| a.title }
end

test "the index shows the article count, cached for a minute" do
  client = new_client
  BlogTest.article("First article")
  res = client.get("/articles")
  assert_includes res.body, "<p class=\"article-count\">1 article</p>"
  BlogTest.article("Second article")
  res = client.get("/articles")
  assert_includes res.body, "Second article"
  assert_includes res.body, "<p class=\"article-count\">1 article</p>"
  Cybertrain::Cache.delete("articles/count")
  res = client.get("/articles")
  assert_includes res.body, "<p class=\"article-count\">2 articles</p>"
end

# The jobs page (config/routes.rb: jobs_page "/admin/jobs", before_action:
# :require_admin) and the login that opens it. BLOG_ADMIN_TOKEN is unset at
# the start of every test (BlogTest.reset).
ADMIN_TOKEN = "blog-admin-s3cret"

def admin_header(token)
  { "x-admin-token" => token }
end

# Posts `token` to /admin/login with the session's CSRF token, taken from
# the new-article form (the login form is 404 while BLOG_ADMIN_TOKEN is
# unset or empty).
def admin_login(client, token)
  client.get("/articles/new")
  client.post("/admin/login", { "authenticity_token" => BlogTest.form_token(client), "token" => token })
end

test "the jobs page is 404 without the token and renders with the x-admin-token header" do
  client = new_client
  assert_response client.get("/admin/jobs"), :not_found
  assert_response client.get("/admin/jobs", admin_header(ADMIN_TOKEN)), :not_found
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  assert_response client.get("/admin/jobs"), :not_found
  assert_response client.get("/admin/jobs", admin_header("wrong")), :not_found
  failed = BlogTest.failed_job
  res = client.get("/admin/jobs", admin_header(ADMIN_TOKEN))
  assert_response res, :ok
  assert_includes res.body, "<title>Blog</title>"
  assert_includes res.body, "<h1>Jobs</h1>"
  assert_includes res.body, "<td>NotifyCommentJob</td>"
  assert_includes res.body, "action=\"/admin/jobs/#{failed}/retry\""
end

test "retry, discard and delete are 404 without a token and without the session" do
  client = new_client
  failed = BlogTest.failed_job
  client.get("/articles/new")
  csrf = BlogTest.form_token(client)
  ["retry", "discard", "delete"].each do |action|
    res = client.post("/admin/jobs/#{failed}/#{action}", { "authenticity_token" => csrf }, admin_header(""))
    assert_response res, :not_found
  end
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  ["retry", "discard", "delete"].each do |action|
    res = client.post("/admin/jobs/#{failed}/#{action}", { "authenticity_token" => csrf })
    assert_response res, :not_found
    assert_equal "failed", BlogTest.job_state(failed)
  end
  assert_response client.post("/admin/jobs/retry_all", { "authenticity_token" => csrf }), :not_found
  assert_response client.post("/admin/jobs/discard_all", { "authenticity_token" => csrf }), :not_found
  assert_equal "failed", BlogTest.job_state(failed)
end

test "a browser signs in at /admin/login and retries a job through its session" do
  client = new_client
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  failed = BlogTest.failed_job
  assert_response client.get("/admin/jobs"), :not_found

  res = client.get("/admin/login")
  assert_response res, :ok
  assert_includes res.body, "<form action=\"/admin/login\" method=\"post\">"
  assert_includes res.body, "<input type=\"password\" name=\"token\" id=\"token\">"
  res = client.post("/admin/login", { "authenticity_token" => BlogTest.form_token(client), "token" => ADMIN_TOKEN })
  assert_redirected_to res, "/admin/jobs"
  assert_response res, :see_other
  session = BlogTest.session_of(client)
  assert_equal Cybertrain::Crypto.hmac_hex(Cybertrain.config.secret_key_base, ADMIN_TOKEN), session["admin"].to_s

  res = client.get("/admin/jobs")
  assert_response res, :ok
  assert_includes res.body, "<h1>Jobs</h1>"
  csrf = BlogTest.form_token(client)
  res = client.post("/admin/jobs/#{failed}/retry", { "authenticity_token" => csrf })
  assert_redirected_to res, "/admin/jobs"
  assert_response res, :see_other
  assert_equal "queued", BlogTest.job_state(failed)
  res = client.follow_redirect!
  assert_response res, :ok
  assert_includes res.body, "<p class=\"notice\">Job #{failed} was queued again.</p>"

  again = BlogTest.failed_job
  client.get("/admin/jobs")
  csrf = BlogTest.form_token(client)
  client.post("/admin/jobs/#{again}/discard", { "authenticity_token" => csrf })
  assert_equal "discarded", BlogTest.job_state(again)
  client.post("/admin/jobs/#{again}/delete", { "authenticity_token" => csrf })
  assert_equal "(gone)", BlogTest.job_state(again)
end

test "a wrong token at /admin/login is 404 and signs nobody in" do
  client = new_client
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  res = admin_login(client, "not-the-token")
  assert_response res, :not_found
  refute BlogTest.session_of(client).key?("admin"), "no admin session"
  assert_response client.get("/admin/jobs"), :not_found
  res = admin_login(client, "")
  assert_response res, :not_found
  refute BlogTest.session_of(client).key?("admin"), "no admin session"
end

test "with BLOG_ADMIN_TOKEN unset or empty nothing opens the jobs page" do
  client = new_client
  assert_response client.get("/admin/login"), :not_found
  assert_response client.get("/admin/jobs", admin_header("")), :not_found
  res = admin_login(client, "")
  assert_response res, :not_found
  refute BlogTest.session_of(client).key?("admin"), "no admin session"

  ENV["BLOG_ADMIN_TOKEN"] = ""
  assert_response client.get("/admin/login"), :not_found
  assert_response client.get("/admin/jobs", admin_header("")), :not_found
  assert_response client.get("/admin/jobs"), :not_found
  res = admin_login(client, "")
  assert_response res, :not_found
  refute BlogTest.session_of(client).key?("admin"), "no admin session"
  assert_response client.get("/admin/jobs"), :not_found
end

test "an admin session is 404 once BLOG_ADMIN_TOKEN changes" do
  client = new_client
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  assert_redirected_to admin_login(client, ADMIN_TOKEN), "/admin/jobs"
  assert_response client.get("/admin/jobs"), :ok
  ENV["BLOG_ADMIN_TOKEN"] = "a-rotated-token"
  assert_response client.get("/admin/jobs"), :not_found
  ENV["BLOG_ADMIN_TOKEN"] = ""
  assert_response client.get("/admin/jobs"), :not_found
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  assert_response client.get("/admin/jobs"), :ok
end

# A NotifyCommentJob row that has run (`done`), last updated `days_ago`
# days ago.
def done_job(days_ago)
  id = Cybertrain::Job.enqueue("NotifyCommentJob", "{\"comment_id\":1,\"article_id\":1}")
  Cybertrain::DB.with do |c|
    c.execute("UPDATE cybertrain_jobs SET state = 'done', updated_at = ? WHERE id = ?",
              Cybertrain::Cast.binds(Time.now.to_i - days_ago * 86_400, id))
  end
  id
end

test "config/app.rb schedules the prune of done jobs, which keeps the last 7 days" do
  BlogTest.reset
  index = Cybertrain::Scheduler.task_index("prune done jobs")
  assert index >= 0, "expected the task \"prune done jobs\""
  old = done_job(8)
  recent = done_job(6)
  failed = BlogTest.failed_job
  Cybertrain::DB.with { |c| c.execute("UPDATE cybertrain_jobs SET updated_at = 0 WHERE id = ?", [failed]) }
  assert Cybertrain::Scheduler.run_task(Cybertrain::Scheduler::TASKS[index]), "the task ran without raising"
  assert_equal "(gone)", BlogTest.job_state(old)
  assert_equal "done", BlogTest.job_state(recent)
  assert_equal "failed", BlogTest.job_state(failed)
end

# The text of body between `marker` and the next `stop` after it ("" when
# the marker is not there).
def text_after(body, marker, stop)
  at = body.index(marker)
  return "" if at.nil?

  start = at + marker.size
  finish = body.index(stop, start)
  return "" if finish.nil?

  body[start, finish - start].to_s
end

def hex8?(text)
  return false unless text.size == 8

  text.each_char { |ch| return false unless "0123456789abcdef".include?(ch) }
  true
end

# An article with both timestamps at 2024-03-10 09:00 UTC, for JSON bodies
# and <time> tags that do not depend on the clock.
def dated_article(title, body = "I am on Rails! This is my first article.")
  article = BlogTest.article(title, body)
  at = Time.utc(2024, 3, 10, 9, 0, 0)
  article.update_columns(created_at: at, updated_at: at)
  article
end

def article_json(article, title, body = "I am on Rails! This is my first article.")
  "{\"id\":#{article.id},\"title\":\"#{title}\",\"body\":\"#{body}\"," \
    "\"created_at\":\"2024-03-10T09:00:00.000Z\",\"updated_at\":\"2024-03-10T09:00:00.000Z\"}"
end

test "/articles.json and /articles/:id.json answer JSON through respond_to; /articles.xml is 406" do
  client = new_client
  first = dated_article("First article")
  second = dated_article("Second article")
  res = client.get("/articles.json")
  assert_response res, :ok
  assert_equal "application/json; charset=utf-8", res.header("Content-Type").to_s
  # Equal created_at: the newer id first is not promised, so either order.
  one = "[#{article_json(first, "First article")},#{article_json(second, "Second article")}]"
  other = "[#{article_json(second, "Second article")},#{article_json(first, "First article")}]"
  assert res.body == one || res.body == other, "unexpected /articles.json body: #{res.body}"

  res = client.get("/articles/#{first.id}.json")
  assert_response res, :ok
  assert_equal "application/json; charset=utf-8", res.header("Content-Type").to_s
  assert_equal article_json(first, "First article"), res.body

  res = client.get("/articles", { "Accept" => "application/json" })
  assert_equal "application/json; charset=utf-8", res.header("Content-Type").to_s

  res = client.get("/articles.xml")
  assert_response res, :not_acceptable
  assert_equal "Not Acceptable", res.body
  assert_response client.get("/articles/#{first.id}.xml"), :not_acceptable
  assert_response client.get("/articles/999.json"), :not_found
end

test "the layout links the digested stylesheet, which is served immutable with its url() digested" do
  client = new_client
  res = client.get("/articles")
  digest = text_after(res.body, "<link rel=\"stylesheet\" href=\"/assets/application-", ".css\">")
  assert hex8?(digest), "expected /assets/application-<8 hex>.css in the layout, got #{digest.inspect}"
  assert_nil res.body.index("/style.css")

  css = client.get("/assets/application-#{digest}.css")
  assert_response css, :ok
  assert_equal "text/css; charset=utf-8", css.header("Content-Type").to_s
  assert_equal "public, max-age=31536000, immutable", css.header("Cache-Control").to_s
  assert_includes css.body, "form.button_to { display: inline; }"
  logo = text_after(css.body, "url(\"/assets/logo-", ".svg\")")
  assert hex8?(logo), "expected the logo's url() digested, got #{logo.inspect}"
  svg = client.get("/assets/logo-#{logo}.svg")
  assert_response svg, :ok
  assert_equal "public, max-age=31536000, immutable", svg.header("Cache-Control").to_s
  assert_includes svg.body, "<svg"
end

test "the import map pins Turbo and the application entry point, with the CSP nonce" do
  client = new_client
  res = client.get("/articles")
  turbo = "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
  assert_includes res.body, "\"@hotwired/turbo\":\"#{turbo}\""
  assert_includes res.body, "<link rel=\"modulepreload\" href=\"#{turbo}\""
  app = text_after(res.body, "\"application\":\"/assets/application-", ".js\"")
  assert hex8?(app), "expected the application entry point digested, got #{app.inspect}"
  js = client.get("/assets/application-#{app}.js")
  assert_response js, :ok
  assert_includes js.body, "import \"@hotwired/turbo\""

  nonce = text_after(res.body, "<meta name=\"csp-nonce\" content=\"", "\"")
  refute nonce.empty?, "expected a csp-nonce meta tag"
  assert_includes res.body, "<script type=\"importmap\" data-turbo-track=\"reload\" nonce=\"#{nonce}\">"
  assert_includes res.body, "<script type=\"module\" nonce=\"#{nonce}\">import \"application\"</script>"
  csp = res.header("Content-Security-Policy").to_s
  assert_includes csp, "default-src 'self'"
  assert_includes csp, "script-src 'self' https://cdn.jsdelivr.net 'nonce-#{nonce}'"
  assert_includes csp, "style-src 'self' 'nonce-#{nonce}'"
  assert_includes csp, "img-src 'self' data:"

  again = text_after(client.get("/articles").body, "<meta name=\"csp-nonce\" content=\"", "\"")
  refute again == nonce, "a new nonce per response"
end

test "the order select puts the oldest first with ?order=old" do
  client = new_client
  older = BlogTest.article("Older article")
  newer = BlogTest.article("Newer article")
  older.update_columns(created_at: Time.utc(2024, 1, 1, 0, 0, 0))
  newer.update_columns(created_at: Time.utc(2024, 6, 1, 0, 0, 0))

  res = client.get("/articles")
  assert_includes res.body, "<select name=\"order\" id=\"order\"><option selected=\"selected\" value=\"new\">Newest first</option>\n" \
                            "<option value=\"old\">Oldest first</option></select>"
  assert res.body.index("Newer article").to_i < res.body.index("Older article").to_i, "newest first by default"

  res = client.get("/articles?order=old")
  assert_includes res.body, "<option value=\"new\">Newest first</option>\n<option selected=\"selected\" value=\"old\">Oldest first</option>"
  assert res.body.index("Older article").to_i < res.body.index("Newer article").to_i, "oldest first"

  res = client.get("/articles?order=sideways")
  assert_includes res.body, "<option selected=\"selected\" value=\"new\">Newest first</option>"
end

test "counts go through number_with_delimiter and dates through time_tag" do
  client = new_client
  article = dated_article("Hello Rails")
  Cybertrain::Cache.write("articles/count", "1234", expires_in: 60)
  res = client.get("/articles")
  assert_includes res.body, "<p class=\"article-count\">1,234 articles</p>"
  assert_includes res.body, "<td class=\"comment-count\">0</td>"

  res = client.get(BlogTest.article_path(article))
  assert_includes res.body, "<time datetime=\"2024-03-10T09:00:00Z\">March 10, 2024 09:00</time>"
end

# /admin/articles: Admin::ArticlesController, behind the AdminGate concern
# (ApplicationController#require_admin, as the jobs page).
test "/admin/articles is 404 without the token and lists the articles with it" do
  client = new_client
  first = dated_article("First article")
  BlogTest.article("Second article")
  assert_response client.get("/admin/articles"), :not_found
  assert_response client.get("/admin/articles", admin_header(ADMIN_TOKEN)), :not_found
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  assert_response client.get("/admin/articles"), :not_found
  assert_response client.get("/admin/articles", admin_header("wrong")), :not_found
  assert_response client.get("/admin/articles", admin_header("")), :not_found

  res = client.get("/admin/articles", admin_header(ADMIN_TOKEN))
  assert_response res, :ok
  assert_includes res.body, "<title>Blog</title>"
  assert_includes res.body, "<h1>Admin: articles</h1>"
  assert_includes res.body, "<p class=\"admin-count\">2 articles</p>"
  assert_includes res.body, "First article"
  assert_includes res.body, "Second article"
  assert_includes res.body, "<time datetime=\"2024-03-10T09:00:00Z\">March 10, 2024 09:00</time>"
  assert_includes res.body, "<form class=\"button_to\" method=\"post\" action=\"/admin/articles/#{first.id}\">"
  assert_includes res.body, "<a href=\"/admin/jobs\">Jobs</a>"

  # The jobs page, now drawn inside the namespace, keeps its gate.
  assert_response client.get("/admin/jobs"), :not_found
  assert_response client.get("/admin/jobs", admin_header(ADMIN_TOKEN)), :ok
  # Only index and destroy are drawn.
  assert_response client.get("/admin/articles/#{first.id}", admin_header(ADMIN_TOKEN)), :not_found
end

test "the admin list shows at most per_page (20) articles, newest first" do
  client = new_client
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  i = 1
  while i <= 21
    article = BlogTest.article("Numbered article #{i}")
    article.update_columns(created_at: Time.utc(2024, 1, i, 0, 0, 0))
    i += 1
  end
  assert_equal 20, Admin::ArticlesController.per_page
  res = client.get("/admin/articles", admin_header(ADMIN_TOKEN))
  assert_includes res.body, "<p class=\"admin-count\">21 articles</p>"
  assert_includes res.body, "Numbered article 21"
  assert_includes res.body, "Numbered article 2<"
  assert_nil res.body.index("Numbered article 1<")
  assert res.body.index("Numbered article 21").to_i < res.body.index("Numbered article 20").to_i, "newest first"
end

test "DELETE /admin/articles/:id with the token deletes the article; without it, 404" do
  client = new_client
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  doomed = BlogTest.article("Doomed article")
  BlogTest.comment(doomed)
  kept = BlogTest.article("Kept article")
  client.get("/admin/articles", admin_header(ADMIN_TOKEN))
  csrf = BlogTest.form_token(client)

  res = client.delete("/admin/articles/#{doomed.id}", { "authenticity_token" => csrf })
  assert_response res, :not_found
  res = client.delete("/admin/articles/#{doomed.id}", { "authenticity_token" => csrf }, admin_header("wrong"))
  assert_response res, :not_found
  assert_equal 2, Article.count

  res = client.post("/admin/articles/#{doomed.id}", { "_method" => "delete", "authenticity_token" => csrf },
                    admin_header(ADMIN_TOKEN))
  assert_redirected_to res, "/admin/articles"
  assert_response res, :see_other
  assert_equal 1, Article.count
  assert_equal kept.id, Article.first.id
  assert_equal 0, Comment.count
  assert_response client.delete("/admin/articles/#{doomed.id}", { "authenticity_token" => csrf }, admin_header(ADMIN_TOKEN)),
                  :not_found
end

test "a signed-in browser reaches /admin/articles, and the article page links to it" do
  client = new_client
  ENV["BLOG_ADMIN_TOKEN"] = ADMIN_TOKEN
  article = BlogTest.article("Hello Rails")
  res = client.get(BlogTest.article_path(article))
  assert_nil res.body.index("/admin/articles")
  admin_login(client, ADMIN_TOKEN)
  res = client.get("/admin/articles")
  assert_response res, :ok
  assert_includes res.body, "Hello Rails"
  res = client.get(BlogTest.article_path(article))
  assert_includes res.body, "<a href=\"/admin/articles\">Manage articles</a>"
  ENV["BLOG_ADMIN_TOKEN"] = "a-rotated-token"
  assert_response client.get("/admin/articles"), :not_found
  assert_nil client.get(BlogTest.article_path(article)).body.index("/admin/articles")
end

Cybertrain::Test.run!
