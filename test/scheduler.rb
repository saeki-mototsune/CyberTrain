require "stringio"
require "cybertrain/scheduler"
require "cybertrain/test"
require_relative "support/log_capture"

# Cybertrain::Scheduler: tasks registered with `every` run when due and
# not before, a raising task is logged and the others (and its own next
# run) go on, last_tick follows the ticks, and start! honours
# Config#worker; only the holder of the "scheduler" lease runs tasks, and
# a tick recovers stale jobs at most once a minute while job threads run.
# The ticks are driven with chosen epoch times through Scheduler.run_due,
# so nothing sleeps; the job threads of the recovery test and the last
# test's scheduler thread are real. Runs are recorded in the timetable
# (test/scheduler_cron.rb covers it). It requires the job queue (and so
# SQLite through FFI) with the scheduler, so its snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).

S = Cybertrain::Scheduler
Lease = Cybertrain::Lease
DB = Cybertrain::DB
Job = Cybertrain::Job

# What the tasks did, read back by the tests (a constant: NOTES rule 64).
RUNS = Array.new(0) { "" }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# Registered at top level, as an application's config/app.rb does.
S.every(10, "tick ten") { RUNS << "ten" }
S.every(25, "boom") { raise "it broke" }
S.every(30, "thirty") { RUNS << "thirty" }
# Not due before 1000 + 999999: only the lease-loss test reaches them. The
# first hands the lease to another holder while the tick runs, when STEAL
# is set.
STEAL = Array.new(0) { "" }
S.every(999_999, "steal") do
  RUNS << "steal"
  unless STEAL.empty?
    DB.with { |c| c.execute("UPDATE cybertrain_leases SET holder = 'thief:1:1:000000', expires_at = 9999999 WHERE name = 'scheduler'") }
  end
end
S.every(999_999, "after steal") { RUNS << "after steal" }
# A task that sets the thread's locale and one that reports the locale it
# starts in (never due in the ticks above; run through run_task).
LOCALES = Array.new(0) { "" }
I18n.available_locales = [:en, :ja]
S.every(999_999, "in ja") { I18n.locale = :ja; LOCALES << "set #{I18n.locale}" }
S.every(999_999, "locale") { LOCALES << "starts #{I18n.locale}" }

Job.handle("noop") { |payload| RUNS << "job" }

# The lease lives in the database: every tick takes or renews it.
DB.connect(":memory:")

# A running row a dead process left, not due again until far in the
# future (so the job thread never claims it once it is requeued).
def insert_stale_running
  id = 0
  DB.with do |c|
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, state, attempts, created_at, updated_at, claimed_by, heartbeat_at) " \
              "VALUES ('noop', '', 9999999999, 'running', 1, 1000, 1000, 'gone:1:1', 1000)")
    id = c.last_insert_id
  end
  id
end

