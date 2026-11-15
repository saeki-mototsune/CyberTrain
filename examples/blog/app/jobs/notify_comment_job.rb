# Runs after a comment is saved (CommentsController#create enqueues it with
# NotifyCommentJob.perform_later), on a job thread of the process that runs
# jobs (`./blog worker`, or `./blog server` unless CYBERTRAIN_WORKER=0), not
# in the request. It finds the comment and logs it; a real app would send
# a mail here. Its log lines carry `[NotifyCommentJob <job id>]` and the id
# of the request that enqueued it.
#
# Two policies, for two kinds of failure:
# - The comment was deleted before the job ran: Comment.find raises
#   Cybertrain::RecordNotFound. There is nothing to notify and nothing a
#   retry would change, so the job is discarded at once (the row becomes
#   `discarded`; reported once).
# - Anything else (the database busy or unreachable) may pass: the job runs
#   again 30 seconds later, three attempts in all, then the row is `failed`
#   for the jobs page. Every failed attempt is logged and reported, but a
#   report identical to one made in the last 60 seconds (same class,
#   message and job) is not sent again.
class NotifyCommentJob < Cybertrain::Job::Base
  # The order of the next two lines matters. Each becomes a `rescue` arm of
  # the generated run_job, in the order written, and the first arm that
  # matches wins, as in a `begin`/`rescue`: Cybertrain::RecordNotFound, a
  # StandardError too, is discarded before `retry_on StandardError` can
  # retry it. Rails checks the handler declared last first, so in a Rails
  # app these two lines go the other way round.
  discard_on Cybertrain::RecordNotFound
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment = Comment.find(Cybertrain::Cast.int(args["comment_id"]))
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment.id} on article #{article_id}")
    nil
  end
end
