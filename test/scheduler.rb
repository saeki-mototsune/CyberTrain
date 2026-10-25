require "stringio"
require "cybertrain/scheduler"
require "cybertrain/test"

# Cybertrain::Scheduler: tasks registered with `every` run when due and
# not before, a raising task is logged and the others (and its own next
# run) go on, last_tick follows the ticks, and start! honours
# Config#worker. The ticks are driven with chosen epoch times through
# Scheduler.run_due, so nothing sleeps; only the last test starts the real
# thread. It requires the job queue (and so SQLite through FFI) with the
# scheduler, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).

S = Cybertrain::Scheduler

# What the tasks did, read back by the tests (a constant: NOTES rule 64).
RUNS = Array.new(0) { "" }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# Registered at top level, as an application's config/app.rb does.
S.every(10, "tick ten") { RUNS << "ten" }
S.every(25, "boom") { raise "it broke" }
S.every(30, "thirty") { RUNS << "thirty" }

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
  assert_includes LOG.string, "[ERROR] Scheduled task \"boom\" failed: RuntimeError: it broke"
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

test "start! does nothing when the worker switch is off" do
  config = Cybertrain::Config.new
  config.worker = false
  refute S.start!(config)
  refute S.running?
  assert_includes LOG.string, "[INFO] Background worker off (CYBERTRAIN_WORKER=0)"
end

test "config: the worker switch and the intervals have their defaults, and boot checks them" do
  config = Cybertrain::Config.new
  assert config.worker
  assert_equal 1, config.scheduler_interval
  assert_equal 5, config.job_poll_interval
  assert_equal 5, config.job_max_attempts
  assert_equal "", config.scheduler_error
  config.job_poll_interval = 0
  assert_includes config.scheduler_error, "job_poll_interval must be at least 1"
end

# Last: the thread it starts keeps running until the program exits. start!
# schedules every task an interval after the real time, so the thread's
# first tick runs nothing.
test "start! starts the thread once; stop! asks it to end" do
  config = Cybertrain::Config.new
  started = Time.now.to_i
  assert S.start!(config)
  assert S.running?
  refute S.start!(config)
  # The thread ticks at once (with the real time) when this one yields.
  sleep 0.3
  assert S.last_tick >= started
  assert_includes LOG.string, "[INFO] Scheduler started: tick ten every 10s, boom every 25s, thirty every 30s"
  S.stop!
  refute S.running?
end

Cybertrain::Test.run!
