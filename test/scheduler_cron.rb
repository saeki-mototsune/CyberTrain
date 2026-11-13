require "stringio"
require "cybertrain/scheduler"
require "cybertrain/test"

# Cybertrain::Scheduler's cron tasks and the persisted timetable: a cron
# task runs at its minute in its zone, a job: task only enqueues, the
# timetable (cybertrain_schedules) carries an `every` interval across a
# restart or a change of leader, a missed cron slot is skipped unless
# catch_up, rows of names no longer registered are pruned, start! refuses
# an unregistered job kind, and a cron task whose next run cannot be
# computed is reported and skipped while the others run. Each test starts
# from no task and a new in-memory database (`fresh`); a "restart" is
# played by registering the tasks again on the same database. Ticks are
# driven with chosen epoch times through Scheduler.run_due; only the last
# test starts the real thread. It links SQLite through FFI, so its
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

S = Cybertrain::Scheduler
Timetable = Cybertrain::Scheduler::Timetable
DB = Cybertrain::DB
Job = Cybertrain::Job
TZ = Cybertrain::TimeZone

# What the tasks did, read back by the tests (a constant: NOTES rule 64).
RAN = Array.new(0) { "" }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# The job threads never start here: a job: task's job stays queued.
Job.handle("report") { |payload| raise "must not run here" }
Job.handle("audit") { |payload| RAN << "audit" }

def utc(y, m, d, h, mi)
  TZ.civil_to_epoch(y, m, d, h, mi, 0)
end

# No task, nothing run, a new database, this process's own label.
def fresh
  S.stop!
  S::TASKS.clear
  RAN.clear
  DB.disconnect if DB.connected?
  DB.connect(":memory:")
  nil
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

def ran_text
  RAN.join(",")
end

def next_run_of(name)
  S::TASKS[S.task_index(name)].task_next_run
end

def register_nightly
  S.cron("0 3 * * *", "nightly") { RAN << "nightly" }
  S.cron("0 3 * * *", "nightly catch up", catch_up: true) { RAN << "caught" }
end

test "a cron task runs at its minute and not before" do
  fresh
  S.cron("12 * * * *", "at twelve") { RAN << "twelve" }
  S.schedule_all(utc(2026, 11, 9, 10, 0))
  assert_equal utc(2026, 11, 9, 10, 12), next_run_of("at twelve")
  assert_equal 0, S.run_due(utc(2026, 11, 9, 10, 11) + 59)
  assert_equal 1, S.run_due(utc(2026, 11, 9, 10, 12))
  assert_equal 0, S.run_due(utc(2026, 11, 9, 10, 13))
  assert_equal "twelve", ran_text
  # The next run comes from the last one: 11:12.
  assert_equal utc(2026, 11, 9, 11, 12), next_run_of("at twelve")
  assert_equal 0, S.run_due(utc(2026, 11, 9, 11, 11))
  assert_equal 1, S.run_due(utc(2026, 11, 9, 11, 12))
  assert_equal "twelve,twelve", ran_text
end

test "tz: evaluates the expression in that zone; the default is config.scheduler_tz" do
  fresh
  S.cron("0 9 * * *", "tokyo morning", tz: "Asia/Tokyo") { RAN << "tokyo" }
  S.cron("0 9 * * *", "utc morning") { RAN << "utc" }
  assert_equal "Asia/Tokyo", S::TASKS[0].task_zone.zone_name
  assert_equal "UTC", S::TASKS[1].task_zone.zone_name
  S.schedule_all(utc(2026, 11, 9, 1, 0))
  # 09:00 in Tokyo is 00:00 UTC.
  assert_equal utc(2026, 11, 10, 0, 0), next_run_of("tokyo morning")
  assert_equal 1, S.run_due(utc(2026, 11, 9, 9, 0))
  assert_equal "utc", ran_text
  assert_equal 1, S.run_due(utc(2026, 11, 10, 0, 0))
  assert_equal "utc,tokyo", ran_text
end

