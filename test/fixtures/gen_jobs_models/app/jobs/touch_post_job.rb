# What TouchPostJob did, for test/gen_jobs_compiles.rb (a constant: NOTES
# rule 64).
TOUCH_LOG = Array.new(0) { "" }

# A job over the gen fixture's Post model (test/fixtures/gen_app): a post
# deleted before the job runs makes Post.find raise
# Cybertrain::RecordNotFound, a framework exception class not named
# ...Error, and the job is discarded rather than retried.
class TouchPostJob < Cybertrain::Job::Base
  discard_on Cybertrain::RecordNotFound

  def perform(args)
    post = Post.find(Cybertrain::Cast.int(args["post_id"]))
    TOUCH_LOG << "touched #{post.title}"
    nil
  end
end
