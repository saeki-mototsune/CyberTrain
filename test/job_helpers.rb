require "stringio"
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/jobs"

# The job test helpers (cybertrain/test/jobs): assert_enqueued_jobs,
# assert_enqueued_with, assert_no_enqueued_jobs, perform_enqueued_jobs and
# clear_enqueued_jobs, each with its pass and its failure message, on a
# temporary in-memory database. Compiled with the framework (NOTES rule 41);
# it links SQLite through FFI, so its snapshot comes from the compiled
# binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Job = Cybertrain::Job

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# What the handlers saw (a constant: NOTES rule 64).
SEEN = Array.new(0) { "" }

Job.register("welcome") { |run| SEEN << "welcome #{Cybertrain::Cast.str(run.run_args["user_id"])}" }
Job.register("digest") { |run| SEEN << "digest" }
Job.register("flaky") { |run| raise "not yet" }
# Enqueues itself again, due at once.
Job.register("again") { |run| Job.enqueue("again", "{}", run_at: Time.at(1000)) }

def fresh_db
  DB.connect(":memory:")
  SEEN.pop until SEEN.empty?
  nil
end

def welcome_args(user_id)
  args = Cybertrain::Cast.empty_hash
  args["user_id"] = user_id
  args["mode"] = "ok"
  args
end

test "assert_enqueued_jobs counts queued rows, of a kind when given" do
  fresh_db
  assert_enqueued_jobs 0
  Job.enqueue("welcome", "{\"user_id\":1}")
  Job.enqueue("welcome", "{\"user_id\":2}")
  Job.enqueue("digest", "{}")
  assert_enqueued_jobs 3
  assert_enqueued_jobs 2, "welcome"
  assert_enqueued_jobs 1, "digest"
  assert_enqueued_jobs 0, "flaky"
  message = assert_raises("AssertionFailed") { assert_enqueued_jobs 2 }
  assert_equal "expected 2 enqueued jobs, got 3", message
  message = assert_raises("AssertionFailed") { assert_enqueued_jobs 1, "welcome" }
  assert_equal "expected 1 enqueued \"welcome\" jobs, got 2", message
end

test "assert_no_enqueued_jobs passes on an empty queue and names what is queued" do
  fresh_db
  assert_no_enqueued_jobs
  Job.enqueue("digest", "{}")
  assert_no_enqueued_jobs "welcome"
  message = assert_raises("AssertionFailed") { assert_no_enqueued_jobs }
  assert_equal "expected no enqueued jobs, got 1", message
  message = assert_raises("AssertionFailed") { assert_no_enqueued_jobs "digest" }
  assert_equal "expected no enqueued \"digest\" jobs, got 1", message
end

test "assert_enqueued_with matches a kind and args by Cast.str, so 1 matches a JSON 1" do
  fresh_db
  Job.enqueue("welcome", "{\"user_id\":1,\"mode\":\"ok\"}")
  Job.enqueue("welcome", "{\"user_id\":2,\"mode\":\"ok\"}")
  assert_enqueued_with "welcome"
  assert_enqueued_with "welcome", { "user_id" => 1 }
  assert_enqueued_with "welcome", { "user_id" => "2", "mode" => "ok" }
  assert_enqueued_with "welcome", welcome_args(2)
  message = assert_raises("AssertionFailed") { assert_enqueued_with "welcome", { "user_id" => 3 } }
  assert_includes message, "expected an enqueued \"welcome\" job with {\"user_id\" => 3}"
  assert_includes message, "{\"user_id\":2,\"mode\":\"ok\"}"
  message = assert_raises("AssertionFailed") { assert_enqueued_with "digest" }
  assert_includes message, "expected an enqueued \"digest\" job"
  # Only queued rows count: a job that ran is no longer enqueued.
  perform_enqueued_jobs
  message = assert_raises("AssertionFailed") { assert_enqueued_with "welcome", { "user_id" => 1 } }
  assert_includes message, "expected an enqueued \"welcome\" job"
end

test "perform_enqueued_jobs runs the due rows, returns the count and leaves future rows" do
  fresh_db
  Job.enqueue("welcome", "{\"user_id\":1}")
  Job.enqueue("digest", "{}")
  later = Time.now + 3600
  Job.enqueue("welcome", "{\"user_id\":9}", run_at: later)
  assert_equal 2, perform_enqueued_jobs
  assert_equal "welcome 1,digest", SEEN.join(",")
  assert_enqueued_jobs 1
  assert_enqueued_with "welcome", { "user_id" => 9 }
  assert_equal 0, perform_enqueued_jobs
  # A later `now` runs the future row.
  assert_equal 1, perform_enqueued_jobs(later + 1)
  assert_equal "welcome 9", SEEN[2]
  assert_no_enqueued_jobs
end

test "assert_enqueued_with reads Symbol keys as their names" do
  fresh_db
  Job.enqueue("welcome", "{\"user_id\":1,\"mode\":\"ok\"}")
  assert_enqueued_with "welcome", user_id: 1
  assert_enqueued_with "welcome", { user_id: "1", mode: "ok" }
  message = assert_raises("AssertionFailed") { assert_enqueued_with "welcome", user_id: 2 }
  assert_includes message, "expected an enqueued \"welcome\" job with {:user_id => 2}"
end

test "perform_enqueued_jobs fails after 10,000 jobs instead of running for ever" do
  fresh_db
  Job.enqueue("again", "{}", run_at: Time.at(1000))
  message = assert_raises("AssertionFailed") { perform_enqueued_jobs(Time.at(2000)) }
  assert_equal "perform_enqueued_jobs ran 10000 jobs; a job re-enqueues itself due at once", message
  assert_enqueued_jobs 1, "again"
  assert_equal 10_000, Job.state_count("done")
end

test "perform_enqueued_jobs leaves a retry scheduled into the future" do
  fresh_db
  Cybertrain.config.job_max_attempts = 3
  Job.enqueue("flaky", "{}")
  assert_equal 1, perform_enqueued_jobs
  assert_enqueued_jobs 1, "flaky"
  assert_equal 0, perform_enqueued_jobs
end

test "clear_enqueued_jobs deletes the queued rows and returns how many" do
  fresh_db
  Job.enqueue("welcome", "{\"user_id\":1}")
  Job.enqueue("digest", "{}")
  assert_equal 2, clear_enqueued_jobs
  assert_no_enqueued_jobs
  assert_equal 0, clear_enqueued_jobs
  assert_equal 0, perform_enqueued_jobs
  assert_equal 0, SEEN.length
end

Cybertrain::Test.run!