test "cron refuses a bad expression, an unknown zone, an empty or taken name" do
  fresh
  assert_includes assert_raises("ArgumentError") { S.cron("61 * * * *", "bad minute") { RAN << "never" } },
                  "Scheduler.cron \"bad minute\": cron \"61 * * * *\":"
  assert_includes assert_raises("ArgumentError") { S.cron("@hourly", "shortcut") { RAN << "never" } },
                  "Scheduler.cron \"shortcut\": cron \"@hourly\": the @ shortcuts are not accepted"
  assert_equal "Scheduler.cron \"mars\": tz \"Mars/Base\" is not a known time zone",
               assert_raises("ArgumentError") { S.cron("0 9 * * *", "mars", tz: "Mars/Base") { RAN << "never" } }
  assert_equal "Scheduler.cron: the name is empty", assert_raises("ArgumentError") { S.cron("0 9 * * *", "") { RAN << "never" } }
  S.every(60, "taken") { RAN << "taken" }
  assert_equal "Scheduler.cron \"taken\": already registered",
               assert_raises("ArgumentError") { S.cron("0 9 * * *", "taken") { RAN << "never" } }
  assert_equal 1, S::TASKS.size
end

test "the timetable survives a restart and a leader change" do
  fresh
  t0 = utc(2026, 11, 9, 10, 0)
  S.every(600, "x") { RAN << "x" }
  S.schedule_all(t0)
  assert_equal 1, S.run_due(t0 + 600)
  rows = Timetable.read_all
  assert_equal [t0 + 600, t0 + 1200], rows["x"]
  # A restart: the process registers its tasks again and reads the table.
  S::TASKS.clear
  S.every(600, "x") { RAN << "x" }
  S.schedule_all(t0 + 700)
  assert_equal t0 + 1200, next_run_of("x")
  # Another process takes over once this one's lease (renewed at t0 + 600,
  # for 30 s) has expired: it continues from the table too.
  mine = Job.override_process_label("other:1:1:000000")
  S::TASKS.clear
  S.every(600, "x") { RAN << "x" }
  S.schedule_all(t0 + 700)
  assert_equal 0, S.run_due(t0 + 700)
  assert S.leader?
  assert_equal 0, S.run_due(t0 + 1199)
  assert_equal 1, S.run_due(t0 + 1200)
  assert_equal "x,x", ran_text
  Job.override_process_label(mine)
  # A process down past the next run executes the task once, at its first tick.
  S::TASKS.clear
  S.every(600, "x") { RAN << "x" }
  S.schedule_all(t0 + 5000)
  assert_equal t0 + 1800, next_run_of("x")
  assert_equal 1, S.run_due(t0 + 5000)
  assert_equal 0, S.run_due(t0 + 5001)
  assert_equal "x,x,x", ran_text
  assert_equal t0 + 5600, next_run_of("x")
end

test "a cron task changed before its first run follows the new expression, not the stored slot" do
  fresh
  # The release before registered "digest" weekly ("0 3 * * 1") and never
  # ran it; its row says next Monday 2026-11-16 03:00. Now it is hourly.
  Timetable.write("digest", 0, utc(2026, 11, 16, 3, 0), utc(2026, 11, 10, 9, 0))
  S.cron("0 * * * *", "digest") { RAN << "digest" }
  S.schedule_all(utc(2026, 11, 10, 9, 30))
  assert_equal utc(2026, 11, 10, 10, 0), next_run_of("digest")
  assert_equal 1, S.run_due(utc(2026, 11, 10, 10, 0))
  assert_equal "digest", ran_text
end

test "a process that takes the lease over schedules from the table, not from its own guess" do
  fresh
  t0 = utc(2026, 11, 9, 10, 0)
  S.every(600, "x") { RAN << "x" }
  S.schedule_all(t0 - 595)
  # Another process leads until t0 + 690.
  assert Cybertrain::Lease.acquire("scheduler", "other:1:1:000000", t0, ttl: 690)
  # Not leading, this process guesses the leader ran x when it ticked:
  # next at t0 + 605, then t0 + 1250.
  assert_equal 0, S.run_due(t0 + 5)
  assert_equal 0, S.run_due(t0 + 650)
  refute S.leader?
  assert_equal t0 + 1250, next_run_of("x")
  # The leader really ran it at t0 and t0 + 600.
  Timetable.write("x", t0 + 600, t0 + 1200, t0 + 600)
  # Taking over at t0 + 700, it continues from the table: no run now,
  # the next at t0 + 1200.
  assert_equal 0, S.run_due(t0 + 700)
  assert S.leader?
  assert_equal t0 + 1200, next_run_of("x")
  assert_equal 1, S.run_due(t0 + 1200)
  assert_equal "x", ran_text
