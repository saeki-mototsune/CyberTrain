require "cybertrain/test"
require "cybertrain/cast"
require "cybertrain/db"
require "cybertrain/job"

module Cybertrain
  module Test
    # Reads behind the job helpers (top-level helpers below): the queued
    # rows of the database the application is connected to. Not API.
    module Jobs
      # How many `queued` rows there are, of `kind` when it is not "".
      def self.queued_count(kind)
        Job.ensure_installed
        rows = if kind.empty?
                 DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state = 'queued'") }
               else
                 DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state = 'queued' AND kind = ?", [kind]) }
               end
        Cast.int(rows[0]["n"])
      end

      # The payloads of the `queued` rows of `kind`, oldest first.
      def self.queued_payloads(kind)
        Job.ensure_installed
        rows = DB.with { |c| c.execute("SELECT payload FROM cybertrain_jobs WHERE state = 'queued' AND kind = ? ORDER BY id", [kind]) }
        out = Array.new(0) { "" }
        rows.each { |r| out << Cast.str(r["payload"]) }
        out
      end

      # Whether the parsed payload holds every key of `args` with an equal
      # value, compared as Cast.str of both sides. A Symbol key is read as
      # its name (the payload's keys are JSON strings).
      def self.args_match?(payload, args)
        have = Cast.json_hash(payload)
        args.each do |k, v|
          name = k.to_s
          return false unless have.key?(name)
          return false unless Cast.str(have[name]) == Cast.str(v)
        end
        true
      end

      # The most jobs {perform_enqueued_jobs} runs in one call.
      PERFORM_LIMIT = 10_000

      # `{"user_id" => 1}` as the failure message shows the wanted args.
      def self.describe_args(args)
        parts = Array.new(0) { "" }
        args.each { |k, v| parts << "#{k.inspect} => #{v.inspect}" }
        "{#{parts.join(", ")}}"
      end
    end
  end
end

# Passes when `count` jobs are queued (rows in state `queued`, not yet
# run), of `kind` when one is given.
# @example
#   post "/comments", ...
#   assert_enqueued_jobs 1, "NotifyCommentJob"
# @param count [Integer]
# @param kind [String] "" counts every kind
# @return [void]
# @api public
def assert_enqueued_jobs(count, kind = "")
  Cybertrain::Test.count_assertion
  got = Cybertrain::Test::Jobs.queued_count(kind)
  return if got == count

  what = kind.empty? ? "jobs" : "#{kind.inspect} jobs"
  flunk("expected #{count} enqueued #{what}, got #{got}")
end

# Passes when no job is queued, of `kind` when one is given.
# @example
#   assert_no_enqueued_jobs "WelcomeJob"
# @param kind [String] "" checks every kind
# @return [void]
# @api public
def assert_no_enqueued_jobs(kind = "")
  Cybertrain::Test.count_assertion
  got = Cybertrain::Test::Jobs.queued_count(kind)
  return if got == 0

  what = kind.empty? ? "jobs" : "#{kind.inspect} jobs"
  flunk("expected no enqueued #{what}, got #{got}")
end

# Passes when at least one job of `kind` is queued whose args contain every
# given key with an equal value. Both sides are compared as `Cast.str`, so
# `"user_id" => 1` matches a JSON 1 (and "1"). A Symbol key is read as its
# name, so `user_id: 1` works too.
# @example
#   assert_enqueued_with "WelcomeJob", { "user_id" => user.id }
#   assert_enqueued_with "WelcomeJob", user_id: user.id
# @param kind [String] the job's kind (the class name for a Job::Base subclass)
# @param args [Hash{String, Symbol => Object}] the keys that must match (none: any job of the kind)
# @return [void]
# @api public
def assert_enqueued_with(kind, args = Cybertrain::Cast.empty_hash)
  Cybertrain::Test.count_assertion
  payloads = Cybertrain::Test::Jobs.queued_payloads(kind)
  payloads.each do |payload|
    return if Cybertrain::Test::Jobs.args_match?(payload, args)
  end

  wanted = args.empty? ? "" : " with #{Cybertrain::Test::Jobs.describe_args(args)}"
  queued = payloads.empty? ? "none queued" : "queued: #{payloads.join(", ")}"
  flunk("expected an enqueued #{kind.inspect} job#{wanted}; #{queued}")
end

# Runs every job due at `now` on the calling thread, until none is due
# (`Job.work_one`), and returns how many it ran. A retry the job scheduled
# for later is left queued; pass a later `now` to run it. It fails the test
# after 10,000 jobs: a job that enqueues itself due at once would otherwise
# never let the test end.
# @example
#   post "/signup", ...
#   assert_equal 1, perform_enqueued_jobs
# @param now [Time]
# @return [Integer]
# @raise [Cybertrain::Test::AssertionFailed] after 10,000 jobs in one call
# @api public
def perform_enqueued_jobs(now = Time.now)
  count = 0
  at = now.to_i
  while Cybertrain::Job.work_one(at)
    count += 1
    if count >= Cybertrain::Test::Jobs::PERFORM_LIMIT
      flunk("perform_enqueued_jobs ran 10000 jobs; a job re-enqueues itself due at once")
    end
  end
  count
end

# Deletes every queued job, so the next test starts from an empty queue.
# @return [Integer] how many rows were deleted
# @api public
def clear_enqueued_jobs
  Cybertrain::Job.ensure_installed
  removed = 0
  Cybertrain::DB.with do |c|
    c.execute("DELETE FROM cybertrain_jobs WHERE state = 'queued'")
    removed = c.changes
  end
  removed
end
