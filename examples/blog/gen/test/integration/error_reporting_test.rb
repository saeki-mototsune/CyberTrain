
require "stringio"

# What ErrorReportingTest's subscriber saw: one line per report, "<class>
# <where> <request id>".
REPORTS_SEEN = Array.new(0) { "" }

# A subscriber, as an application writes one (a Cybertrain::ErrorSubscriber
# that defines report(event)): it runs on the reporter's thread for every
# report. One added in a test is dropped before the next test.
class SeenReports < Cybertrain::ErrorSubscriber
  def report(event)
    REPORTS_SEEN << "#{event.error_class} #{event.error_where} #{event.error_request_id}"
    nil
  end
end

# The blog's errors reported. A page that fails (a 500), a failed job
# attempt and a discarded job are reported, to the subscribers and to
# Sentry when CYBERTRAIN_SENTRY_DSN is set; here the DSN points at a
# Sentry stand-in on 127.0.0.1 (Cybertrain::Test::SentryReceiver),
# assigned in the test because `cybertrain test` ignores an exported DSN.
class ErrorReportingTest < ActionDispatch::IntegrationTest; def setup; super; setup_error_reporting_test_1; nil; end; def teardown; teardown_error_reporting_test_1; super; nil; end
  def setup_error_reporting_test_1; begin
    REPORTS_SEEN.clear
    @saved_dsn = Cybertrain.config.sentry_dsn
    @saved_private = Cybertrain.config.http_allow_private
    @receiver = Cybertrain::Test::SentryReceiver.new
    @receiver.start
    Cybertrain.config.sentry_dsn = @receiver.dsn("1")
    Cybertrain.config.http_allow_private = true
  end; nil; end

  def teardown_error_reporting_test_1; begin
    Cybertrain.config.sentry_dsn = @saved_dsn
    Cybertrain.config.http_allow_private = @saved_private
    @receiver.stop
  end; nil; end

  def test_an_article_page_that_fails_is_reported; begin
    path = article_path(articles(:one))
    get_with_articles_hidden(path)
    ev = @receiver.received_events(1)[0]
    assert_equal "ArticlesController#show", ev.sentry_field("transaction")
    assert_equal "Cybertrain::DB::Error", ev.sentry_field("exception.values.0.type")
    assert_equal "GET", ev.sentry_field("request.method")
    assert_equal path, ev.sentry_field("request.url")
  end; nil; end

  # A failure that may pass (here the comments table is missing while the
  # job runs): retry_on queues the job again 30 seconds later, and the
  # attempt is logged and reported with its number and the kind's limit.
  def test_a_failing_job_is_reported_with_its_attempt_and_retried; begin
    comment = comments(:one)
    NotifyCommentJob.perform_later("comment_id" => comment.id, "article_id" => comment.article_id)
    job = BlogTestHelper.last_job
    log = StringIO.new
    # The block-less form: a failed attempt does not fail the test.
    assert_equal 1, perform_jobs_with_comments_hidden(log)
    assert_includes log.string, " ERROR [NotifyCommentJob #{job[0]}] job #{job[0]} (NotifyCommentJob) attempt 1 of 3 failed: " \
                                "Cybertrain::DB::Error: "
    assert_includes log.string, "; retrying in 30 s\n"
    assert_equal "queued", BlogTestHelper.job_state(job[0].to_i)
    ev = @receiver.received_events(1)[0]
    assert_equal "NotifyCommentJob", ev.sentry_field("transaction")
    assert_equal "Cybertrain::DB::Error", ev.sentry_field("exception.values.0.type")
    # The context's keys hold a dot ("job.attempt"); sentry_field reads
    # the longest key that exists first, so the dotted key is read whole.
    assert_equal job[0], ev.sentry_field("extra.job.id")
    assert_equal "1", ev.sentry_field("extra.job.attempt")
    assert_equal "3", ev.sentry_field("extra.job.max_attempts")
  end; nil; end

  # A failure no retry changes: the comment was deleted before the job ran.
  # discard_on ends the job at its first attempt, reported once, with the
  # id of the request that enqueued it.
  def test_a_job_whose_comment_was_deleted_is_discarded_and_reported_once__with_the_request_s_id; begin
    Cybertrain.error.subscribe(SeenReports.new)
    article = articles(:one)
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "Ann", body: "Hi" } }
    rid = response.header("X-Request-Id").to_s
    comment = Comment.last
    refute comment.nil?, "expected the comment to be saved"
    comment_id = comment.id
    job = BlogTestHelper.last_job
    comment.destroy
    log = StringIO.new
    assert_equal 1, perform_jobs_logging_to(log)
    assert_includes log.string, " ERROR [NotifyCommentJob #{job[0]}] [#{rid}] job #{job[0]} (NotifyCommentJob) discarded: " \
                                "NotifyCommentJob::CommentGone: comment #{comment_id} was deleted; nothing to notify\n"
    assert_nil log.string.index("retrying")
    assert_equal "discarded", BlogTestHelper.job_state(job[0].to_i)
    assert_equal 0, perform_enqueued_jobs
    Cybertrain.error.drain_reports
    assert_equal ["NotifyCommentJob::CommentGone NotifyCommentJob #{rid}"], REPORTS_SEEN
    events = @receiver.received_events(2, 1.0)
    assert_equal 1, events.size
    ev = events[0]
    assert_equal "NotifyCommentJob", ev.sentry_field("transaction")
    assert_equal "NotifyCommentJob::CommentGone", ev.sentry_field("exception.values.0.type")
    assert_equal rid, ev.sentry_field("tags.request_id")
    assert_equal "1", ev.sentry_field("extra.job.attempt")
    assert_equal "1", ev.sentry_field("extra.job.max_attempts")
  end; nil; end

  def test_a_page_that_is_not_found_is_not_reported; begin
    Cybertrain.error.subscribe(SeenReports.new)
    get "/articles/999999"
    assert_response :not_found
    Cybertrain.error.drain_reports
    assert_equal 0, REPORTS_SEEN.size
  end; nil; end

  private

  # GET path while the articles table is renamed away, so the controller's
  # Article.find fails before anything renders; the table is back
  # afterwards even if the request does not raise (a method that does not
  # yield: NOTES rules 32/45).
  def get_with_articles_hidden(path)
    hidden = false
    rename_table("articles", "articles_hidden")
    hidden = true
    assert_raises(Cybertrain::DB::Error) { get path }
  ensure
    rename_table("articles_hidden", "articles") if hidden
  end

  # perform_enqueued_jobs while the comments table is renamed away (the
  # job's Comment.find_by fails), with Cybertrain.logger writing to `io`;
  # the table and the logger are back afterwards.
  def perform_jobs_with_comments_hidden(io)
    saved = Cybertrain.logger
    hidden = false
    Cybertrain.logger = Cybertrain::Logger.new(io)
    rename_table("comments", "comments_hidden")
    hidden = true
    perform_enqueued_jobs
  ensure
    rename_table("comments_hidden", "comments") if hidden
    Cybertrain.logger = saved
  end

  # perform_enqueued_jobs with Cybertrain.logger writing to `io` (a failed
  # attempt's ERROR line would otherwise print among the test lines),
  # restored afterwards (a method that does not yield: NOTES rules 32/45).
  def perform_jobs_logging_to(io)
    saved = Cybertrain.logger
    Cybertrain.logger = Cybertrain::Logger.new(io)
    perform_enqueued_jobs
  ensure
    Cybertrain.logger = saved
  end

  def rename_table(from, to)
    Cybertrain::DB.with { |c| c.execute("ALTER TABLE #{from} RENAME TO #{to}") }
    nil
  end
end
# Generated by `spin run gen` from test/integration/error_reporting_test.rb. Do not edit.
