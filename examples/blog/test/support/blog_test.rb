# Shared setup for the blog's integration tests (test/articles.rb,
# test/comments.rb). `spin test` runs only test/*.rb, so this file is
# required, not run.
#
# The app is built the way bin/blog.rb builds it, in the test
# environment, against a fresh storage/test.sqlite3 migrated from
# gen/migrations.rb. The database is compiled in through FFI, so these
# programs do not run under CRuby: their snapshots come from the compiled
# binaries (`./build/test/articles > test/articles.rb.expected 2>&1`).
ENV["CYBERTRAIN_ENV"] = "test"

require "cybertrain"
require "cybertrain/test/client"
require "cybertrain/test/jobs"
require "cybertrain/cache"
require_relative "../../config/app"
require_relative "../../gen/app"
require_relative "../../gen/migrations"

module BlogTest
  def self.database_path
    Cybertrain.config.database_path
  end

  # Deletes storage/test.sqlite3 (and its WAL files), migrates a new one
  # and boots the application on it.
  def self.boot
    path = database_path
    [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
    connection = Cybertrain::DB::Connection.new(path)
    Cybertrain::DB::Migrator.new(connection).migrate(Cybertrain::Migration.all)
    connection.close

    app = Cybertrain::Application.new(
      router: Gen::Routes.build(Cybertrain::Router.new),
      url_resolver: Gen::Routes.url_resolver
    )
    app.boot
  end

  # Every test starts from empty tables, an empty cache, no jobs (every
  # row, not only the queued ones clear_enqueued_jobs removes; install!
  # creates the table the first time), no BLOG_ADMIN_TOKEN and a new
  # browser (no cookies).
  def self.reset
    Comment.all.delete_all
    Article.all.delete_all
    Cybertrain::Cache.clear
    Cybertrain::Job.install!
    Cybertrain::DB.with { |c| c.execute("DELETE FROM cybertrain_jobs") }
    ENV.delete("BLOG_ADMIN_TOKEN")
    nil
  end

  def self.article(title = "Hello Rails", body = "I am on Rails! This is my first article.")
    Article.create(title: title, body: body)
  end

  def self.comment(article, commenter = "Alice", body = "Great post!")
    Comment.create(commenter: commenter, body: body, article_id: article.id)
  end

  # The authenticity_token of the first form in the last response, as a
  # browser would submit it back.
  def self.form_token(client)
    body = client.response.body
    marker = "name=\"authenticity_token\" value=\""
    at = body.index(marker)
    raise "no authenticity_token in the last response" if at.nil?

    start = at + marker.size
    stop = body.index("\"", start)
    raise "unterminated authenticity_token" if stop.nil?

    body[start, stop - start].to_s
  end

  def self.article_path(article)
    "/articles/#{article.id}"
  end

  # A NotifyCommentJob row that has used its attempts: `failed`, which the
  # jobs page offers to retry, discard or delete.
  def self.failed_job
    id = Cybertrain::Job.enqueue("NotifyCommentJob", "{\"comment_id\":1,\"article_id\":1}")
    Cybertrain::DB.with do |c|
      c.execute("UPDATE cybertrain_jobs SET state = 'failed', attempts = 3, last_error = 'boom' WHERE id = ?", [id])
    end
    id
  end

  # The state of the job row `id`; "(gone)" when there is no such row.
  def self.job_state(id)
    rows = Cybertrain::DB.with { |c| c.execute("SELECT state FROM cybertrain_jobs WHERE id = ?", [id]) }
    return "(gone)" if rows.empty?

    Cybertrain::Cast.str(rows[0]["state"])
  end

  # The session the client's cookie carries, read as the server reads it.
  def self.session_of(client)
    Cybertrain::Session.load(client.cookies[Cybertrain.config.session_cookie_name], Cybertrain.config.secret_key_base)
  end
end

BLOG = BlogTest.boot
