require "stringio"
require "cybertrain"
require "cybertrain/test"

# Cybertrain::Job, compiled with the whole framework (NOTES rule 41): the
# cybertrain_jobs table created on demand, enqueue / claim / run / done,
# a failure retried with the backoff and counted, the final `failed`
# state, an unknown kind, a bounded last_error, recovery of rows left
# `running`, claimed_by and heartbeats, recovery by staleness only (two
# processes' labels in one database), the in-place column upgrade,
# and per-kind concurrency limits (test/job_threads.rb starts the real
# threads). Jobs are worked
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
Job.handle("paid", concurrency: 1) { |payload| SEEN << "paid #{payload}" }
Job.handle("other") { |payload| SEEN << "other #{payload}" }
# Runs recover! at the time in its payload while its own row is running.
Job.handle("probe") do |payload|
  requeued = Job.recover!(payload.to_i)
  SEEN << "#{requeued} #{job_state(1)}"
end
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
  insert_claimed(kind, state, "elsewhere:1:1", 1000)
end

# A row as another (or this) process's claim left it.
def insert_claimed(kind, state, label, heartbeat)
  binds = Cybertrain::Cast.binds(kind, state, label, heartbeat)
  id = 0
  DB.with do |c|
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, state, created_at, updated_at, claimed_by, heartbeat_at) " \
              "VALUES (?, '', 1000, ?, 1000, 1000, ?, ?)", binds)
    id = c.last_insert_id
  end
  id
end

def job_claimed_by(id)
  rows = DB.with { |c| c.execute("SELECT claimed_by FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["claimed_by"])
end

def job_heartbeat(id)
  rows = DB.with { |c| c.execute("SELECT heartbeat_at FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.int(rows[0]["heartbeat_at"])
end

def job_columns
  rows = DB.with { |c| c.execute("PRAGMA table_info('cybertrain_jobs')") }
  names = Array.new(0) { "" }
  rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
  names.join(",")
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

test "recover! requeues rows a dead process left running once their heartbeat is stale" do
  fresh_db
  Job.install!
  id = insert_raw("record", "running")
  assert_equal 0, Job.recover!(1300)
  assert_equal "running", job_state(id)
  assert_equal 1, Job.recover!(1301)
  assert_equal "queued", job_state(id)
  assert_equal 0, Job.recover!(1301)
end

test "a claim writes claimed_by and heartbeat_at; heartbeat! touches only this process's running rows" do
  fresh_db
  label = Job.process_label
  assert_equal 3, label.split(":").size
  assert_equal label, Job.process_label
  id = Job.enqueue("record", "one", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal label, job_claimed_by(id)
  assert_equal 1000, job_heartbeat(id)
  mine = insert_claimed("record", "running", label, 1000)
  theirs = insert_claimed("record", "running", "other-host:7:1", 1000)
  done = insert_claimed("record", "done", label, 1000)
  assert_equal 1, Job.heartbeat!(1100)
  assert_equal 1100, job_heartbeat(mine)
  assert_equal 1000, job_heartbeat(theirs)
  assert_equal 1000, job_heartbeat(done)
  assert_equal 1000, job_heartbeat(id)
end

test "two processes recovering: only the stale row is requeued, and only once" do
  fresh_db
  Job.install!
  now = 5000
  stale = insert_claimed("record", "running", "host-a:10:1", now - 301)
  fresh = insert_claimed("record", "running", "host-b:20:1", now - 299)
  # Process a's and process b's recover! at the same tick: one requeue.
  assert_equal 1, Job.recover!(now)
  assert_equal 0, Job.recover!(now)
  assert_equal "queued", job_state(stale)
  assert_equal "running", job_state(fresh)
  # b keeps beating (its rows are not this process's, so write it by hand):
  # a minute later it is still not stale.
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET heartbeat_at = ? WHERE id = ?", [now + 60, fresh]) }
  assert_equal 0, Job.recover!(now + 300)
  assert_equal "running", job_state(fresh)
  assert_equal 1, Job.recover!(now + 361)
end

test "install! adds claimed_by and heartbeat_at to a table made before them" do
  fresh_db
  DB.with do |c|
    c.exec_script("CREATE TABLE cybertrain_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, " \
                  "payload TEXT NOT NULL DEFAULT '', run_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, " \
                  "last_error TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', " \
                  "created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);")
    c.execute("INSERT INTO cybertrain_jobs (kind, run_at, state, created_at, updated_at) VALUES ('record', 1000, 'running', 1000, 1200)")
  end
  refute job_columns.include?("claimed_by")
  Job.install!
  assert_equal "id,kind,payload,run_at,attempts,last_error,state,created_at,updated_at,claimed_by,heartbeat_at", job_columns
  Job.install!
  # A probe job, claimed by work_one at 2000, calls recover!(2001) from its
  # handler: the old release's running row (no heartbeat) is requeued at
  # once, the probe's own row, claimed a second before, is left running.
  probe = Job.enqueue("probe", "2001", run_at: Time.at(1000))
  assert Job.work_one(2000)
  assert_equal "1 queued", SEEN.join(",")
  assert_equal "done", job_state(probe)
  assert_equal 0, Job.recover!(2001)
end

test "concurrency: a kind at its limit is skipped and another kind's job claimed" do
  fresh_db
  Job.install!
  running = insert_claimed("paid", "running", "host-a:10:1", 1000)
  assert_equal 1, Job.running_count("paid")
  assert_equal 0, Job.running_count("other")
  waiting = Job.enqueue("paid", "second", run_at: Time.at(1000))
  other = Job.enqueue("other", "x", run_at: Time.at(1001))
  assert Job.work_one(2000)
  assert_equal "done", job_state(other)
  assert_equal "queued", job_state(waiting)
  refute Job.work_one(2000)
  assert_equal "other x", SEEN.join(",")
  # The running one ends: the slot is free again.
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET state = 'done' WHERE id = ?", [running]) }
  assert_equal 0, Job.running_count("paid")
  assert Job.work_one(2000)
  assert_equal "done", job_state(waiting)
  assert_equal "other x,paid second", SEEN.join(",")
end

test "concurrency must not be negative" do
  assert_includes assert_raises("ArgumentError") { Job.handle("negative", concurrency: -1) { |p| SEEN << p } }, "concurrency must be 0"
  assert_equal(-1, Job.handler_index("negative"))
  assert_equal 1, Job::HANDLERS[Job.handler_index("paid")].handler_concurrency
  assert_equal 0, Job::HANDLERS[Job.handler_index("other")].handler_concurrency
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

Cybertrain::Test.run!
