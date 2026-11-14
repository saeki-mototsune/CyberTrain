# Runs after a comment is saved (CommentsController#create enqueues it with
# NotifyCommentJob.perform_later), on a job thread of the process that runs
# jobs (`./blog worker`, or `./blog server` unless CYBERTRAIN_WORKER=0), not
# in the request. It finds the comment and logs it; a real app would send
# a mail here. A comment deleted before the job runs fails it
# (Cybertrain::RecordNotFound): each failed attempt is reported
# (Cybertrain.error, and Sentry when CYBERTRAIN_SENTRY_DSN is set) and
# retried 30 seconds later, three attempts in all. Its log lines carry
# `[NotifyCommentJob <job id>]` and the id of the request that enqueued it.
class NotifyCommentJob < Cybertrain::Job::Base
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment = Comment.find(Cybertrain::Cast.int(args["comment_id"]))
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment.id} on article #{article_id}")
    nil
  end
end
