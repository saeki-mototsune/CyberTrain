# Runs after a comment is saved (CommentsController#create enqueues it), on
# a Solid Queue worker thread, not in the request: it finds the comment and
# logs it, as examples/blog's NotifyCommentJob does. A comment deleted before
# the job ran is discarded; anything else is retried 30 seconds later, three
# attempts in all.
class NotifyCommentJob < ApplicationJob
  # Rails checks the handler declared last first, so the discard comes after
  # the retry (examples/blog writes them the other way round).
  retry_on StandardError, wait: 30.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(comment_id:, article_id:)
    comment = Comment.find(comment_id)
    logger.info("new comment #{comment.id} on article #{article_id}")
  end
end