end

test "a process that takes the lease over runs a cron slot the table records as due, once" do
  fresh
  register_nightly
  # Scheduled at 02:00: both rows say 03:00. Another process leads until
  # 03:04:59 and dies before running the slot.
  S.schedule_all(utc(2026, 11, 9, 2, 0))
  assert Cybertrain::Lease.acquire("scheduler", "other:1:1:000000", utc(2026, 11, 9, 2, 0), ttl: 3899)
  assert_equal 0, S.run_due(utc(2026, 11, 9, 2, 30))
  assert_equal 0, S.run_due(utc(2026, 11, 9, 3, 0))
  refute S.leader?
  # This process takes over at 03:05: each slot runs once, then the next
  # is 03:00 the next day.
  assert_equal 2, S.run_due(utc(2026, 11, 9, 3, 5))
  assert S.leader?
  assert_equal "nightly,caught", ran_text
  assert_equal utc(2026, 11, 10, 3, 0), next_run_of("nightly")
  assert_equal utc(2026, 11, 10, 3, 0), next_run_of("nightly catch up")
  assert_equal 0, S.run_due(utc(2026, 11, 9, 3, 6))
  assert_equal [utc(2026, 11, 9, 3, 5), utc(2026, 11, 10, 3, 0)], Timetable.read_all["nightly"]
end

test "one process that misses the lease at a cron slot runs the slot at its next tick" do
  fresh
  S.cron("0 3 * * *", "nightly") { RAN << "nightly" }
  S.schedule_all(utc(2026, 11, 9, 2, 0))
  assert_equal 0, S.run_due(utc(2026, 11, 9, 2, 59))
  assert S.leader?
  # At 03:00 the tick cannot take the lease (another holder has it until
  # then); the next one does, and runs the slot once.
  binds = Cybertrain::Cast.binds(utc(2026, 11, 9, 3, 0))
  DB.with { |c| c.execute("UPDATE cybertrain_leases SET holder = 'thief:1:1:000000', expires_at = ? WHERE name = 'scheduler'", binds) }
  assert_equal 0, S.run_due(utc(2026, 11, 9, 3, 0))
  refute S.leader?
  assert_equal 1, S.run_due(utc(2026, 11, 9, 3, 0) + 1)
  assert S.leader?
  assert_equal "nightly", ran_text
  assert_equal utc(2026, 11, 10, 3, 0), next_run_of("nightly")
  assert_equal 0, S.run_due(utc(2026, 11, 9, 3, 1))
  assert_equal "nightly", ran_text
end

test "a cold start whose first tick misses the lease still skips a slot that passed while no process ran" do
  fresh
  S.cron("0 3 * * *", "nightly") { RAN << "nightly" }
  S.schedule_all(utc(2026, 11, 9, 2, 0))
  # Down from before 03:00 until 04:00; the dead process's lease runs to
  # 04:00, so the first tick after the start cannot take it.
  S::TASKS.clear
  S.cron("0 3 * * *", "nightly") { RAN << "nightly" }
  assert Cybertrain::Lease.acquire("scheduler", "gone:1:1:000000", utc(2026, 11, 9, 2, 30), ttl: 5400)
  S.schedule_all(utc(2026, 11, 9, 4, 0))
  assert_equal 0, S.run_due(utc(2026, 11, 9, 4, 0))
  refute S.leader?
  # The second tick takes the lease: still the cold start, so 03:00 does
  # not run, and the next run is 03:00 tomorrow.
  assert_equal 0, S.run_due(utc(2026, 11, 9, 4, 0) + 1)
  assert S.leader?
  assert_equal "", ran_text
  assert_equal utc(2026, 11, 10, 3, 0), next_run_of("nightly")
end

# A row from last week, a start at 02:00 under a dead predecessor's
# lease that lasts until just before `takeover`; true when the takeover
# tick ran the task.
def old_row_takeover(takeover)
  S.cron("0 3 * * *", "nightly") { RAN << "nightly" }
  Timetable.write("nightly", utc(2026, 11, 1, 3, 0), utc(2026, 11, 2, 3, 0), utc(2026, 11, 1, 3, 0))
  start = utc(2026, 11, 9, 2, 0)
  Cybertrain::Lease.acquire("scheduler", "gone:1:1:000000", start, ttl: takeover - start - 1)
  S.schedule_all(start)
  S.run_due(start)
  S.run_due(takeover - 300) if takeover - 300 > start
  S.leader? ? false : S.run_due(takeover) == 1
