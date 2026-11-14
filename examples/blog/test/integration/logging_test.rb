require "test_helper"
require "stringio"

# Request ids in the blog's log. Every request gets an id, answered in
# its X-Request-Id header and put on each line the request logs; a job
# the request enqueues records the id in its row (cybertrain_jobs'
# request_id), and every line the job logs carries its own tag
# ("NotifyCommentJob <job id>") and then that id. config/app.rb turns the
# request log off in tests (log_level :none), so the job's lines are read
# through a logger installed for the job's run.
class LoggingTest < ActionDispatch::IntegrationTest
  test "a comment's request id is in the job it enqueued: the job's row and its log line" do
    article = articles(:one)
    post "/articles/#{article.id}/comments", params: { comment: { commenter: "Ann", body: "Hi" } }
    assert_response :see_other
    rid = response.header("X-Request-Id").to_s
    assert BlogTestHelper.uuid?(rid), "expected a UUID request id, got #{rid.inspect}"
    comment = Comment.last
    refute comment.nil?, "expected the comment to be saved"

    job = BlogTestHelper.last_job
    assert_equal "NotifyCommentJob", job[1]
    assert_equal rid, job[2]

    log = StringIO.new
    assert_equal 1, perform_jobs_logging_to(log)
    assert_includes log.string, " INFO [NotifyCommentJob #{job[0]}] [#{rid}] new comment #{comment.id} on article #{article.id}\n"
  end

  test "each request has its own id" do
    get "/articles"
    first = response.header("X-Request-Id").to_s
    get "/articles"
    second = response.header("X-Request-Id").to_s
    assert BlogTestHelper.uuid?(first), "expected a UUID request id, got #{first.inspect}"
    assert BlogTestHelper.uuid?(second), "expected a UUID request id, got #{second.inspect}"
    assert first != second, "expected two ids, got #{first} twice"
  end

  test "a job enqueued outside a request logs its own tag alone" do
    comment = comments(:one)
    NotifyCommentJob.perform_later("comment_id" => comment.id, "article_id" => comment.article_id)
    job = BlogTestHelper.last_job
    assert_equal "", job[2]
    log = StringIO.new
    assert_equal 1, perform_jobs_logging_to(log)
    assert_includes log.string, " INFO [NotifyCommentJob #{job[0]}] new comment #{comment.id} on article #{comment.article_id}\n"
  end

  private

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
end
