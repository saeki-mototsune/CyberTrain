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

test "a cron task with no next run is reported and skipped; the others run" do
  fresh
  # After 2096-02-29 the next 29 February falls on a Thursday in 2104,
  # beyond Cron.next_after's five years.
  S.cron("0 0 29 2 *", "leap day") { RAN << "leap" }
  S.every(60, "minutely") { RAN << "minutely" }
  S.schedule_all(utc(2096, 2, 28, 23, 59))
  assert_equal utc(2096, 2, 29, 0, 0), next_run_of("leap day")
  assert_equal 1, S.run_due(utc(2096, 2, 29, 0, 0))
  assert_equal "minutely", ran_text
  assert_includes LOG.string, "[ERROR] Scheduled task \"leap day\" failed: ArgumentError: cron \"0 0 29 2 *\": no run in the 5 years after 2096-02-29 00:00 UTC"
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
