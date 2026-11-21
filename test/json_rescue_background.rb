require "stringio"
require "cybertrain"
require "cybertrain/test"

# `rescue StandardError` alone catches JSON's errors in the background
# code: a job handler, a scheduled task, a job thread and a plain Thread
# that raise JSON::ParserError or JSON::NestingError are rescued by the
# framework's StandardError arms (Executor.run_handler, the Scheduler's
# run_task, Worker.claim_safely's Exception arm), which no longer name
# the two JSON classes first. spikes/NOTES.md rules 33 and 61 said the
# classes had to be named; this is the test of the shape those rules ask
# for before the idiom is dropped, and what fails if a compiler brings
# the gap back. Compiled with the whole framework (NOTES rule 41); it
# links SQLite through FFI, so its snapshot comes from the compiled
# binary (rule 23).

DB = Cybertrain::DB
Job = Cybertrain::Job
S = Cybertrain::Scheduler
LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# What the plain threads rescued, and the lock they append under.
OUT = Array.new(0) { "" }
OUT_LOCK = Mutex.new

DIR = "tmp/json_rescue_background_test"
PATH = "#{DIR}/jobs.sqlite3"

# An Array nested n deep: JSON.generate refuses more than 100 levels.
def deep(n)
  out = Cybertrain::Cast.empty_array
  cur = out
  i = 0
  while i < n
    nxt = Cybertrain::Cast.empty_array
    cur << nxt
    cur = nxt
    i += 1
  end
  out
end

def note(text)
  OUT_LOCK.synchronize { OUT << text }
  nil
end

def raise_json(which)
  if which == 0
    JSON.parse("{")
  else
    JSON.generate(deep(150))
  end
  nil
end

# The framework's shape: the rescue in a plain method the thread's block
# calls.
def std_guard(which)
  raise_json(which)
  "none"
rescue StandardError => e
  "std #{e.class.name}"
end

def exc_guard(which)
  raise_json(which)
  "none"
rescue Exception => e
  "exc #{e.class.name}"
end

Job.handle("parse") { |payload| JSON.parse("{") }
Job.handle("nest") { |payload| JSON.generate(deep(150)) }
Job.register("parse run") { |run| JSON.parse("[1,") }
S.every(10, "parse task") { JSON.parse("{") }
S.every(10, "nest task") { JSON.generate(deep(150)) }

# The row's state and, when its last_error is one of `class_name` (the
# message differs between the runtimes), that name; else the whole error.
def row_text(id, class_name)
  rows = DB.with { |c| c.execute("SELECT state, last_error FROM cybertrain_jobs WHERE id = ?", [id]) }
  error = Cybertrain::Cast.str(rows[0]["last_error"])
  error = class_name if error.start_with?("#{class_name}: ")
  "#{rows[0]["state"]} #{error}"
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

test "a job thread's claim survives a StandardError through its Exception arm" do
  # Not connected yet: the claim raises DB::Error.
  assert_equal false, Job::Worker.claim_safely(1000, 7, 0)
  puts LOG.string.include?("Job thread 7: Cybertrain::DB::Error: not connected")
end

test "a JSON error raised by a job handler is the attempt's error" do
  DB.connect(":memory:", size: 1)
  a = Job.enqueue("parse", "x", run_at: Time.at(1))
  b = Job.enqueue("nest", "x", run_at: Time.at(1))
  c = Job.enqueue("parse run", "{}", run_at: Time.at(1))
  assert_equal true, Job.work_one(1000)
  assert_equal true, Job.work_one(1000)
  assert_equal true, Job.work_one(1000)
  puts row_text(a, "JSON::ParserError")
  puts row_text(b, "JSON::NestingError")
  puts row_text(c, "JSON::ParserError")
end

test "a JSON error raised by a scheduled task is logged and the pass goes on" do
  S.schedule_all(1000)
  puts S.run_due(1000)
  puts S.run_due(1010)
  puts LOG.string.include?("Scheduled task \"parse task\" failed: JSON::ParserError")
  puts LOG.string.include?("Scheduled task \"nest task\" failed: JSON::NestingError")
end

test "rescue StandardError alone, inline in a block" do
  got = ""
  begin
    JSON.parse("{")
  rescue StandardError => e
    got = e.class.name
  end
  puts got
  begin
    JSON.generate(deep(150))
  rescue StandardError => e
    got = e.class.name
  end
  puts got
end

test "JSON errors on plain threads are caught by StandardError and by Exception" do
  t1 = Thread.new do
    note(std_guard(0))
    note(std_guard(1))
  end
  t1.join
  t2 = Thread.new do
    note(exc_guard(0))
    note(exc_guard(1))
  end
  t2.join
  puts OUT.join(" | ")
end

test "JSON errors raised by handlers on real job threads" do
  Dir.mkdir("tmp") unless File.directory?("tmp")
  Dir.mkdir(DIR) unless File.directory?(DIR)
  ["", "-wal", "-shm"].each { |suffix| File.delete("#{PATH}#{suffix}") if File.exist?("#{PATH}#{suffix}") }
  DB.connect(PATH)
  logged = LOG.string.size
  a = Job.enqueue("parse", "x", run_at: Time.at(Time.now.to_i - 1))
  b = Job.enqueue("nest", "x", run_at: Time.at(Time.now.to_i - 1))
  config = Cybertrain::Config.new
  config.job_threads = 2
  config.job_poll_interval = 1
  config.job_heartbeat_interval = 1
  config.job_drain_timeout = 1
  assert Job.start!(config)
  assert(wait_until(5.0) { Job.state_count("queued") == 2 && row_text(a, "-").size > 8 && row_text(b, "-").size > 8 })
  puts row_text(a, "JSON::ParserError")
  puts row_text(b, "JSON::NestingError")
  # Both loops are alive, and run_handler's StandardError arm took the
  # errors: nothing reached the job thread's own rescue.
  puts Job.live_loops
  Job.stop!
  since = LOG.string
  puts since[logged, since.size - logged].include?("Job thread ")
end
Cybertrain::Test.run!
