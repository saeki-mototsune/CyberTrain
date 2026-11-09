require "stringio"
require "cybertrain"
require "cybertrain/test"

# Cybertrain::Job, compiled with the whole framework (NOTES rule 41): the
# cybertrain_jobs table created on demand, enqueue / claim / run / done,
# a failure retried with the backoff and counted, the final `failed`
# state, an unknown kind, a bounded last_error, recovery of rows left
# `running`, claimed_by and heartbeats, recovery by staleness only (two
# processes' labels in one database), the in-place column upgrade,
# per-kind concurrency limits (test/job_threads.rb starts the real
# threads), and Job.register: the Job::Run its block receives, the
# outcomes Job.retry_later and Job.discard write under the fence, the
# `discarded` state, per-kind max_attempts in recovery, and limits per
# concurrency key: the one key derivation, enqueue's key, the claim's
# (kind, key) pairs, the start backfill, keyed recovery and the upgrade
# that adds the column and its index. Jobs are worked
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
Job.handle("api", concurrency: 2) { |payload| SEEN << "api #{payload}" }
# Beats from inside its own run: heartbeat! touches the rows in flight.
Job.handle("beater") { |payload| SEEN << Job.heartbeat!(payload.to_i).to_s }
# While it runs, the row is recovered and claimed again by this same
# process (a second attempt): only the attempt number tells the claims
# apart.
Job.handle("again") do |payload|
  Job.recover!(5000, 300)
  DB.with do |c|
    c.execute("UPDATE cybertrain_jobs SET state = 'running', attempts = attempts + 1, heartbeat_at = 5000 " \
              "WHERE kind = 'again' AND state = 'queued'")
  end
  SEEN << "again"
end
# Plays a worker whose heartbeat went stale mid-job: while it runs (as
# "host-a"), the row is recovered and claimed again by "host-b"
# (work_one under that label runs the nested call, which just records),
# and then this first run ends normally, or raises with "fail".
Job.handle("reclaim") do |payload|
  if SEEN.empty?
    SEEN << "first"
    Job.recover!(5000, 300)
    mine = Job.override_process_label("host-b:2:1")
    SEEN << "reclaimed" if Job.work_one(5000)
    Job.override_process_label(mine)
    raise "first run failed" if payload == "fail"
  else
    SEEN << "second"
  end
end
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

# What Job.retry_later and Job.discard answered (seeded, NOTES rule 9).
OUTCOMES = Array.new(0) { Job::OUTCOME_STALE }

# Job.register: the block receives a Job::Run.
Job.register("run kind") { |run| SEEN << "#{run.run_kind}:#{run.run_attempts}:#{Cybertrain::Cast.int(run.run_args["n"])}" }
Job.register("plain") { |run| raise "bad" unless run.run_args.empty? }

# Policies written as the generated run_job(run) writes them: the rescue
# in a method body, the outcome written from it.
def retrying_job(run)
  begin
    raise ArgumentError, "try #{run.run_attempts}"
  rescue ArgumentError => e
    OUTCOMES << Job.retry_later(run, e, 60, run.run_payload == "poly", 3)
  end
  nil
end

def discarding_job(run)
  begin
    raise ArgumentError, "unusable #{run.run_payload}"
  rescue ArgumentError => e
    OUTCOMES << Job.discard(run, e)
  end
  raise "after the discard" if run.run_payload == "raise"
  nil
end

# Another process takes the row over while the policy runs: its write is
# fenced off.
def stolen_job(run)
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET claimed_by = 'thief:1:1:abcdef' WHERE id = ?", [run.run_id]) }
  begin
    raise ArgumentError, "stolen"
  rescue ArgumentError => e
    OUTCOMES << (run.run_payload == "discard" ? Job.discard(run, e) : Job.retry_later(run, e, 60, false, 3))
  end
  nil
end