end

test "a takeover runs a slot that came due since the start although the row is old" do
  fresh
  # Ticks fail from 02:00 until 03:05, across the 03:00 slot.
  assert old_row_takeover(utc(2026, 11, 9, 3, 5))
  assert S.leader?
  assert_equal "nightly", ran_text
  assert_equal utc(2026, 11, 10, 3, 0), next_run_of("nightly")
end

test "a takeover before any slot came due since the start runs nothing" do
  fresh
  refute old_row_takeover(utc(2026, 11, 9, 2, 30))
  assert S.leader?
  assert_equal "", ran_text
  assert_equal utc(2026, 11, 9, 3, 0), next_run_of("nightly")
  assert_equal 1, S.run_due(utc(2026, 11, 9, 3, 0))
  assert_equal "nightly", ran_text
end

test "a missed cron slot is skipped unless catch_up" do
  fresh
  register_nightly
  # Scheduled at 02:00; both rows say 03:00.
  S.schedule_all(utc(2026, 11, 9, 2, 0))
  assert_equal [0, utc(2026, 11, 9, 3, 0)], Timetable.read_all["nightly"]
  # The process is down until 04:00.
  S::TASKS.clear
  register_nightly
  S.schedule_all(utc(2026, 11, 9, 4, 0))
  assert_equal 1, S.run_due(utc(2026, 11, 9, 4, 0))
  assert_equal "caught", ran_text
  assert_equal 0, S.run_due(utc(2026, 11, 9, 4, 1))
  assert_equal 0, S.run_due(utc(2026, 11, 10, 2, 59))
  assert_equal 2, S.run_due(utc(2026, 11, 10, 3, 0))
  assert_equal "caught,nightly,caught", ran_text
  # Down again from the 10th's run until the 11th, 04:00: the same, from
  # the recorded last runs.
  S::TASKS.clear
  register_nightly
  S.schedule_all(utc(2026, 11, 11, 4, 0))
  assert_equal utc(2026, 11, 12, 3, 0), next_run_of("nightly")
  assert_equal 1, S.run_due(utc(2026, 11, 11, 4, 0))
  assert_equal "caught,nightly,caught,caught", ran_text
  # Once caught up, it continues on its schedule.
  assert_equal utc(2026, 11, 12, 3, 0), next_run_of("nightly catch up")
end

test "a job: task enqueues and does not run the job on the scheduler thread" do
  fresh
  S.cron("* * * * *", "r", job: "report", args: { "scope" => "all" })
  S.schedule_all(utc(2026, 11, 9, 10, 0))
  assert_equal 1, S.run_due(utc(2026, 11, 9, 10, 1))
  assert_equal 1, Job.state_count("queued")
  rows = DB.with { |c| c.execute("SELECT kind, payload FROM cybertrain_jobs") }
  assert_equal "report", Cybertrain::Cast.str(rows[0]["kind"])
  assert_equal "{\"scope\":\"all\"}", Cybertrain::Cast.str(rows[0]["payload"])
  refute LOG.string.include?("must not run here")
end

test "a job: task needs a registered kind, and a block or job: but not both" do
  fresh
  assert_equal "Scheduler.cron \"neither\": give a block or job:, not neither",
               assert_raises("ArgumentError") { S.cron("* * * * *", "neither") }
  assert_equal "Scheduler.cron \"both\": give a block or job:, not both",
               assert_raises("ArgumentError") { S.cron("* * * * *", "both", job: "report") { RAN << "never" } }
  assert_equal 0, S::TASKS.size
  assert_equal "", S.job_kinds_error
  S.cron("* * * * *", "u", job: "unknown")
  message = "Scheduler.cron \"u\": job \"unknown\" is not a registered job kind (registered: report, audit)"
  assert_equal message, S.job_kinds_error
  assert_equal message, assert_raises("ArgumentError") { S.start!(Cybertrain::Config.new) }
  refute S.running?
end

