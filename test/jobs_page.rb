require "tmpdir"
require "stringio"
require "cybertrain"
require "cybertrain/mailer"
require "cybertrain/test"
require "cybertrain/test/client"

# The jobs page (`jobs_page "/admin/jobs", before_action: :require_admin`
# in the fixture's config/routes.rb) through the test client: the checked-in
# gen/routes.rb and gen/controllers.rb (CybertrainJobsController <
# ApplicationController), loaded by gen/app.rb, behind a booted
# Application (sessions, CSRF, a layout from a temporary app/views), on an
# in-memory database. Cybertrain::JobsPage's row actions are called
# directly too. SQLite is FFI, so the snapshot comes from the compiled
# binary (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_app/gen/app"

DB = Cybertrain::DB
JobsPage = Cybertrain::JobsPage

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

VIEWS = Dir.mktmpdir("cybertrain-jobs-page")
Dir.mkdir("#{VIEWS}/layouts")
File.write("#{VIEWS}/layouts/application.html.erb",
           "<html><%= csrf_meta_tags %><% if flash[:notice] %><p class=\"notice\"><%= flash[:notice] %></p><% end %>\n<%= yield %></html>\n")
at_exit do
  File.delete("#{VIEWS}/layouts/application.html.erb")
  Dir.rmdir("#{VIEWS}/layouts")
  Dir.rmdir(VIEWS)
end

config = Cybertrain::Config.new
config.env = "test"
config.database_path = ":memory:"
config.pool_size = 1
config.secret_key_base = "jobs-page-secret"
config.encryption_key = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
config.log_level = :none
config.static_files = false
config.views_root = VIEWS
Cybertrain.config = config
APP = Cybertrain::Application.new(router: Gen::Routes.build(Cybertrain::Router.new), url_resolver: Gen::Routes.url_resolver, config: config)
APP.boot

def clear_jobs
  Cybertrain::Job.install!
  DB.with { |c| c.execute("DELETE FROM cybertrain_jobs") }
  nil
end

# A WelcomeJob row (keyed by user_id) put into `state` with an error.
def job_in(state, user_id, error)
  id = WelcomeJob.perform_later({ "user_id" => user_id, "mode" => "ok" })
  DB.with do |c|
    c.execute("UPDATE cybertrain_jobs SET state = ?, attempts = 5, last_error = ?, run_at = 1000, updated_at = 2000 WHERE id = ?",
              Cybertrain::Cast.binds(state, error, id))
  end
  id
end

def job_value(id, column)
  rows = DB.with { |c| c.execute("SELECT #{column} AS v FROM cybertrain_jobs WHERE id = ?", [id]) }
  return "(gone)" if rows.empty?

  Cybertrain::Cast.str(rows[0]["v"])
end

def job_count
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs") }
  Cybertrain::Cast.int(rows[0]["n"])
end

# The value of the first `name="authenticity_token"` field in body.
def form_token(body)
  marker = "name=\"authenticity_token\" value=\""
  start = body.index(marker)
  return "" if start.nil?

  from = start + marker.length
  body[from, body.index("\"", from).to_i - from].to_s
end

# A client that loaded the page as an admin, and the token of its forms.
def admin_client
  client = Cybertrain::Test::Client.new(APP)
  res = client.get("/admin/jobs?admin=1")
  [client, form_token(res.body)]
end

