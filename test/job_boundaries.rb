require "cybertrain/test"
require "cybertrain/job/retry_policy"

# The boundaries inside Cybertrain::Job (docs/design.md D68, issue #184).
# Job::RetryPolicy is checked with nothing else of the framework in the
# program: no database, no Config, no handler registry, so this file also
# runs under CRuby (`ruby -I. test/job_boundaries.rb`). The other tests
# read the sources of the parts: the store names no thread and no pool,
# and the worker and the executor hold no SQL. What the parts do together
# is test/jobs.rb and test/job_threads.rb.

Policy = Cybertrain::Job::RetryPolicy

# The code of a framework file: its lines less the comment lines.
def code_of(path)
  out = +""
  File.read(path).split("\n").each do |line|
    out << line << "\n" unless line.strip.start_with?("#")
  end
  out
end

# The words of `words` that `text` contains, joined with ", ".
def found_in(text, words)
  found = Array.new(0) { "" }
  words.each { |word| found << word if text.include?(word) }
  found.join(", ")
end

SQL_WORDS = ["cybertrain_jobs", "SELECT ", "UPDATE ", "INSERT ", "DELETE ", "DB.with", "DB.transaction", ".execute("].freeze
THREAD_WORDS = ["Thread", "Mutex", "sleep", "Worker", "Executor", "running?", "request_stop", "start!", "stop!",
                "handler_run_block"].freeze

test "the default policy waits 1, 5, 15 and then 60 minutes" do
  assert_equal 60, Policy.default_wait(1)
  assert_equal 300, Policy.default_wait(2)
  assert_equal 900, Policy.default_wait(3)
  assert_equal 3600, Policy.default_wait(4)
  assert_equal 3600, Policy.default_wait(50)
  # An attempt number below 1 is read as the first.
  assert_equal 60, Policy.default_wait(0)
  assert_equal 60, Policy.default_wait(-3)
end

test "a retry_on policy waits its base, or attempts ** 4 + 2 when polynomial" do
  assert_equal 45, Policy.policy_wait(1, 45, false)
  assert_equal 45, Policy.policy_wait(7, 45, false)
  assert_equal 3, Policy.policy_wait(1, 45, true)
  assert_equal 18, Policy.policy_wait(2, 45, true)
  assert_equal 83, Policy.policy_wait(3, 45, true)
  assert_equal 10_002, Policy.policy_wait(10, 0, true)
end

test "an attempt is the last once it reaches the limit" do
  refute Policy.exhausted?(1, 5)
  refute Policy.exhausted?(4, 5)
  assert Policy.exhausted?(5, 5)
  assert Policy.exhausted?(6, 5)
  # A limit of 1 allows the first attempt only.
  assert Policy.exhausted?(1, 1)
end

test "recovery gives up at the larger of the default and the kind's own limit" do
  assert_equal 5, Policy.recovery_limit(0, 5)
  assert_equal 5, Policy.recovery_limit(3, 5)
  assert_equal 5, Policy.recovery_limit(5, 5)
  assert_equal 20, Policy.recovery_limit(20, 5)
end

test "the error text is Class: message, cut at 1000 characters" do
  assert_equal "RuntimeError: boom", Policy.error_text("RuntimeError", "boom")
  assert_equal "RuntimeError: ", Policy.error_text("RuntimeError", "")
  long = Policy.error_text("RuntimeError", "x" * 2000)
  assert_equal Policy::MAX_ERROR_LENGTH, long.size
  assert long.start_with?("RuntimeError: xxx")
  exact = "y" * Policy::MAX_ERROR_LENGTH
  assert_equal exact, Policy.bounded(exact)
  assert_equal exact, Policy.bounded("#{exact}z")
end

test "the retry policy requires nothing and names no database, Config or clock" do
  code = code_of("cybertrain/job/retry_policy.rb")
  assert_equal "", found_in(code, ["require", "DB", "Cybertrain.config", "Time.", "logger", "Store"])
end

test "the store names no thread, no pool and no handler call" do
  code = code_of("cybertrain/job/store.rb")
  assert_equal "", found_in(code, THREAD_WORDS)
  # (It is the file with the SQL: the check below is not vacuous.)
  assert_includes code, "cybertrain_jobs"
end

test "the worker and the executor hold no SQL" do
  assert_equal "", found_in(code_of("cybertrain/job/worker.rb"), SQL_WORDS)
  assert_equal "", found_in(code_of("cybertrain/job/executor.rb"), SQL_WORDS)
  # The pool's threads are the worker's, and only the worker's.
  assert_includes code_of("cybertrain/job/worker.rb"), "Thread.new"
  refute code_of("cybertrain/job/executor.rb").include?("Thread")
end

test "the facade keeps no statement of its own" do
  assert_equal "", found_in(code_of("cybertrain/job.rb"), SQL_WORDS)
end

Cybertrain::Test.run!