test "task_summary names cron tasks with their next run in UTC" do
  fresh
  S.every(60, "minutely") { RAN << "minutely" }
  S.cron("12 * * * *", "at twelve", tz: "Asia/Tokyo") { RAN << "twelve" }
  S.cron("0 9 * * *", "report", job: "report")
  S.schedule_all(utc(2026, 11, 9, 10, 0))
  assert_equal "minutely every 60s, at twelve (cron \"12 * * * *\" Asia/Tokyo) next 2026-11-09T10:12Z, " \
               "report (cron \"0 9 * * *\" UTC) next 2026-11-10T09:00Z", S.task_summary
end

test "a cron task with no next run runs its due slot once, is reported once, then is skipped" do
  fresh
  # After 2096-02-29 the next 29 February falls on a Thursday in 2104,
  # beyond Cron.next_after's five years.
  S.cron("0 0 29 2 *", "leap day") { RAN << "leap" }
  S.every(60, "minutely") { RAN << "minutely" }
  S.schedule_all(utc(2096, 2, 28, 23, 59))
  assert_equal utc(2096, 2, 29, 0, 0), next_run_of("leap day")
  assert_equal 2, S.run_due(utc(2096, 2, 29, 0, 0))
  assert_equal "leap,minutely", ran_text
  error = "[ERROR] Scheduled task \"leap day\" failed: ArgumentError: cron \"0 0 29 2 *\": no run in the 5 years after 2096-02-29 00:00 UTC"
  assert_includes LOG.string, error
  assert_equal(-1, next_run_of("leap day"))
  # The row keeps the slot it ran; no negative next_run_at is written.
  assert_equal [utc(2096, 2, 29, 0, 0), utc(2096, 2, 29, 0, 0)], Timetable.read_all["leap day"]
  # Disabled: later ticks skip it without another error; the others run.
  assert_equal 1, S.run_due(utc(2096, 2, 29, 0, 1))
  assert_equal 1, S.run_due(utc(2096, 2, 29, 0, 2))
  assert_equal "leap,minutely,minutely,minutely", ran_text
  assert_equal 1, count_of(LOG.string, "Scheduled task \"leap day\" failed")
end

test "the timetable: rows read back as [last, next], 0 for a run that never happened" do
  fresh
  assert_equal 0, Timetable.read_all.size
  Timetable.write("a", 0, 200, 100)
  Timetable.write("b", 300, 400, 300)
  Timetable.write("a", 200, 260, 200)
  rows = Timetable.read_all
  assert_equal [200, 260], rows["a"]
  assert_equal [300, 400], rows["b"]
  Timetable.write("c", 0, 500, 100)
  assert_equal [0, 500], Timetable.read_all["c"]
  names = Array.new(0) { "" }
  names << "b"
  assert_equal 2, Timetable.prune(names)
  assert_equal 1, Timetable.read_all.size
end

test "the timetable never moves a row back; a new task's row never replaces one" do
  fresh
  # The new leader's row, then the old leader's late write: ignored.
  Timetable.write("x", 1000, 1600, 1000)
  Timetable.write("x", 400, 1000, 1200)
  assert_equal [1000, 1600], Timetable.read_all["x"]
  # The same last run with an earlier next run: ignored too.
  Timetable.write("x", 1000, 1500, 1300)
  assert_equal [1000, 1600], Timetable.read_all["x"]
  Timetable.write_missing("x", 50, 1300)
  assert_equal [1000, 1600], Timetable.read_all["x"]
  Timetable.write_missing("y", 700, 1300)
  assert_equal [0, 700], Timetable.read_all["y"]
  # A later run moves it on.
  Timetable.write("x", 1600, 2200, 1600)
  assert_equal [1600, 2200], Timetable.read_all["x"]
end

test "a cron task without tz: takes config.scheduler_tz as it is when the scheduler starts" do
  fresh
  saved = Cybertrain.config.scheduler_tz
  # A bad default does not raise at registration (boot reports it).
  Cybertrain.config.scheduler_tz = "Mars/Base"
  S.cron("0 9 * * *", "later zone") { RAN << "later" }
  Cybertrain.config.scheduler_tz = "Asia/Tokyo"
  S.schedule_all(utc(2026, 11, 9, 1, 0))
  assert_equal "Asia/Tokyo", S::TASKS[0].task_zone.zone_name
  assert_equal utc(2026, 11, 10, 0, 0), next_run_of("later zone")
  Cybertrain.config.scheduler_tz = saved