Job.register("retrying") { |run| retrying_job(run) }
Job.register("discarding") { |run| discarding_job(run) }
Job.register("stolen") { |run| stolen_job(run) }
Job.register("long policy", max_attempts: 20) { |run| SEEN << run.run_payload }
Job.register("short policy", max_attempts: 2) { |run| SEEN << run.run_payload }
# One running at a time per "exchange".
Job.register("keyed", concurrency: 1, concurrency_key: "exchange") { |run| SEEN << "keyed #{Cybertrain::Cast.str(run.run_args["exchange"])}" }

def fresh_db
  DB.connect(":memory:")
  SEEN.pop until SEEN.empty?
  OUTCOMES.pop until OUTCOMES.empty?
  nil
end

def set_attempts(id, attempts)
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET attempts = ? WHERE id = ?", Cybertrain::Cast.binds(attempts, id)) }
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

def job_key(id)
  rows = DB.with { |c| c.execute("SELECT concurrency_key FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["concurrency_key"])
end

# A row written as an older release (or another process's claim) left it,
# with concurrency_key ''.
def insert_payload(kind, state, payload, heartbeat)
  binds = Cybertrain::Cast.binds(kind, payload, state, heartbeat)
  id = 0
  DB.with do |c|
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, state, created_at, updated_at, claimed_by, heartbeat_at) " \
              "VALUES (?, ?, 1000, ?, 1000, 1000, 'host-a:10:1:aaaaaa', ?)", binds)
    id = c.last_insert_id
  end
  id
end

def job_indexes
  rows = DB.with { |c| c.execute("PRAGMA index_list('cybertrain_jobs')") }
  names = Array.new(0) { "" }
  rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
  names.sort.join(",")
end

def index_columns(name)
  rows = DB.with { |c| c.execute("PRAGMA index_info('#{name}')") }
  names = Array.new(0) { "" }
  rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
  names.join(",")
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

test "recover! fails a stale row that used its last attempt instead of requeueing it" do
  fresh_db
  Job.install!
  # A payload that kills its process: every claim counted an attempt, and
  # the row was left running each time.
  last = insert_raw("record", "running")
  spare = insert_raw("record", "running")
  max = Cybertrain.config.job_max_attempts
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET attempts = ? WHERE id = ?", Cybertrain::Cast.binds(max, last)) }
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET attempts = ? WHERE id = ?", Cybertrain::Cast.binds(max - 1, spare)) }
  assert_equal 1, Job.recover!(1301)
  assert_equal "failed", job_state(last)
  assert_equal "process stopped (heartbeat stale) during attempt #{max} of #{max}", job_error(last)
  assert_equal "queued", job_state(spare)
  assert_includes LOG.string, "[ERROR] job #{last} (record) failed: process stopped (heartbeat stale) during attempt #{max} of #{max}"
  assert_equal 0, Job.recover!(1301)
end

test "a claim writes claimed_by and heartbeat_at; heartbeat! touches only the jobs in flight here" do
  fresh_db
  label = Job.process_label
  # host:pid:epoch:random
  assert_equal 4, label.split(":").size
  assert_equal 6, label.split(":")[3].size
  assert_equal label, Job.process_label
  id = Job.enqueue("record", "one", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal label, job_claimed_by(id)
  assert_equal 1000, job_heartbeat(id)
  # Running rows under this label that no thread here is running (a lost
  # outcome write), another process's, and a done one: none is touched.
  mine = insert_claimed("record", "running", label, 1000)
  theirs = insert_claimed("record", "running", "other-host:7:1:abcdef", 1000)
  done = insert_claimed("record", "done", label, 1000)
  assert_equal 0, Job.heartbeat!(1100)
  assert_equal 1000, job_heartbeat(mine)
  # A job that beats while it runs touches its own row, and only that.
  beater = Job.enqueue("beater", "1200", run_at: Time.at(1000))
  assert Job.work_one(1100)
  assert_equal "one,1", SEEN.join(",")
  assert_equal 1200, job_heartbeat(beater)
  assert_equal 1000, job_heartbeat(mine)
  assert_equal 1000, job_heartbeat(theirs)
  assert_equal 1000, job_heartbeat(done)
  assert_equal 0, Job.in_flight_ids.size
end

test "an outcome write that keeps failing leaves the row to staleness recovery" do
  fresh_db
  id = Job.enqueue("record", "lost", run_at: Time.at(1000))
  # Every try of the outcome write raises (a database locked past its busy
  # timeout).
  Job.fail_outcome_writes(Job::OUTCOME_TRIES)
  assert Job.work_one(1000)
  assert_equal "lost", SEEN.join(",")
  assert_equal "running", job_state(id)
  assert_includes LOG.string, "outcome write 3 of 3 failed: Cybertrain::DB::Error: outcome write failed on purpose"
  assert_includes LOG.string, "[ERROR] job #{id} (record) finished but its outcome could not be written; left running for heartbeat recovery"
  # It is no longer in flight: the heartbeat does not keep it alive ...
  assert_equal 0, Job.heartbeat!(1200)
  assert_equal 1000, job_heartbeat(id)
  # ... so it is recovered once stale, and runs again.
  assert_equal 0, Job.recover!(1300)
  assert_equal 1, Job.recover!(1301)
  assert Job.work_one(1301)
  assert_equal "done", job_state(id)
  assert_equal "lost,lost", SEEN.join(",")
end

test "an outcome write that fails once is retried and written" do
  fresh_db
  id = Job.enqueue("record", "kept", run_at: Time.at(1000))
  Job.fail_outcome_writes(1)
  assert Job.work_one(1000)
  assert_equal "done", job_state(id)
  assert_includes LOG.string, "[ERROR] job #{id}: outcome write 1 of 3 failed"
end

test "the outcome is fenced by the attempt: a later claim by this same process wins" do
  fresh_db
  id = Job.enqueue("again", "", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal "again", SEEN.join(",")
  # The second claim (attempt 2, same label) still runs; the first run's
  # outcome was discarded.
  assert_equal "running", job_state(id)
  assert_equal 2, job_attempts(id)
  assert_equal Job.process_label, job_claimed_by(id)
  assert_includes LOG.string, "[WARN] job #{id} (again) finished after it was reclaimed; outcome discarded"
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
  # The table needs no ALTER when another process already upgraded it;
  # here one of the two columns is already there.
  DB.with { |c| c.execute("ALTER TABLE cybertrain_jobs ADD COLUMN claimed_by TEXT") }
  Job.install!
  assert_equal "id,kind,payload,run_at,attempts,last_error,state,created_at,updated_at,claimed_by,heartbeat_at,concurrency_key", job_columns
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

test "an outcome written after the row was reclaimed is discarded" do
  ["ok", "fail"].each do |mode|
    fresh_db
    Job.override_process_label("host-a:1:1")
    id = Job.enqueue("reclaim", mode, run_at: Time.at(1000))
    # Claimed at 1000; by 5000 its heartbeat is stale.
    assert Job.work_one(1000)
    assert_equal "first,second,reclaimed", SEEN.join(",")
    # The second claimer's outcome stands, with its claim.
    assert_equal "done", job_state(id)
    assert_equal "host-b:2:1", job_claimed_by(id)
    assert_equal 2, job_attempts(id)
    assert_equal "", job_error(id)
    assert_includes LOG.string, "[WARN] job #{id} (reclaim) finished after it was reclaimed; outcome discarded"
    Job.override_process_label("")
  end
end

test "concurrency: two kinds at their limits at once are both left out" do
  fresh_db
  Job.install!
  insert_claimed("paid", "running", "host-a:10:1:aaaaaa", 1000)
  insert_claimed("api", "running", "host-a:10:1:aaaaaa", 1000)
  insert_claimed("api", "running", "host-b:20:1:bbbbbb", 1000)
  paid = Job.enqueue("paid", "p", run_at: Time.at(1000))
  api = Job.enqueue("api", "a", run_at: Time.at(1000))
  other = Job.enqueue("other", "o", run_at: Time.at(1002))
  assert Job.work_one(2000)
  assert_equal "other o", SEEN.join(",")
  assert_equal "queued", job_state(paid)
  assert_equal "queued", job_state(api)
  refute Job.work_one(2000)
  # One api slot frees up: api runs, paid still waits.
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET state = 'done' WHERE kind = 'api' AND claimed_by = 'host-b:20:1:bbbbbb'") }
  assert Job.work_one(2000)
  assert_equal "done", job_state(api)
  assert_equal "queued", job_state(paid)
  assert_equal "other o,api a", SEEN.join(",")
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

test "register gives the handler a Run with the parsed args and the attempt" do
  fresh_db
  id = Job.enqueue("run kind", "{\"n\":7}", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal "run kind:1:7", SEEN.join(",")
  assert_equal "done", job_state(id)
end

test "a non-object payload gives a Run whose run_args is {}" do
  fresh_db
  ["plain text", "[1,2]", "", "{\"broken\""].each { |payload| Job.enqueue("plain", payload, run_at: Time.at(1000)) }
  assert_equal 4, Job.work_due(1000)
  assert_equal 4, Job.state_count("done")
end

test "register refuses an empty kind, a taken one and a negative max_attempts; the fields are kept" do
  assert_includes assert_raises("ArgumentError") { Job.register("") { |run| SEEN << run.run_payload } }, "empty"
  assert_includes assert_raises("ArgumentError") { Job.register("record") { |run| SEEN << run.run_payload } }, "already registered"
  assert_includes assert_raises("ArgumentError") { Job.register("negative", max_attempts: -1) { |run| SEEN << run.run_payload } }, "max_attempts must be 0"
  assert_includes assert_raises("ArgumentError") { Job.register("negative", concurrency: -1) { |run| SEEN << run.run_payload } }, "concurrency must be 0"
  assert_equal(-1, Job.handler_index("negative"))
  assert_equal 20, Job::HANDLERS[Job.handler_index("long policy")].handler_max_attempts
  assert_equal 0, Job::HANDLERS[Job.handler_index("record")].handler_max_attempts
  assert_equal "", Job::HANDLERS[Job.handler_index("record")].handler_concurrency_key
end

test "retry_later requeues with the wait, fails at the limit, and answers the outcome" do
  fresh_db
  id = Job.enqueue("retrying", "fixed", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal Job::OUTCOME_REQUEUED, OUTCOMES[0]
  assert_equal "queued", job_state(id)
  assert_equal 1060, job_run_at(id)
  assert_equal "ArgumentError: try 1", job_error(id)
  assert_includes LOG.string, "[ERROR] job #{id} (retrying) attempt 1 of 3 failed: ArgumentError: try 1; retrying in 60 s"
  refute Job.work_one(1059)
  assert Job.work_one(1060)
  assert_equal 1120, job_run_at(id)
  assert Job.work_one(1120)
  assert_equal Job::OUTCOME_FAILED, OUTCOMES[2]
  assert_equal "failed", job_state(id)
  assert_equal 3, job_attempts(id)
  assert_equal "ArgumentError: try 3", job_error(id)
  assert_includes LOG.string, "[ERROR] job #{id} (retrying) failed after 3 attempts: ArgumentError: try 3"
  # Polynomially longer: attempts ** 4 + 2 seconds.
  poly = Job.enqueue("retrying", "poly", run_at: Time.at(2000))
  assert Job.work_one(2000)
  assert_equal 2003, job_run_at(poly)
  assert Job.work_one(2003)
  assert_equal 2021, job_run_at(poly)
  assert_equal "requeued,requeued,failed,requeued,requeued", OUTCOMES.map { |o| o.to_s }.join(",")
end

test "retry_later and discard answer OUTCOME_STALE when the row was reclaimed" do
  ["retry", "discard"].each do |mode|
    fresh_db
    id = Job.enqueue("stolen", mode, run_at: Time.at(1000))
    assert Job.work_one(1000)
    assert_equal Job::OUTCOME_STALE, OUTCOMES[0]
    # Untouched: still the thief's running claim, and finish wrote nothing.
    assert_equal "running", job_state(id)
    assert_equal "thief:1:1:abcdef", job_claimed_by(id)
    assert_equal "", job_error(id)
    assert_equal 1000, job_run_at(id)
    assert_includes LOG.string, "[WARN] job #{id} (stolen) finished after it was reclaimed; outcome discarded"
  end
end

test "discard writes discarded and prune_finished removes it with failed rows; prune_done does not" do
  fresh_db
  id = Job.enqueue("discarding", "x", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal Job::OUTCOME_FAILED, OUTCOMES[0]
  assert_equal "discarded", job_state(id)
  assert_equal 1, job_attempts(id)
  assert_equal "ArgumentError: unusable x", job_error(id)
  assert_includes LOG.string, "[ERROR] job #{id} (discarding) discarded: ArgumentError: unusable x"
  refute Job.work_one(999_999)
  assert_equal 1, Job.state_count("discarded")
  insert_raw("record", "done")
  insert_raw("record", "failed")
  assert_equal 1, Job.prune_done(2000)
  assert_equal 1, Job.state_count("discarded")
  assert_equal 0, Job.prune_finished(1000)
  assert_equal 2, Job.prune_finished(1001)
  assert_equal 0, Job.state_count("discarded")
  assert_equal 0, Job.state_count("failed")
end

test "a handler that writes its own outcome is not written again by finish" do
  fresh_db
  # It returns normally after retry_later: queued, not done.
  id = Job.enqueue("retrying", "fixed", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal "queued", job_state(id)
  assert_equal 1060, job_run_at(id)
  # It raises after discard: discarded, not queued by the default policy.
  raised = Job.enqueue("discarding", "raise", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal "discarded", job_state(raised)
  assert_equal "ArgumentError: unusable raise", job_error(raised)
  assert_includes LOG.string, "[ERROR] job #{raised} (discarding) raised after its outcome was written: RuntimeError: after the discard"
end

test "fail_exhausted uses the larger of the default and the kind's max_attempts" do
  fresh_db
  Job.install!
  assert_equal 5, Cybertrain.config.job_max_attempts
  assert_equal 20, Job.recovery_limit("long policy")
  assert_equal 5, Job.recovery_limit("short policy")
  assert_equal 5, Job.recovery_limit("record")
  assert_equal 5, Job.recovery_limit("gone")
  long = insert_raw("long policy", "running")
  long_last = insert_raw("long policy", "running")
  plain = insert_raw("record", "running")
  short = insert_raw("short policy", "running")
  short_last = insert_raw("short policy", "running")
  set_attempts(long, 5)
  set_attempts(long_last, 20)
  set_attempts(plain, 5)
  set_attempts(short, 3)
  set_attempts(short_last, 5)
  assert_equal 2, Job.recover!(1301)
  assert_equal "queued", job_state(long)
  assert_equal "failed", job_state(long_last)
  assert_equal "process stopped (heartbeat stale) during attempt 20 of 20", job_error(long_last)
  assert_equal "failed", job_state(plain)
  assert_equal "process stopped (heartbeat stale) during attempt 5 of 5", job_error(plain)
  assert_equal "queued", job_state(short)
  assert_equal "failed", job_state(short_last)
  assert_equal "process stopped (heartbeat stale) during attempt 5 of 5", job_error(short_last)
end

test "Job.handle still receives the payload String" do
  fresh_db
  id = Job.enqueue("record", "{\"n\":7}", run_at: Time.at(1000))
  assert Job.work_one(1000)
  assert_equal "{\"n\":7}", SEEN.join(",")
  assert_equal "done", job_state(id)
end

test "the key derivation is the same for a String, an Integer, a Float and a boolean" do
  assert_equal "X",    Job.concurrency_key_for("keyed", "{\"exchange\":\"X\"}")
  assert_equal "true", Job.concurrency_key_for("keyed", "{\"exchange\":true}")
  assert_equal "7",    Job.concurrency_key_for("keyed", "{\"exchange\":7}")
  assert_equal "7.5",  Job.concurrency_key_for("keyed", "{\"exchange\":7.5}")
  assert_equal "",     Job.concurrency_key_for("keyed", "{\"exchange\":null}")
  assert_equal "",     Job.concurrency_key_for("keyed", "{\"other\":1}")
  assert_equal "",     Job.concurrency_key_for("keyed", "not json")
  assert_equal "",     Job.concurrency_key_for("keyed", "[\"X\"]")
  # A kind with no key, and one not registered, have no key.
  assert_equal "",     Job.concurrency_key_for("record", "{\"exchange\":\"X\"}")
  assert_equal "",     Job.concurrency_key_for("nobody", "{\"exchange\":\"X\"}")
end

test "enqueue stores the key and refuses a payload without the field" do
  fresh_db
  keyed = Job.enqueue("keyed", "{\"exchange\":\"X\"}", run_at: Time.at(1000))
  plain = Job.enqueue("record", "{\"exchange\":\"X\"}", run_at: Time.at(1000))
  assert_equal "X", job_key(keyed)
  assert_equal "", job_key(plain)
  assert_equal "Job.enqueue \"keyed\": the payload has no \"exchange\" field for limits_concurrency",
               assert_raises("ArgumentError") { Job.enqueue("keyed", "{\"other\":1}") }
  assert_equal "Job.enqueue \"keyed\": the payload has no \"exchange\" field for limits_concurrency",
               assert_raises("ArgumentError") { Job.enqueue("keyed", "not json") }
  assert_equal 2, Job.state_count("queued")
end

test "two rows of the same key never run at once across two claimed_by labels; different keys do" do
  fresh_db
  Job.install!
  # host-a runs an "a" row (the older release's claim, keyed by enqueue
  # here through the column).
  running = Job.enqueue("keyed", "{\"exchange\":\"a\"}", run_at: Time.at(1000))
  Job.override_process_label("host-a:10:1:aaaaaa")
  assert Job.work_one(1000)
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET state = 'running' WHERE id = ?", [running]) }
  waiting = Job.enqueue("keyed", "{\"exchange\":\"a\"}", run_at: Time.at(1000))
  other = Job.enqueue("keyed", "{\"exchange\":\"b\"}", run_at: Time.at(1001))
  # host-b: the older "a" row is skipped, the "b" row is claimed.
  Job.override_process_label("host-b:20:1:bbbbbb")
  assert Job.work_one(2000)
  assert_equal "done", job_state(other)
  assert_equal "queued", job_state(waiting)
  refute Job.work_one(2000)
  assert_equal 1, Job.running_count("keyed")
  # The running "a" row ends: the key's slot is free again.
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET state = 'done' WHERE id = ?", [running]) }
  assert Job.work_one(2000)
  assert_equal "done", job_state(waiting)
  assert_equal "keyed a,keyed b,keyed a", SEEN.join(",")
  Job.override_process_label("")
end

test "backfill_keys keys queued rows of a keyed kind and lists the unkeyable ones" do
  fresh_db
  Job.install!
  keyable = insert_payload("keyed", "queued", "{\"exchange\":\"X\"}", 1000)
  unkeyable = insert_payload("keyed", "queued", "not json", 1000)
  missing = insert_payload("keyed", "queued", "{\"other\":1}", 1000)
  plain = insert_payload("record", "queued", "{\"exchange\":\"X\"}", 1000)
  running = insert_payload("keyed", "running", "{\"exchange\":\"X\"}", 1000)
  # More than one batch of 1000.
  DB.transaction do |c|
    i = 0
    while i < 1000
      c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, created_at, updated_at) VALUES ('keyed', ?, 1000, 1000, 1000)",
                ["{\"exchange\":\"n#{i % 3}\"}"])
      i += 1
    end
  end
  assert_equal 1001, Job.backfill_keys(2000)
  assert_equal "X", job_key(keyable)
  assert_equal "", job_key(unkeyable)
  assert_equal "", job_key(missing)
  assert_equal "", job_key(plain)
  assert_equal "", job_key(running)
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE concurrency_key IN ('n0', 'n1', 'n2')") }
  assert_equal 1000, Cybertrain::Cast.int(rows[0]["n"])
  assert_includes LOG.string, "[WARN] 2 queued job(s) of keyed have no \"exchange\" field to key them by; " \
                              "left in the \"\" bucket: ids #{unkeyable}, #{missing}"
  assert_equal 0, Job.backfill_keys(2000)
end

test "recovery requeues a stale running row with its key in the same statement" do
  fresh_db
  Job.install!
  keyed = insert_payload("keyed", "running", "{\"exchange\":\"X\"}", 1000)
  plain = insert_payload("record", "running", "{\"exchange\":\"X\"}", 1000)
  # Fresh heartbeats: untouched.
  assert_equal 0, Job.recover!(1300)
  assert_equal "running", job_state(keyed)
  assert_equal "", job_key(keyed)
  # Stale: both requeued, the keyed one with its key.
  assert_equal 2, Job.recover!(1301)
  assert_equal "queued", job_state(keyed)
  assert_equal "X", job_key(keyed)
  assert_equal "queued", job_state(plain)
  assert_equal "", job_key(plain)
  assert_equal 0, Job.recover!(1301)
end

test "an upgrade adds the column and the index to an existing table" do
  fresh_db
  DB.with do |c|
    c.exec_script("CREATE TABLE cybertrain_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, " \
                  "payload TEXT NOT NULL DEFAULT '', run_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, " \
                  "last_error TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued', " \
                  "created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, claimed_by TEXT, heartbeat_at INTEGER); " \
                  "CREATE INDEX index_cybertrain_jobs_on_state_and_run_at ON cybertrain_jobs (state, run_at);")
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, created_at, updated_at) VALUES ('keyed', '{\"exchange\":\"X\"}', 1000, 1000, 1000)")
  end
  refute job_columns.include?("concurrency_key")
  assert_equal "index_cybertrain_jobs_on_state_and_run_at", job_indexes
  Job.install!
  assert_equal "id,kind,payload,run_at,attempts,last_error,state,created_at,updated_at,claimed_by,heartbeat_at,concurrency_key", job_columns
  assert_equal "cybertrain_jobs_state_kind_key,index_cybertrain_jobs_on_state_and_run_at", job_indexes
  assert_equal "state,kind,concurrency_key", index_columns("cybertrain_jobs_state_kind_key")
  # The old row carries "" until the backfill keys it.
  assert_equal "", job_key(1)
  Job.install!
  assert_equal 1, Job.backfill_keys(2000)
  assert_equal "X", job_key(1)
  # A table made now has the same columns and indexes.
  fresh_db
  Job.install!
  assert_equal "id,kind,payload,run_at,attempts,last_error,state,created_at,updated_at,claimed_by,heartbeat_at,concurrency_key", job_columns
  assert_equal "cybertrain_jobs_state_kind_key,index_cybertrain_jobs_on_state_and_run_at", job_indexes
end

test "schema dumps leave the jobs table out" do
  fresh_db
  Job.install!
  DB.with { |c| c.exec_script("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT);") }
  assert_equal "posts", dumped_tables.join(",")
end

Cybertrain::Test.run!