def job_state(id)
  rows = DB.with { |c| c.execute("SELECT state FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["state"])
end

def runs_text
  RUNS.join(",")
end

def count_of(text, needle)
  n = 0
  at = text.index(needle)
  until at.nil?
    n += 1
    at = text.index(needle, at + needle.size)
  end
  n
end

test "every registers tasks in order" do
  assert_equal 0, S.task_index("tick ten")
  assert_equal 1, S.task_index("boom")
  assert_equal 2, S.task_index("thirty")
  assert_equal(-1, S.task_index("missing"))
end

test "every refuses a bad interval, an empty name and a taken one" do
  assert_includes assert_raises("ArgumentError") { S.every(0, "zero") { RUNS << "never" } }, "at least 1"
  assert_includes assert_raises("ArgumentError") { S.every(5, "") { RUNS << "never" } }, "empty"
  assert_includes assert_raises("ArgumentError") { S.every(5, "boom") { RUNS << "never" } }, "already registered"
  assert_equal(-1, S.task_index("zero"))
end

test "the first tick only schedules; a task runs when due and not before" do
  assert_equal 0, S.run_due(1000)
  assert_equal "", runs_text
  assert_equal 0, S.run_due(1009)
  assert_equal "", runs_text
  assert_equal 1, S.run_due(1010)
  assert_equal "ten", runs_text
  # The next run is an interval after the run that happened.
  assert_equal 0, S.run_due(1019)
  assert_equal 1, S.run_due(1020)
  assert_equal "ten,ten", runs_text
end

test "a raising task is logged and does not stop the others" do
  # boom is due at 1025, thirty at 1030, ten at 1030.
  assert_equal 1, S.run_due(1025)
  assert_logged LOG.string, "ERROR", "Scheduled task \"boom\" failed: RuntimeError: it broke"
  assert_equal 2, S.run_due(1030)
  assert_equal "ten,ten,ten,thirty", runs_text
  # boom runs (and fails) again at its next time, next to ten (due since
  # 1040): the loop went on.
  assert_equal 2, S.run_due(1050)
  assert_equal "ten,ten,ten,thirty,ten", runs_text
  assert_equal 2, count_of(LOG.string, "it broke")
end

test "last_tick is the time of the latest tick" do
  S.run_due(1060)
  assert_equal 1060, S.last_tick
  S.run_due(1061)
  assert_equal 1061, S.last_tick
end

test "only the lease holder runs due tasks; another takes over once the lease expires" do
  assert_equal Job.process_label, S.holder
  # The ticks so far took the lease (last renewed at 1061, for 30 s).
  assert S.leader?
  assert_equal S.holder, Lease.lease_holder("scheduler")
  assert_equal 1091, Lease.lease_expires_at("scheduler")
  # Another process takes it once it has expired.
  assert Lease.acquire("scheduler", "other:1:1", 2000, ttl: 30)
  before = runs_text
  # Every task is overdue, but this process does not lead: it runs none.
  assert_equal 0, S.run_due(2001)
  refute S.leader?
  assert_equal 0, S.run_due(2030)
  assert_equal before, runs_text
  assert_equal 2030, S.last_tick
  # What the other leader recorded in the timetable as it ran the tasks.
  Cybertrain::Scheduler::Timetable.write("tick ten", 2030, 2040, 2030)
  Cybertrain::Scheduler::Timetable.write("boom", 2026, 2051, 2026)
  Cybertrain::Scheduler::Timetable.write("thirty", 2001, 2031, 2001)
  # The other's lease ran out at 2030: the next tick leads, re-reads the
  # timetable and runs what is due by it, not every task the other led
  # through.
  assert_equal 1, S.run_due(2031)
  assert S.leader?
  assert_equal S.holder, Lease.lease_holder("scheduler")
  assert_equal "#{before},thirty", runs_text
  refute Lease.acquire("scheduler", "other:1:1", 2032, ttl: 30)
end

test "a tick that cannot reach the database runs nothing, logs, and leads again later" do
  DB.disconnect
  assert_equal 0, S.run_due(3000)
  refute S.leader?
  assert_equal 3000, S.last_tick
  assert_logged LOG.string, "ERROR", "Scheduler lease: Cybertrain::DB::Error: not connected"
  DB.connect(":memory:")
  # The failed tick kept the timetable: nothing is due at 3001, ten at 3010.
  assert_equal 0, S.run_due(3001)
  assert S.leader?
  assert_equal 1, S.run_due(3010)
end

test "while job threads run, every tick (leader or not) recovers stale jobs, at most once a minute" do
  Job.install!
  stale_one = insert_stale_running
  # Job threads do not run yet: the tick leaves the row alone.
  S.run_due(4000)
  assert_equal "running", job_state(stale_one)
  config = Cybertrain::Config.new
  config.job_threads = 1
  # start! recovers with the real time, so the row is requeued at once.
  assert Job.start!(config)
  assert_equal "queued", job_state(stale_one)
  stale_two = insert_stale_running
  S.run_due(4001)
  assert_equal "queued", job_state(stale_two)
  stale_three = insert_stale_running
  S.run_due(4031)
  S.run_due(4060)
  assert_equal "running", job_state(stale_three)
  S.run_due(4061)
  assert_equal "queued", job_state(stale_three)
  assert_logged LOG.string, "WARN", "Requeued 1 job(s) whose process stopped sending heartbeats"
  # Recovery does not wait for the lease: with another process leading, no
  # task runs, but the tick still recovers.
  assert Lease.acquire("scheduler", "other:1:1", 4100, ttl: 100)
  stale_five = insert_stale_running
  assert_equal 0, S.run_due(4121)
  refute S.leader?
  assert_equal "queued", job_state(stale_five)
  # The other's lease ran out at 4200: this process leads and runs the tasks.
  assert_equal 3, S.run_due(4201)
  assert S.leader?
  Job.stop!
  # Without job threads, no more recovery.
  stale_four = insert_stale_running
  S.run_due(5000)
  assert_equal "running", job_state(stale_four)
end

test "a leader that loses the lease during a tick runs no further task in it" do
  STEAL << "on"
  before = runs_text
  # ten, boom, thirty, then steal (which hands the lease away); "after
  # steal" is due too, but the lease is renewed before each task and the
  # renewal now fails.
  assert_equal 4, S.run_due(2_000_000)
  refute S.leader?
  assert_equal "#{before},ten,thirty,steal", runs_text
  assert_equal "thief:1:1:000000", Lease.lease_holder("scheduler")
  STEAL.pop
end

test "start! does nothing when the worker switch is off" do
  config = Cybertrain::Config.new
  config.worker = false
  refute S.start!(config)
  refute S.running?
  assert_logged LOG.string, "INFO", "Background worker off (CYBERTRAIN_WORKER=0)"
end

test "config: the worker switch and the intervals have their defaults, and boot checks them" do
  config = Cybertrain::Config.new
  assert config.worker
  assert_equal 1, config.scheduler_interval
  assert_equal 1, config.job_poll_interval
  assert_equal 5, config.job_max_attempts
  assert_equal 3, config.job_threads
  assert_equal 30, config.job_heartbeat_interval
  assert_equal 300, config.job_heartbeat_stale
  assert_equal 10, config.job_drain_timeout
  assert_equal 30, config.scheduler_lease_ttl
  assert_equal "", config.scheduler_error
  config.job_poll_interval = 0
  assert_includes config.scheduler_error, "job_poll_interval must be at least 1"
end

test "config: each job and lease setting must be at least 1, and stale more than the interval" do
  config = Cybertrain::Config.new
  config.job_threads = 0
  assert_equal "job_threads must be at least 1 (got 0)", config.scheduler_error
  config.job_threads = 3
  config.job_heartbeat_interval = 0
  assert_equal "job_heartbeat_interval must be at least 1 (got 0)", config.scheduler_error
  config.job_heartbeat_interval = 30
  config.job_heartbeat_stale = 0
  assert_equal "job_heartbeat_stale must be at least 1 (got 0)", config.scheduler_error
  config.job_heartbeat_stale = 30
  assert_equal "job_heartbeat_stale (30) must be more than job_heartbeat_interval (30)", config.scheduler_error
  config.job_heartbeat_stale = 31
  assert_equal "", config.scheduler_error
  config.scheduler_interval = 16
  assert_equal "scheduler_lease_ttl (30) must be at least twice scheduler_interval (16)", config.scheduler_error
  config.scheduler_interval = 15
  assert_equal "", config.scheduler_error
  config.scheduler_interval = 1
  config.job_drain_timeout = 0
  assert_equal "job_drain_timeout must be at least 1 (got 0)", config.scheduler_error
  config.job_drain_timeout = 10
  config.scheduler_lease_ttl = -1
  assert_equal "scheduler_lease_ttl must be at least 1 (got -1)", config.scheduler_error
end

test "config: CYBERTRAIN_JOB_THREADS sets job_threads; a word is the default, 0 is kept for boot to refuse" do
  ENV["CYBERTRAIN_JOB_THREADS"] = "8"
  assert_equal 8, Cybertrain::Config.new.job_threads
  ENV["CYBERTRAIN_JOB_THREADS"] = "many"
  assert_equal 3, Cybertrain::Config.new.job_threads
  ENV["CYBERTRAIN_JOB_THREADS"] = "0"
  zero = Cybertrain::Config.new
  assert_equal 0, zero.job_threads
  assert_includes zero.scheduler_error, "job_threads must be at least 1"
  ENV.delete("CYBERTRAIN_JOB_THREADS")
  assert_equal 3, Cybertrain::Config.new.job_threads
end

test "every continues from last_run_at after schedule_all" do
  # The table says "thirty" last ran at 6000 (its row from the ticks
  # above, which is later, is removed first: a write never moves a row
  # back): schedule_all (a restart) continues from there, not an interval
  # after its own now.
  Cybertrain::Scheduler::Timetable.prune(["tick ten", "boom", "steal", "after steal"])
  Cybertrain::Scheduler::Timetable.write("thirty", 6000, 6030, 6000)
  S.schedule_all(6010)
  assert_equal 6030, S::TASKS[S.task_index("thirty")].task_next_run
  # One the table has never seen starts an interval after now.
  Cybertrain::Scheduler::Timetable.prune(["tick ten", "boom", "steal", "after steal"])
  S.schedule_all(6010)
  assert_equal 6040, S::TASKS[S.task_index("thirty")].task_next_run
  assert_equal [0, 6040], Cybertrain::Scheduler::Timetable.read_all["thirty"]
end

test "a task that never ran takes its current schedule when that is earlier than the stored next run" do
  # An earlier release registered "thirty" weekly and never ran it: its
  # row says next 6010 + 7 days. Now it is every 30 s, so it runs 30 s
  # after the start, not six days later.
  Cybertrain::Scheduler::Timetable.prune(["tick ten", "boom", "steal", "after steal"])
  Cybertrain::Scheduler::Timetable.write("thirty", 0, 6010 + 7 * 86_400, 6010)
  S.schedule_all(6010)
  assert_equal 6040, S::TASKS[S.task_index("thirty")].task_next_run
  # A stored next run earlier than the schedule gives is kept: it runs
  # once then, and follows the schedule after that.
  Cybertrain::Scheduler::Timetable.prune(["tick ten", "boom", "steal", "after steal"])
  Cybertrain::Scheduler::Timetable.write("thirty", 0, 6020, 6010)
  S.schedule_all(6010)
  assert_equal 6020, S::TASKS[S.task_index("thirty")].task_next_run
  Cybertrain::Scheduler::Timetable.prune(["tick ten", "boom", "steal", "after steal"])
end

test "a task that sets the locale does not leave it for the next task on the same thread" do
  assert S.run_task(S::TASKS[S.task_index("in ja")])
  assert S.run_task(S::TASKS[S.task_index("locale")])
  assert_equal "set ja,starts en", LOCALES.join(",")
  I18n.locale = nil
end

# Last: the thread it starts keeps running until the program exits. With
# the timetable emptied, start! schedules every task an interval after the
# real time, so the thread's first tick runs nothing.
test "start! starts the thread once; stop! asks it to end" do
  Cybertrain::Scheduler::Timetable.prune(Array.new(0) { "" })
  config = Cybertrain::Config.new
  started = Time.now.to_i
  assert S.start!(config)
  assert S.running?
  refute S.start!(config)
  # The thread ticks at once (with the real time) when this one yields.
  sleep 0.3
  assert S.last_tick >= started
  assert_logged LOG.string, "INFO", "Scheduler started: tick ten every 10s, boom every 25s, thirty every 30s, steal every 999999s, after steal every 999999s, " \
                                   "in ja every 999999s, locale every 999999s"
  assert S.leader?
  S.stop!
  refute S.running?
  # stop! handed the lease back.
  refute S.leader?
  assert_equal "", Lease.lease_holder("scheduler")
end

Cybertrain::Test.run!
