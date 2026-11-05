require "stringio"
require "cybertrain"
require "cybertrain/test"

# Cybertrain::Job's thread pool (Job.start! / Job.stop!), with real
# threads against a temporary database file: rows a dead process left are
# requeued at start, two job threads run a slow and a fast job at once
# (the fast one is not held up by the slow one), the heartbeat thread
# moves a running job's heartbeat_at, stop! waits at most
# job_drain_timeout and leaves an unfinished job `running` for staleness
# recovery, and the scheduler no longer runs jobs as a task. Assertions
# are on order and bounds; no time is printed. Compiled with the whole
# framework (NOTES rule 41); it links SQLite through FFI, so its snapshot
# comes from the compiled binary (rule 23).

DB = Cybertrain::DB
Job = Cybertrain::Job

# What the handlers did, in order (constants: NOTES rule 64), and the lock
# the job threads take to append to it.
EVENTS = Array.new(0) { "" }
EVENTS_LOCK = Mutex.new

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

DIR = "tmp/job_threads_test"
PATH = "#{DIR}/jobs.sqlite3"

def record_event(text)
  EVENTS_LOCK.synchronize { EVENTS << text }
  nil
end

def events_text
  text = ""
  EVENTS_LOCK.synchronize { text = EVENTS.join(",") }
  text
end

def clear_events
  EVENTS_LOCK.synchronize { EVENTS.pop until EVENTS.empty? }
  nil
end

# The heartbeat of the running `beat` row less its claim time.
def beat_lag
  rows = DB.with { |c| c.execute("SELECT heartbeat_at - updated_at AS d FROM cybertrain_jobs WHERE kind = 'beat' AND state = 'running'") }
  return -1 if rows.empty?

  Cybertrain::Cast.int(rows[0]["d"])
end

Job.handle("record") { |payload| record_event(payload) }
Job.handle("slow") do |payload|
  sleep 1
  record_event("slow")
end
Job.handle("fast") { |payload| record_event("fast") }
Job.handle("beat") do |payload|
  sleep 2
  record_event(beat_lag >= 1 ? "beat moved" : "beat still")
end
Job.handle("long") do |payload|
  sleep 3
  record_event("long")
end

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# Polls the condition every 20 ms for at most `seconds`; true once it holds.
def wait_until(seconds, &condition)
  ends_at = monotonic + seconds
  while monotonic < ends_at
    return true if condition.call

    sleep 0.02
  end
  condition.call
end

def fresh_db
  Dir.mkdir("tmp") unless File.directory?("tmp")
  Dir.mkdir(DIR) unless File.directory?(DIR)
  ["", "-wal", "-shm"].each { |suffix| File.delete("#{PATH}#{suffix}") if File.exist?("#{PATH}#{suffix}") }
  DB.connect(PATH)
  clear_events
  nil
end

def pool_config(threads)
  config = Cybertrain::Config.new
  config.job_threads = threads
  config.job_poll_interval = 1
  config.job_heartbeat_interval = 1
  config.job_drain_timeout = 1
  config
end

def enqueue_now(kind, payload)
  Job.enqueue(kind, payload, run_at: Time.at(Time.now.to_i - 1))
end

def job_state(id)
  rows = DB.with { |c| c.execute("SELECT state FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["state"])
end

test "start! requeues a dead process's stale rows, runs them, and starts only once" do
  fresh_db
  Job.install!
  DB.with do |c|
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, state, attempts, created_at, updated_at, claimed_by, heartbeat_at) " \
              "VALUES ('record', 'left over', 1000, 'running', 1, 1000, 1000, 'gone:1:1', 1000)")
  end
  config = pool_config(1)
  refute Job.running?
  assert Job.start!(config)
  assert Job.running?
  refute Job.start!(config)
  assert_includes LOG.string, "[WARN] Requeued 1 job(s) whose process stopped sending heartbeats"
  assert_includes LOG.string, "[INFO] Job threads started: 1 (#{Job.process_label})"
  assert wait_until(2.0) { Job.state_count("done") == 1 }
  assert_equal "left over", events_text
  Job.stop!
  refute Job.running?
  assert_equal 0, Job.live_loops
end

test "two job threads: a slow and a fast job are claimed together, and the fast one ends first" do
  fresh_db
  slow = enqueue_now("slow", "")
  fast = enqueue_now("fast", "")
  assert Job.start!(pool_config(2))
  assert wait_until(0.5) { Job.state_count("queued") == 0 }
  assert wait_until(3.0) { Job.state_count("done") == 2 }
  assert_equal "fast,slow", events_text
  assert_equal "done", job_state(slow)
  assert_equal "done", job_state(fast)
  Job.stop!
  assert_equal 0, Job.live_loops
end

test "an idle job thread picks up a job enqueued after it started within the poll interval" do
  fresh_db
  assert Job.start!(pool_config(1))
  sleep 0.2
  enqueue_now("fast", "")
  assert wait_until(1.5) { Job.state_count("done") == 1 }
  assert_equal "fast", events_text
  Job.stop!
end

test "the heartbeat thread moves a running job's heartbeat_at" do
  fresh_db
  enqueue_now("beat", "")
  assert Job.start!(pool_config(1))
  assert wait_until(4.0) { Job.state_count("done") == 1 }
  assert_equal "beat moved", events_text
  Job.stop!
end

test "the scheduler no longer runs jobs as a task" do
  fresh_db
  assert_equal(-1, Cybertrain::Scheduler.task_index("cybertrain jobs"))
  # Handlers alone start it (its ticks recover jobs), with no task of its own.
  assert Cybertrain::Scheduler.start!(pool_config(1))
  assert_equal(-1, Cybertrain::Scheduler.task_index("cybertrain jobs"))
  assert_includes LOG.string, "[INFO] Scheduler started: no scheduled tasks"
  Cybertrain::Scheduler.stop!
end

# Last: the long job's thread outlives stop!, so the program waits for it.
test "stop! waits at most job_drain_timeout and leaves an unfinished job running for recovery" do
  fresh_db
  long = enqueue_now("long", "")
  assert Job.start!(pool_config(1))
  assert wait_until(0.5) { Job.running_count("long") == 1 }
  started = monotonic
  Job.stop!
  waited = monotonic - started
  assert waited >= 0.9
  assert waited < 1.5
  refute Job.running?
  assert_equal "running", job_state(long)
  assert_equal 1, Job.live_loops
  assert_includes LOG.string, "[WARN] 1 job(s) still running at shutdown; left to heartbeat recovery"
  now = Time.now.to_i
  # Its heartbeat is fresh: no other process may take it yet.
  assert_equal 0, Job.recover!(now, 300)
  # Once it is stale, one recover! requeues it.
  assert_equal 1, Job.recover!(now + 301, 300)
  assert_equal "queued", job_state(long)
  # The old thread finishes the job it had and ends.
  assert wait_until(4.0) { Job.live_loops == 0 }
  assert_equal "long", events_text
  # Its outcome is fenced off: the requeued row stays queued.
  assert_equal "queued", job_state(long)
  assert_includes LOG.string, "[WARN] job #{long} (long) finished after it was reclaimed; outcome discarded"
end

Cybertrain::Test.run!
