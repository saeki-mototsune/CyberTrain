# Announces an article by mail, later: the job queues the mail
# (deliver_later), so a test that performs it runs a job that queues a job.
class AnnounceJob < Cybertrain::Job::Base
  def perform(args)
    NewsMailer.published(Article.find(Cybertrain::Cast.int(args["article_id"]))).deliver_later
    nil
  end
end