test "the page lists counts and failed rows, and the before_action applies" do
  clear_jobs
  failed = job_in("failed", 7, "Net::SMTPError: <b>smtp</b> timed out")
  job_in("queued", 8, "")
  client = Cybertrain::Test::Client.new(APP)
  assert_redirected_to client.get("/admin/jobs"), "/"
  res = client.get("/admin/jobs?admin=1")
  assert_response res, :ok
  body = res.body
  assert body.start_with?("<html><meta name=\"csrf-param\""), "rendered in the application's layout"
  assert_includes body, "<h1>Jobs</h1>"
  assert_includes body, "<tr><td>failed</td><td>1</td></tr>"
  assert_includes body, "<tr><td>queued</td><td>1</td></tr>"
  assert_includes body, "<td>WelcomeJob</td>"
  assert_includes body, "<td>{&quot;user_id&quot;:7,&quot;mode&quot;:&quot;ok&quot;}</td>"
  assert_includes body, "<td>Net::SMTPError: &lt;b&gt;smtp&lt;/b&gt; timed out</td>"
  refute body.include?("<b>smtp</b>"), "the error is escaped"
  assert_includes body, "<form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{failed}/retry\"><input type=\"hidden\" name=\"authenticity_token\" value=\""
  assert_includes body, "action=\"/admin/jobs/#{failed}/discard\""
  assert_includes body, "action=\"/admin/jobs/#{failed}/delete\""
  assert_includes body, "action=\"/admin/jobs/retry_all\""
  assert_includes body, "action=\"/admin/jobs/discard_all\""
  assert_includes body, "<td>1970-01-01 00:16:40 UTC</td>"
  assert_includes body, "No discarded jobs."
  assert_includes body, "No running jobs."
end

test "running rows show who claimed them; the queued line shows the next due time" do
  clear_jobs
  running = job_in("running", 1, "")
  DB.with do |c|
    c.execute("UPDATE cybertrain_jobs SET claimed_by = 'web:42:1:abc<x>', heartbeat_at = ? WHERE id = ?",
              Cybertrain::Cast.binds(Time.now.to_i - 5, running))
  end
  queued = job_in("queued", 2, "")
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET run_at = 4102444800 WHERE id = ?", [queued]) }
  html = JobsPage.index_html(1, 50, "/admin/jobs", Cybertrain::Template::Helpers.new(nil))
  assert_includes html, "<td>web:42:1:abc&lt;x&gt;</td>"
  assert_includes html, " s ago</td>"
  assert_includes html, "<p class=\"jobs-queued\">1 queued; the next is due at 2100-01-01 00:00:00 UTC.</p>"
  clear_jobs
  html = JobsPage.index_html(1, 50, "/admin/jobs", Cybertrain::Template::Helpers.new(nil))
  assert_includes html, "<p class=\"jobs-queued\">No queued jobs.</p>"
  assert_includes html, "No failed jobs."
end

test "retry resets attempts and requeues; discard and delete act only on failed or discarded rows" do
  clear_jobs
  failed = job_in("failed", 7, "boom")
  queued = job_in("queued", 8, "")
  pair = admin_client
  client = pair[0]
  token = pair[1]
  refute token.empty?, "the page's forms carry the CSRF token"
  assert_response client.post("/admin/jobs/#{failed}/retry", { "admin" => "1" }), :forbidden
  assert_equal "failed", job_value(failed, "state")
  before = Time.now.to_i
  res = client.post("/admin/jobs/#{failed}/retry", { "authenticity_token" => token, "admin" => "1" })
  assert_redirected_to res, "/admin/jobs"
  assert_response res, :see_other
  assert_equal "queued", job_value(failed, "state")
  assert_equal "0", job_value(failed, "attempts")
  assert_equal "", job_value(failed, "last_error")
  assert Cybertrain::Cast.int(job_value(failed, "run_at")) >= before, "run_at is now"
  assert_equal "7", job_value(failed, "concurrency_key")
  assert_includes client.get("/admin/jobs?admin=1").body, "<p class=\"notice\">Job #{failed} was queued again.</p>"
  # A queued row is left alone by every action.
  client.post("/admin/jobs/#{queued}/discard", { "authenticity_token" => token, "admin" => "1" })
  assert_equal "queued", job_value(queued, "state")
  assert_includes client.get("/admin/jobs?admin=1").body, "Job #{queued} was not discarded: it is not failed or discarded."
  client.post("/admin/jobs/#{queued}/delete", { "authenticity_token" => token, "admin" => "1" })
  assert_equal "queued", job_value(queued, "state")
  refute JobsPage.retry_job(queued)
  refute JobsPage.discard_job(queued)
  refute JobsPage.delete_job(queued)
  refute JobsPage.retry_job(999_999)
  # A failed row is discarded, a discarded one deleted.
  again = job_in("failed", 9, "boom")
  client.post("/admin/jobs/#{again}/discard", { "authenticity_token" => token, "admin" => "1" })
  assert_equal "discarded", job_value(again, "state")
  client.post("/admin/jobs/#{again}/delete", { "authenticity_token" => token, "admin" => "1" })
  assert_equal "(gone)", job_value(again, "state")
  assert_includes client.get("/admin/jobs?admin=1").body, "Job #{again} was deleted."
  # A discarded row can be retried too.
  gone = job_in("discarded", 10, "bad")
  assert JobsPage.retry_job(gone)
  assert_equal "queued", job_value(gone, "state")
  # The before_action guards the POST actions as well.
  plain = Cybertrain::Test::Client.new(APP)
  plain.get("/admin/jobs?admin=1")
  other = job_in("failed", 11, "boom")
  assert_redirected_to plain.post("/admin/jobs/#{other}/delete", { "authenticity_token" => form_token(plain.get("/admin/jobs?admin=1").body) }), "/"
  assert_equal "failed", job_value(other, "state")
  assert_equal "Job 0 was not retried: it is not failed or discarded.", JobsPage.retry_notice("abc")
