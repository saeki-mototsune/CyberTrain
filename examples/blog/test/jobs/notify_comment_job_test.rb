require "test_helper"
require "stringio"

# NotifyCommentJob (app/jobs/notify_comment_job.rb): what
# CommentsController#create enqueues; it logs the comment.
class NotifyCommentJobTest < ActiveSupport::TestCase
  test "performed, it logs the comment and its article" do
    comment = comments(:one)
    log = StringIO.new
    ran = perform_logging_to(log, comment)
    assert_equal 1, ran
    assert_no_enqueued_jobs
    assert_includes log.string, "new comment #{comment.id} on article #{comment.article_id}"
  end

  private

  # Enqueues the job for comment and performs it with Cybertrain.logger
  # writing to io, restored afterwards even if the job raises (a method
  # that does not yield: NOTES rules 32/45).
  def perform_logging_to(io, comment)
    saved = Cybertrain.logger
    Cybertrain.logger = Cybertrain::Logger.new(io)
    NotifyCommentJob.perform_later("comment_id" => comment.id, "article_id" => comment.article_id)
    perform_enqueued_jobs
  ensure
    Cybertrain.logger = saved
  end
end
