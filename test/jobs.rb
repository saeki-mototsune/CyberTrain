require "stringio"
require "cybertrain"
require "cybertrain/test"

# Cybertrain::Job, compiled with the whole framework (NOTES rule 41): the
# cybertrain_jobs table created on demand, enqueue / claim / run / done,
# a failure retried with the backoff and counted, the final `failed`
# state, an unknown kind, a bounded last_error, recovery of rows left
# `running`, and the scheduler adding the worker task. Jobs are worked
# with chosen epoch times through Job.work_one, so nothing sleeps. It
# links SQLite through FFI, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Job = Cybertrain::Job

# What the handlers saw (a constant: NOTES rule 64).
SEEN = Array.new(0) { "" }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

Job.handle("record") { |payload| SEEN << payload }
Job.handle("boom") { |payload| raise "boom #{payload}" }
Job.handle("long") { |payload| raise "x" * 5000 }
# Fails twice, then succeeds.
Job.handle("flaky") do |payload|
  SEEN << "flaky"
  raise "not yet" if SEEN.size < 3
end

def fresh_db
  DB.connect(":memory:")
  SEEN.pop until SEEN.empty?
  nil
end

def job_state(id)
  rows = DB.with { |c| c.execute("SELECT state FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["state"])
end

def job_attempts(id)
  rows = DB.with { |c| c.execute("SELECT attempts FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.int(rows[0]["attempts"])
end

def job_run_at(id)
  rows = DB.with { |c| c.execute("SELECT run_at FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.int(rows[0]["run_at"])
end

def job_error(id)
  rows = DB.with { |c| c.execute("SELECT last_error FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["last_error"])
end

def insert_raw(kind, state)
  binds = Cybertrain::Cast.binds(kind, state)
  id = 0
  DB.with do |c|
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, state, created_at, updated_at) VALUES (?, '', 1000, ?, 1000, 1000)", binds)
    id = c.last_insert_id
  end
  id
end

def dumped_tables
  DB.with { |c| DB::SchemaDumper.table_names(c) }
end

# A job enqueued in a transaction that raises, in a method body (NOTES
# rule 45).
def enqueue_then_raise
  DB.transaction do |c|
    Job.enqueue("record", "lost", run_at: Time.at(1000))
    raise "roll it back"
  end
  nil
end

test "handle refuses an empty kind and a taken one; enqueue refuses an unknown kind" do
  fresh_db
  assert Job.handlers?
  assert_includes assert_raises("ArgumentError") { Job.handle("") { |p| SEEN << p } }, "empty"
  assert_includes assert_raises("ArgumentError") { Job.handle("record") { |p| SEEN << p } }, "already registered"
  assert_includes assert_raises("ArgumentError") { Job.enqueue("nope", "") }, "no handler registered for \"nope\""
end

test "enqueue creates the table; a job runs when due, oldest first, and ends done" do
  fresh_db
  late = Job.enqueue("record", "second", run_at: Time.at(2000))
  early = Job.enqueue("record", "first", run_at: Time.at(1500))
  assert_equal "queued", job_state(early)
  assert_equal 0, job_attempts(early)
  refute Job.work_one(1499)
  assert Job.work_one(2000)
  assert_equal "first", SEEN.join(",")
  assert_equal "done", job_state(early)
  assert_equal 1, job_attempts(early)
  assert_equal "queued", job_state(late)
  assert Job.work_one(2000)
  refute Job.work_one(2000)
  assert_equal "first,second", SEEN.join(",")
  assert_equal 2, Job.state_count("done")
  assert_includes LOG.string, "[INFO] job #{early} (record) done"
end

test "a failing job is retried with the backoff, counting attempts, until it is failed" do
  fresh_db
  Cybertrain.config.job_max_attempts = 3
  id = Job.enqueue("boom", "x", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal "queued", job_state(id)
  assert_equal 1, job_attempts(id)
  assert_equal 1060, job_run_at(id)
  assert_equal "RuntimeError: boom x", job_error(id)
  assert_includes LOG.string, "[ERROR] job #{id} (boom) attempt 1 of 3 failed: RuntimeError: boom x; retrying in 60 s"
  refute Job.work_one(1059)
  assert Job.work_one(1060)
  assert_equal 2, job_attempts(id)
  assert_equal 1360, job_run_at(id)
  assert Job.work_one(1360)
  assert_equal "failed", job_state(id)
  assert_equal 3, job_attempts(id)
  assert_equal "RuntimeError: boom x", job_error(id)
  assert_includes LOG.string, "[ERROR] job #{id} (boom) failed after 3 attempts: RuntimeError: boom x"
  refute Job.work_one(999_999)
  assert_equal 1, Job.state_count("failed")
  Cybertrain.config.job_max_attempts = 5
end

test "a job that fails and then succeeds ends done" do
  fresh_db
  id = Job.enqueue("flaky", "", run_at: Time.at(1000))
  # One claim per call: a failed attempt is rescheduled past `now`.
  assert_equal 1, Job.work_due(1000)
  assert_equal 1, Job.work_due(1060)
  assert_equal "queued", job_state(id)
  assert_equal 1, Job.work_due(1360)
  assert_equal "done", job_state(id)
  assert_equal 3, job_attempts(id)
  assert_equal "", job_error(id)
end

test "the backoff list is 1, 5, 15 and then 60 minutes" do
  assert_equal 60, Job.backoff(1)
  assert_equal 300, Job.backoff(2)
  assert_equal 900, Job.backoff(3)
  assert_equal 3600, Job.backoff(4)
  assert_equal 3600, Job.backoff(9)
end

test "a job of a kind with no handler is failed at once, with last_error" do
  fresh_db
  Job.install!
  id = insert_raw("gone", "queued")
  assert Job.work_one(1000)
  assert_equal "failed", job_state(id)
  assert_equal 1, job_attempts(id)
  assert_equal "no handler registered for kind \"gone\"", job_error(id)
end

test "last_error is bounded" do
  fresh_db
  id = Job.enqueue("long", "", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal Job::MAX_ERROR_LENGTH, job_error(id).size
end

test "recover! requeues rows a dead process left running" do
  fresh_db
  Job.install!
  id = insert_raw("record", "running")
  assert_equal 1, Job.recover!(1000)
  assert_equal "queued", job_state(id)
  assert_equal 0, Job.recover!(1000)
end

test "a job enqueued in a transaction that rolls back is gone with it" do
  fresh_db
  assert_raises("RuntimeError") { enqueue_then_raise }
  # The table the enqueue created inside it went too (SQLite's DDL is
  # transactional); the next use creates it again.
  assert_equal 0, Job.state_count("queued")
  Job.enqueue("record", "kept", run_at: Time.at(1000))
  assert_equal 1, Job.state_count("queued")
end

test "prune_done deletes old done rows and keeps failed ones" do
  fresh_db
  Job.install!
  insert_raw("record", "done")
  insert_raw("record", "failed")
  assert_equal 1, Job.prune_done(2000)
  assert_equal 0, Job.state_count("done")
  assert_equal 1, Job.state_count("failed")
end

test "schema dumps leave the jobs table out" do
  fresh_db
  Job.install!
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT);") }
  assert_equal "posts", dumped_tables.join(",")
end

# Last: start! leaves a thread running until the program exits.
test "the scheduler adds the job worker task when handlers are registered" do
  fresh_db
  Job.install!
  id = insert_raw("record", "running")
  config = Cybertrain::Config.new
  assert Cybertrain::Scheduler.start!(config)
  assert Cybertrain::Scheduler.task_index(Cybertrain::Scheduler::JOB_TASK_NAME) >= 0
  assert_equal "queued", job_state(id)
  assert_includes LOG.string, "[WARN] Requeued 1 job(s) left running by a previous process"
  assert_includes LOG.string, "Scheduler started: cybertrain jobs every 5s"
  Cybertrain::Scheduler.stop!
end

Cybertrain::Test.run!
