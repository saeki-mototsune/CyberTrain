# Runs after a comment is saved (CommentsController#create enqueues it with
# NotifyCommentJob.perform_later), on a job thread of the process that runs
# jobs (`./blog worker`, or `./blog server` unless CYBERTRAIN_WORKER=0), not
# in the request. It only logs the comment; a real app would send a mail
# here, and a failure is retried 30 seconds later, three attempts in all.
class NotifyCommentJob < Cybertrain::Job::Base
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment_id = Cybertrain::Cast.int(args["comment_id"])
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment_id} on article #{article_id}")
    nil
  end
end