end

test "retry keys a legacy failed row of a keyed kind in the same statement" do
  clear_jobs
  now = Time.now.to_i
  DB.with do |c|
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, attempts, last_error, state, created_at, updated_at, concurrency_key) " \
              "VALUES ('WelcomeJob', '{\"user_id\":3}', ?, 5, 'old', 'failed', ?, ?, '')", Cybertrain::Cast.binds(now, now, now))
  end
  rows = DB.with { |c| c.execute("SELECT MAX(id) AS id FROM cybertrain_jobs") }
  id = Cybertrain::Cast.int(rows[0]["id"])
  assert JobsPage.retry_job(id)
  assert_equal "queued", job_value(id, "state")
  assert_equal "3", job_value(id, "concurrency_key")
end

test "retry_all and discard_all_failed count the rows" do
  clear_jobs
  a = job_in("failed", 1, "x")
  b = job_in("failed", 2, "x")
  c = job_in("discarded", 3, "x")
  d = job_in("queued", 4, "x")
  DB.with { |conn| conn.execute("UPDATE cybertrain_jobs SET concurrency_key = '' WHERE id = ?", [b]) }
  assert_equal 2, JobsPage.retry_all
  assert_equal "queued", job_value(a, "state")
  assert_equal "2", job_value(b, "concurrency_key")
  assert_equal "discarded", job_value(c, "state")
  assert_equal 0, JobsPage.retry_all
  e = job_in("failed", 5, "x")
  f = job_in("failed", 6, "x")
  assert_equal 2, JobsPage.discard_all_failed
  assert_equal "discarded", job_value(e, "state")
  assert_equal "discarded", job_value(f, "state")
  assert_equal "queued", job_value(d, "state")
  g = job_in("failed", 7, "x")
  pair = admin_client
  res = pair[0].post("/admin/jobs/retry_all", { "authenticity_token" => pair[1], "admin" => "1" })
  assert_redirected_to res, "/admin/jobs"
  assert_equal "queued", job_value(g, "state")
  assert_includes pair[0].get("/admin/jobs?admin=1").body, "1 failed job(s) queued again."
  h = job_in("failed", 8, "x")
  pair[0].post("/admin/jobs/discard_all", { "authenticity_token" => pair[1], "admin" => "1" })
  assert_equal "discarded", job_value(h, "state")
  assert_includes pair[0].get("/admin/jobs?admin=1").body, "1 failed job(s) discarded."
  assert_equal 8, job_count
end