end

test "prune_schedules deletes the rows of names no longer registered" do
  fresh
  S.every(60, "kept") { RAN << "kept" }
  Timetable.write("kept", 100, 160, 100)
  Timetable.write("gone", 100, 160, 100)
  assert_equal 1, S.prune_schedules
  assert_equal 1, Timetable.read_all.size
  assert_equal [100, 160], Timetable.read_all["kept"]
end

test "config: scheduler_tz is UTC, from CYBERTRAIN_SCHEDULER_TZ, and boot refuses an unknown zone" do
  assert_equal "UTC", Cybertrain::Config.new.scheduler_tz
  ENV["CYBERTRAIN_SCHEDULER_TZ"] = "Asia/Tokyo"
  config = Cybertrain::Config.new
  assert_equal "Asia/Tokyo", config.scheduler_tz
  assert_equal "", config.scheduler_error
  config.scheduler_tz = "Mars/Base"
  assert_equal "scheduler_tz \"Mars/Base\" is not a known time zone", config.scheduler_error
  ENV.delete("CYBERTRAIN_SCHEDULER_TZ")
end

test "config: scheduler_tz defaults to time_zone; CYBERTRAIN_SCHEDULER_TZ and an assignment win" do
  ENV.delete("CYBERTRAIN_SCHEDULER_TZ")
  ENV["CYBERTRAIN_TIME_ZONE"] = "Asia/Tokyo"
  config = Cybertrain::Config.new
  assert_equal "Asia/Tokyo", config.scheduler_tz
  # It follows a later assignment of time_zone while it was never set.
  config.time_zone = "Europe/London"
  assert_equal "Europe/London", config.scheduler_tz
  ENV["CYBERTRAIN_SCHEDULER_TZ"] = "UTC"
  assert_equal "UTC", Cybertrain::Config.new.scheduler_tz
  ENV.delete("CYBERTRAIN_SCHEDULER_TZ")
  config.scheduler_tz = "America/New_York"
  config.time_zone = "UTC"
  assert_equal "America/New_York", config.scheduler_tz
  ENV.delete("CYBERTRAIN_TIME_ZONE")
  # An unknown time_zone is reported once, as time_zone, not again as
  # scheduler_tz.
  unknown = Cybertrain::Config.new
  unknown.time_zone = "Mars/Base"
  assert_equal "time_zone \"Mars/Base\" is not a known time zone", unknown.validation_error
end

# Sets Cybertrain.config.time_zone to name, with scheduler_tz following
# it, for the block, and puts both back when it ends, also when an
# assertion in it fails (spikes/NOTES.md rule 103's save-yield-ensure in a
# module function).
module ConfigZone
  def self.during(name)
    c = Cybertrain.config
    saved = c.time_zone
    saved_tz = c.scheduler_tz
    c.scheduler_tz = ""
    c.time_zone = name
    _value = yield
    nil
  ensure
    Cybertrain.config.time_zone = saved
    Cybertrain.config.scheduler_tz = saved_tz
  end
end

test "a cron task without tz: runs in time_zone; a task's tz: still wins" do
  fresh
  ConfigZone.during("Asia/Tokyo") do
    S.cron("0 9 * * *", "zone morning") { RAN << "zone" }
    S.cron("0 9 * * *", "utc morning", tz: "UTC") { RAN << "utc" }
    S.schedule_all(utc(2026, 11, 10, 1, 0))
    assert_equal "Asia/Tokyo", S::TASKS[0].task_zone.zone_name
    assert_equal "UTC", S::TASKS[1].task_zone.zone_name
    # 09:00 in Tokyo is 00:00 UTC.
    assert_equal Time.utc(2026, 11, 11, 0).to_i, next_run_of("zone morning")
    assert_equal Time.utc(2026, 11, 10, 9).to_i, next_run_of("utc morning")
  end
end

# Last: the thread it starts keeps running until the program exits.
test "start! prunes the rows of names no longer registered" do
  fresh
  S.every(600, "kept") { RAN << "kept" }
  Timetable.write("gone", 100, 160, 100)
  assert S.start!(Cybertrain::Config.new)
  rows = Timetable.read_all
  refute rows.key?("gone")
  S.stop!
end

Cybertrain::Test.run!