test "each list shows jobs_page_per_page rows, with page links" do
  clear_jobs
  ids = [job_in("failed", 1, "one"), job_in("failed", 2, "two"), job_in("failed", 3, "three")]
  rows = JobsPage.jobs_rows("failed", 1, 2)
  assert_equal [ids[2], ids[1]], rows.map { |r| Cybertrain::Cast.int(r["id"]) }
  assert_equal [ids[0]], JobsPage.jobs_rows("failed", 2, 2).map { |r| Cybertrain::Cast.int(r["id"]) }
  assert_equal 0, JobsPage.jobs_rows("failed", 3, 2).size
  first = JobsPage.index_html(1, 2, "/admin/jobs", Cybertrain::Template::Helpers.new(nil))
  assert_includes first, "<td>three</td>"
  refute first.include?("<td>one</td>"), "the third row is on page 2"
  assert_includes first, "<nav class=\"pagination\"><a href=\"/admin/jobs?page=2\">Older</a></nav>"
  second = JobsPage.index_html(2, 2, "/admin/jobs", Cybertrain::Template::Helpers.new(nil))
  assert_includes second, "<td>one</td>"
  assert_includes second, "<nav class=\"pagination\"><a href=\"/admin/jobs?page=1\">Newer</a></nav>"
  config_per_page = Cybertrain.config.jobs_page_per_page
  Cybertrain.config.jobs_page_per_page = 1
  body = admin_client[0].get("/admin/jobs?admin=1&page=3").body
  assert_includes body, "<td>one</td>"
  assert_includes body, "<a href=\"/admin/jobs?page=2\">Newer</a>"
  Cybertrain.config.jobs_page_per_page = config_per_page
end

# Two failed rows and a discarded one (fixed times), nothing queued or
# running: at one row a page, the page's whole HTML is fixed but for the
# ids, and it has an Older link.
def fixed_jobs
  clear_jobs
  job_in("failed", 6, "older")
  failed = job_in("failed", 7, "boom <x>")
  discarded = job_in("discarded", 8, "gone")
  [failed, discarded]
end

test "the jobs page in English is unchanged" do
  I18n.locale = nil
  ids = fixed_jobs
  f = ids[0]
  d = ids[1]
  html = JobsPage.index_html(1, 1, "/admin/jobs", Cybertrain::Template::Helpers.new(nil))
  expected = "<section class=\"cybertrain-jobs\"><h1>Jobs</h1>\n" \
             "<table class=\"jobs-counts\"><thead><tr><th>State</th><th>Jobs</th></tr></thead><tbody><tr><td>queued</td><td>0</td></tr><tr><td>running</td><td>0</td></tr><tr><td>done</td><td>0</td></tr><tr><td>failed</td><td>2</td></tr><tr><td>discarded</td><td>1</td></tr></tbody></table>\n" \
             "<p class=\"jobs-queued\">No queued jobs.</p>\n" \
             "<h2>Failed (2)</h2>\n" \
             "<div class=\"jobs-bulk\"><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/retry_all\"><button type=\"submit\">Retry all failed</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/discard_all\"><button type=\"submit\">Discard all failed</button></form></div>\n" \
             "<table class=\"jobs-failed\"><thead><tr><th>ID</th><th>Kind</th><th>Arguments</th><th>Error</th><th>Attempts</th><th>Run at</th><th>Updated</th><th></th></tr></thead><tbody><tr><td>#{f}</td><td>WelcomeJob</td><td>{&quot;user_id&quot;:7,&quot;mode&quot;:&quot;ok&quot;}</td><td>boom &lt;x&gt;</td><td>5</td><td>1970-01-01 00:16:40 UTC</td><td>1970-01-01 00:33:20 UTC</td><td><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{f}/retry\"><button type=\"submit\">Retry</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{f}/discard\"><button type=\"submit\">Discard</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{f}/delete\"><button type=\"submit\">Delete</button></form></td></tr></tbody></table>\n" \
             "<h2>Discarded (1)</h2>\n" \
             "<table class=\"jobs-discarded\"><thead><tr><th>ID</th><th>Kind</th><th>Arguments</th><th>Error</th><th>Attempts</th><th>Run at</th><th>Updated</th><th></th></tr></thead><tbody><tr><td>#{d}</td><td>WelcomeJob</td><td>{&quot;user_id&quot;:8,&quot;mode&quot;:&quot;ok&quot;}</td><td>gone</td><td>5</td><td>1970-01-01 00:16:40 UTC</td><td>1970-01-01 00:33:20 UTC</td><td><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{d}/retry\"><button type=\"submit\">Retry</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{d}/delete\"><button type=\"submit\">Delete</button></form></td></tr></tbody></table>\n" \
             "<h2>Running (0)</h2>\n" \
             "<p class=\"jobs-empty\">No running jobs.</p>\n" \
             "<nav class=\"pagination\"><a href=\"/admin/jobs?page=2\">Older</a></nav></section>"
  assert_equal expected, html
  # The notices of a row that is not there (nothing changes).
  assert_equal "Job 0 was not retried: it is not failed or discarded.", JobsPage.retry_notice("x")
  assert_equal "Job 0 was not discarded: it is not failed or discarded.", JobsPage.discard_notice(nil)
  assert_equal "Job 0 was not deleted: it is not failed or discarded.", JobsPage.delete_notice("0")
end

test "the jobs page in Japanese" do
  I18n.available_locales = [:en, :ja]
  ids = fixed_jobs
  f = ids[0]
  d = ids[1]
  html = I18n.with_locale(:ja) { JobsPage.index_html(1, 1, "/admin/jobs", Cybertrain::Template::Helpers.new(nil)) }
  assert_includes html, "ジョブ"
  ["<h1>Jobs</h1>", "Failed (", "Discarded (", "Running (", "No running jobs.", ">Retry<", ">Older<"].each do |english|
    refute html.include?(english), "no English: #{english}"
  end
  expected = "<section class=\"cybertrain-jobs\"><h1>ジョブ</h1>\n" \
             "<table class=\"jobs-counts\"><thead><tr><th>状態</th><th>件数</th></tr></thead><tbody><tr><td>待機中</td><td>0</td></tr><tr><td>実行中</td><td>0</td></tr><tr><td>完了</td><td>0</td></tr><tr><td>失敗</td><td>2</td></tr><tr><td>破棄済み</td><td>1</td></tr></tbody></table>\n" \
             "<p class=\"jobs-queued\">待機中のジョブはありません。</p>\n" \
             "<h2>失敗 (2)</h2>\n" \
             "<div class=\"jobs-bulk\"><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/retry_all\"><button type=\"submit\">失敗したジョブをすべて再実行</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/discard_all\"><button type=\"submit\">失敗したジョブをすべて破棄</button></form></div>\n" \
             "<table class=\"jobs-failed\"><thead><tr><th>ID</th><th>種類</th><th>引数</th><th>エラー</th><th>試行回数</th><th>実行予定</th><th>更新日時</th><th></th></tr></thead><tbody><tr><td>#{f}</td><td>WelcomeJob</td><td>{&quot;user_id&quot;:7,&quot;mode&quot;:&quot;ok&quot;}</td><td>boom &lt;x&gt;</td><td>5</td><td>1970-01-01 00:16:40 UTC</td><td>1970-01-01 00:33:20 UTC</td><td><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{f}/retry\"><button type=\"submit\">再実行</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{f}/discard\"><button type=\"submit\">破棄</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{f}/delete\"><button type=\"submit\">削除</button></form></td></tr></tbody></table>\n" \
             "<h2>破棄済み (1)</h2>\n" \
             "<table class=\"jobs-discarded\"><thead><tr><th>ID</th><th>種類</th><th>引数</th><th>エラー</th><th>試行回数</th><th>実行予定</th><th>更新日時</th><th></th></tr></thead><tbody><tr><td>#{d}</td><td>WelcomeJob</td><td>{&quot;user_id&quot;:8,&quot;mode&quot;:&quot;ok&quot;}</td><td>gone</td><td>5</td><td>1970-01-01 00:16:40 UTC</td><td>1970-01-01 00:33:20 UTC</td><td><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{d}/retry\"><button type=\"submit\">再実行</button></form><form class=\"button_to\" method=\"post\" action=\"/admin/jobs/#{d}/delete\"><button type=\"submit\">削除</button></form></td></tr></tbody></table>\n" \
             "<h2>実行中 (0)</h2>\n" \
             "<p class=\"jobs-empty\">実行中のジョブはありません。</p>\n" \
             "<nav class=\"pagination\"><a href=\"/admin/jobs?page=2\">次へ</a></nav></section>"
  assert_equal expected, html
  # Page 2 has a Newer link and an empty discarded list.
  second = I18n.with_locale(:ja) { JobsPage.index_html(2, 1, "/admin/jobs", Cybertrain::Template::Helpers.new(nil)) }
  assert_includes second, "<nav class=\"pagination\"><a href=\"/admin/jobs?page=1\">前へ</a></nav>"
  assert_includes second, "<p class=\"jobs-empty\">破棄済みのジョブはありません。</p>"
  clear_jobs
  html = I18n.with_locale(:ja) { JobsPage.index_html(1, 50, "/admin/jobs", Cybertrain::Template::Helpers.new(nil)) }
  assert_includes html, "<p class=\"jobs-empty\">失敗したジョブはありません。</p>"
  # A running row (no heartbeat, then one 5 s ago) and the queued line.
  running = job_in("running", 1, "")
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET claimed_by = 'w1', heartbeat_at = NULL WHERE id = ?", [running]) }
  queued = job_in("queued", 2, "")
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET run_at = 4102444800 WHERE id = ?", [queued]) }
  html = I18n.with_locale(:ja) { JobsPage.index_html(1, 50, "/admin/jobs", Cybertrain::Template::Helpers.new(nil)) }
  assert_includes html, "<thead><tr><th>ID</th><th>種類</th><th>実行ワーカー</th><th>最終応答</th></tr></thead>"
  assert_includes html, "<td>#{running}</td><td>WelcomeJob</td><td>w1</td><td>なし</td>"
  assert_includes html, "<p class=\"jobs-queued\">待機中 1件。次の実行予定は 2100-01-01 00:00:00 UTC です。</p>"
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET heartbeat_at = ? WHERE id = ?", Cybertrain::Cast.binds(Time.now.to_i - 5, running)) }
  html = I18n.with_locale(:ja) { JobsPage.index_html(1, 50, "/admin/jobs", Cybertrain::Template::Helpers.new(nil)) }
  assert html.include?("<td>w1</td><td>5秒前</td>") || html.include?("<td>w1</td><td>6秒前</td>"), "the heartbeat age in ja"
  # The notices, done and not done.
  failed = job_in("failed", 3, "x")
  gone = job_in("failed", 6, "x")
  notices = I18n.with_locale(:ja) do
    [JobsPage.discard_notice(failed.to_s), JobsPage.retry_notice(failed.to_s), JobsPage.retry_notice(failed.to_s),
     JobsPage.discard_notice(failed.to_s), JobsPage.delete_notice(failed.to_s), JobsPage.delete_notice(gone.to_s)].join("|")
  end
  assert_equal "ジョブ #{failed} を破棄しました。|ジョブ #{failed} を再びキューに入れました。|" \
               "ジョブ #{failed} は再実行できません。失敗または破棄済みの状態ではありません。|" \
               "ジョブ #{failed} は破棄できません。失敗または破棄済みの状態ではありません。|" \
               "ジョブ #{failed} は削除できません。失敗または破棄済みの状態ではありません。|" \
               "ジョブ #{gone} を削除しました。", notices
  job_in("failed", 4, "x")
  assert_equal "失敗したジョブ 1件を再びキューに入れました。", I18n.with_locale(:ja) { JobsPage.retry_all_notice }
  job_in("failed", 5, "x")
  assert_equal "失敗したジョブ 1件を破棄しました。", I18n.with_locale(:ja) { JobsPage.discard_all_failed_notice }
  # English again outside the block.
  assert_equal "Job 0 was not deleted: it is not failed or discarded.", JobsPage.delete_notice("0")
end

test "jobs_page_per_page: 50, CYBERTRAIN_JOBS_PAGE_PER_PAGE, at least 1" do
  assert_equal 50, Cybertrain::Config.new.jobs_page_per_page
  ENV["CYBERTRAIN_JOBS_PAGE_PER_PAGE"] = "20"
  assert_equal 20, Cybertrain::Config.new.jobs_page_per_page
  ENV["CYBERTRAIN_JOBS_PAGE_PER_PAGE"] = "many"
  assert_equal 50, Cybertrain::Config.new.jobs_page_per_page
  ENV["CYBERTRAIN_JOBS_PAGE_PER_PAGE"] = "0"
  checked = Cybertrain::Config.new
  assert_equal 0, checked.jobs_page_per_page
  assert_equal "jobs_page_per_page must be at least 1 (got 0)", checked.scheduler_error
  ENV.delete("CYBERTRAIN_JOBS_PAGE_PER_PAGE")
end

Cybertrain::Test.run!
