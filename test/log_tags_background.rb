require "stringio"
require "cybertrain/job"
require "cybertrain/scheduler"
require "cybertrain/websocket"
require "cybertrain/context"
require "cybertrain/middleware/request_id"
require "cybertrain/test"
require "cybertrain/test/jobs"
require "cybertrain/test/websocket_receiver"
require_relative "support/log_capture"

# The log tags of work that runs outside a request (spec section 12.3):
# a job's lines carry `[<kind> <id>]`, and the id of the request that
# enqueued it (recorded in cybertrain_jobs.request_id) when log_tags
# shows request ids; a scheduled task's carry `[schedule:<name>]`; a feed
# thread's `[feed:<name>]`. A worker thread runs one job after another,
# so each job's Scope is gone before the next starts. The jobs are hand
# written in the shape gen/jobs.rb gives an app/jobs class. SQLite is FFI,
# so the snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Job = Cybertrain::Job
WS = Cybertrain::WebSocket
Scope = Cybertrain::Logger::Scope

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

RID = "3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c"

# What the handlers saw of their thread's Scope (constants: NOTES rule 64).
SEEN = Array.new(0) { "" }
TICKS = Array.new(0) { "" }

# The Scope a request's RequestId installs (RequestId.scope_for's shape):
# the id is the first tag.
def request_scope(rid)
  verb = "POST"
  path = "/users"
  where = ""
  tags = Array.new(0) { "" }
  tags << rid
  context = { "" => "" }
  context.delete("")
  Scope.new(rid, verb, path, where, tags, 0, context)
end

# One line describing this thread's Scope, as a handler sees it.
def scope_text
  s = Cybertrain::Logger.current_scope
  keys = s.scope_context.keys.sort
  pairs = Array.new(0) { "" }
  keys.each { |k| pairs << "#{k}=#{s.scope_context[k]}" }
  "id=#{s.scope_request_id} tags=#{s.scope_tags.join("|")} at=#{s.scope_id_tag} where=#{s.scope_where} " \
    "context=#{pairs.join(",")}"
end

class WelcomeJob < Cybertrain::Job::Base
  def self.job_kind
    "WelcomeJob"
  end

  def self.perform_later(args = {})
    Cybertrain::Job.enqueue(job_kind, JSON.generate(args))
  end

  def self.run_job(run)
    new.perform(run.run_args)
    nil
  end

  def perform(args)
    Cybertrain.logger.info("welcome #{Cybertrain::Cast.int(args["user_id"])}")
    SEEN << scope_text
    nil
  end
end

class BoomJob < Cybertrain::Job::Base
  def self.job_kind
    "BoomJob"
  end

  def self.perform_later(args = {})
    Cybertrain::Job.enqueue(job_kind, JSON.generate(args))
  end

  def self.run_job(run)
    new.perform(run.run_args)
    nil
  end

  def perform(args)
    SEEN << scope_text
    raise "boom"
  end
end

# The ids of the jobs ParentJob enqueued.
CHILDREN = Array.new(0) { 0 }

# A job that enqueues another, as a job's handler would.
class ParentJob < Cybertrain::Job::Base
  def self.job_kind
    "ParentJob"
  end

  def self.perform_later(args = {})
    Cybertrain::Job.enqueue(job_kind, JSON.generate(args))
  end

  def self.run_job(run)
    new.perform(run.run_args)
    nil
  end

  def perform(args)
    CHILDREN << WelcomeJob.perform_later("user_id" => 5)
    nil
  end
end

Job.register("WelcomeJob") { |run| WelcomeJob.run_job(run) }
Job.register("BoomJob") { |run| BoomJob.run_job(run) }
Job.register("ParentJob") { |run| ParentJob.run_job(run) }
Job.handle("welcome_mail") { |payload| Cybertrain.logger.info("mail #{payload}") }

Cybertrain::Scheduler.every(60, "nightly") { Cybertrain.logger.info("pruned") }
Cybertrain::Scheduler.every(60, "broken") { raise "no disk" }
Cybertrain::Scheduler.every(60, "enqueuer") { Job.enqueue("welcome_mail", "from a task") }

# The table as phase 5a created it (9866af2's Job::Store::TABLE_SQL).
OLD_TABLE_SQL = "CREATE TABLE IF NOT EXISTS cybertrain_jobs (" \
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " \
                "kind TEXT NOT NULL, " \
                "payload TEXT NOT NULL DEFAULT '', " \
                "run_at INTEGER NOT NULL, " \
                "attempts INTEGER NOT NULL DEFAULT 0, " \
                "last_error TEXT NOT NULL DEFAULT '', " \
                "state TEXT NOT NULL DEFAULT 'queued', " \
                "created_at INTEGER NOT NULL, " \
                "updated_at INTEGER NOT NULL, " \
                "claimed_by TEXT, " \
                "heartbeat_at INTEGER, " \
                "concurrency_key TEXT NOT NULL DEFAULT ''); " \
                "CREATE INDEX IF NOT EXISTS index_cybertrain_jobs_on_state_and_run_at " \
                "ON cybertrain_jobs (state, run_at);"

NOON = Time.utc(2026, 11, 11, 12)

def fresh_db
  DB.connect(":memory:")
  SEEN.pop until SEEN.empty?
  nil
end

def request_id_of(id)
  rows = DB.with { |c| c.execute("SELECT request_id FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["request_id"])
end

def job_columns
  rows = DB.with { |c| c.execute("PRAGMA table_info('cybertrain_jobs')") }
  names = Array.new(0) { "" }
  rows.each { |r| names << Cybertrain::Cast.str(r["name"]) }
  names.join(",")
end

# Runs the block with Config#log_tags set to `tags`, restored after it.
def with_log_tags(tags)
  saved = Cybertrain.config.log_tags
  Cybertrain.config.log_tags = tags
  _value = yield
  nil
ensure
  Cybertrain.config.log_tags = saved
end

def no_scope?
  Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

test "a job enqueued in a request records its id, and the job's lines carry both tags" do
  fresh_db
  travel_to(NOON) do
    id = 0
    with_scope(request_scope(RID)) { id = WelcomeJob.perform_later("user_id" => 1) }
    assert_equal RID, request_id_of(id)
    log = capture_log { perform_enqueued_jobs }
    assert_includes log, "2026-11-11T12:00:00.000Z INFO [WelcomeJob #{id}] [#{RID}] welcome 1\n"
    assert_includes log, "2026-11-11T12:00:00.000Z INFO [WelcomeJob #{id}] [#{RID}] job #{id} (WelcomeJob) done\n"
    assert_equal "id=#{RID} tags=WelcomeJob #{id}|#{RID} at=1 where=WelcomeJob context=job.attempt=1,job.id=#{id},job.max_attempts=5", SEEN[0]
  end
  assert no_scope?
end

test "a failing job, then a job enqueued outside a request" do
  fresh_db
  travel_to(NOON) do
    failing = 0
    with_scope(request_scope(RID)) { failing = BoomJob.perform_later }
    quiet = WelcomeJob.perform_later("user_id" => 2)
    log = capture_log { perform_enqueued_jobs }
    assert_includes log, "ERROR [BoomJob #{failing}] [#{RID}] job #{failing} (BoomJob) attempt 1 of 5 failed: RuntimeError: boom; retrying in "
    assert_includes log, "INFO [WelcomeJob #{quiet}] welcome 2\n"
    assert_includes log, "INFO [WelcomeJob #{quiet}] job #{quiet} (WelcomeJob) done\n"
    assert_equal "", request_id_of(quiet)
  end
  assert no_scope?
end

test "two jobs on one reused thread: the second starts from its own Scope, nothing of the first" do
  fresh_db
  failing = 0
  with_scope(request_scope(RID)) { failing = BoomJob.perform_later }
  quiet = WelcomeJob.perform_later("user_id" => 3)
  after = Array.new(0) { "" }
  worker = Thread.new do
    Job.work_one(Time.now.to_i + 1)
    Job.work_one(Time.now.to_i + 1)
    after << scope_text
  end
  worker.join
  assert_equal 2, SEEN.size
  assert_equal "id=#{RID} tags=BoomJob #{failing}|#{RID} at=1 where=BoomJob context=job.attempt=1,job.id=#{failing},job.max_attempts=5", SEEN[0]
  assert_equal "id= tags=WelcomeJob #{quiet} at=-1 where=WelcomeJob context=job.attempt=1,job.id=#{quiet},job.max_attempts=5", SEEN[1]
  assert_equal "id= tags= at=-1 where= context=", after[0]
  assert no_scope?
end

test "a job enqueued by a job records the request id its parent carries" do
  fresh_db
  CHILDREN.pop until CHILDREN.empty?
  travel_to(NOON) do
    parent = 0
    with_scope(request_scope(RID)) { parent = ParentJob.perform_later }
    log = capture_log { perform_enqueued_jobs }
    assert_equal 1, CHILDREN.size
    child = CHILDREN[0]
    assert_equal RID, request_id_of(parent)
    assert_equal RID, request_id_of(child)
    assert_includes log, "2026-11-11T12:00:00.000Z INFO [WelcomeJob #{child}] [#{RID}] welcome 5\n"
  end
  assert no_scope?
end

# An action's work in a request: enqueues a WelcomeJob and answers its id.
class EnqueueInRequest < Cybertrain::Middleware
  def call(ctx)
    id = WelcomeJob.perform_later("user_id" => 6)
    ctx.response.body = id.to_s
    nil
  end
end

test "a job enqueued in a request through RequestId records the response's X-Request-Id" do
  fresh_db
  travel_to(NOON) do
    request = Cybertrain::Request.new("POST", "/users", { "host" => "www.example.com" }, "", "127.0.0.1")
    ctx = Cybertrain::Context.new(request)
    Cybertrain::RequestId.new(EnqueueInRequest.new(nil), [:request_id]).call(ctx)
    rid = ctx.response.header("X-Request-Id").to_s
    id = ctx.response.body.to_i
    assert LogCapture.uuid?(rid), rid
    assert_equal rid, request_id_of(id)
    log = capture_log { perform_enqueued_jobs }
    assert_includes log, "2026-11-11T12:00:00.000Z INFO [WelcomeJob #{id}] [#{rid}] welcome 6\n"
  end
  assert no_scope?
end

test "a block job's lines carry its kind and id" do
  fresh_db
  travel_to(NOON) do
    id = Job.enqueue("welcome_mail", "hi")
    log = capture_log { perform_enqueued_jobs }
    assert_includes log, "2026-11-11T12:00:00.000Z INFO [welcome_mail #{id}] mail hi\n"
  end
end

test "an older cybertrain_jobs gets request_id on first use" do
  fresh_db
  DB.with do |c|
    c.exec_script(OLD_TABLE_SQL)
    c.execute("INSERT INTO cybertrain_jobs (kind, payload, run_at, created_at, updated_at) VALUES ('welcome_mail', 'old', 1000, 1000, 1000)")
  end
  refute job_columns.include?("request_id")
  Job.ensure_installed
  assert_equal "id,kind,payload,run_at,attempts,last_error,state,created_at,updated_at,claimed_by,heartbeat_at," \
               "concurrency_key,request_id", job_columns
  assert_equal "", request_id_of(1)
  log = capture_log { assert Job.work_one(2000) }
  assert_includes log, "INFO [welcome_mail 1] mail old\n"
end

test "log_tags without :request_id leaves the job's request tag off" do
  fresh_db
  with_log_tags([]) do
    travel_to(NOON) do
      id = 0
      with_scope(request_scope(RID)) { id = WelcomeJob.perform_later("user_id" => 1) }
      assert_equal RID, request_id_of(id)
      log = capture_log { perform_enqueued_jobs }
      assert_includes log, "2026-11-11T12:00:00.000Z INFO [WelcomeJob #{id}] welcome 1\n"
      assert_equal "id=#{RID} tags=WelcomeJob #{id} at=-1 where=WelcomeJob context=job.attempt=1,job.id=#{id},job.max_attempts=5", SEEN[0]
    end
  end
end

test "a JSON job line names the request id apart from the job's tag" do
  fresh_db
  Cybertrain::Logger.json_lines = true
  Cybertrain::Test.after_this_case(-> { Cybertrain::Logger.json_lines = false })
  travel_to(NOON) do
    id = 0
    with_scope(request_scope(RID)) { id = WelcomeJob.perform_later("user_id" => 4) }
    log = capture_log { perform_enqueued_jobs }
    assert_includes log, "{\"time\":\"2026-11-11T12:00:00.000Z\",\"level\":\"INFO\",\"request_id\":\"#{RID}\"," \
                         "\"tags\":[\"WelcomeJob #{id}\"],\"message\":\"welcome 4\"}\n"
  end
end

def task_named(name)
  Cybertrain::Scheduler::TASKS[Cybertrain::Scheduler.task_index(name)]
end

test "a scheduled task's lines carry [schedule:<name>]" do
  log = ""
  travel_to(NOON) do
    log = capture_log do
      assert Cybertrain::Scheduler.run_task(task_named("nightly"))
      refute Cybertrain::Scheduler.run_task(task_named("broken"))
    end
  end
  assert_includes log, "2026-11-11T12:00:00.000Z INFO [schedule:nightly] pruned\n"
  assert_includes log, "ERROR [schedule:broken] Scheduled task \"broken\" failed: RuntimeError: no disk\n"
  assert no_scope?
end

test "a scheduled task inside a request's Scope puts that Scope back" do
  scope = request_scope(RID)
  with_scope(scope) do
    assert Cybertrain::Scheduler.run_task(task_named("nightly"))
    assert Cybertrain::Logger.current_scope.equal?(scope)
  end
end

test "a job a scheduled task enqueues records no request id" do
  fresh_db
  with_scope(request_scope(RID)) do
    assert Cybertrain::Scheduler.run_task(task_named("enqueuer"))
  end
  assert_equal "", request_id_of(1)
end

def subscribe_prices(url)
  WS.subscribe("prices", url, allow_private: true)
    .on_message do |conn, msg|
      Cybertrain.logger.info("tick #{msg}")
      TICKS << msg
    end
end

def await_ticks(count, wait)
  ends_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) < ends_at
    return true if TICKS.size >= count

    sleep(0.05)
  end
  TICKS.size >= count
end

# The callable that stops the feeds (made in a method: spikes/NOTES.md
# rule 82), registered with Test.after_this_case before they start, so a
# failed assertion leaves no feed thread running into the next case.
# WS.stop! does nothing once they are stopped.
def feeds_stopper
  lambda do
    WS.stop!
    nil
  end
end

test "a feed thread's lines carry [feed:<name>]" do
  Cybertrain::Test.after_this_case(feeds_stopper)
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 10.0, read_timeout: 5.0)
  rx.ws_script([Cybertrain::Test::WsStep.new("accept", ""), Cybertrain::Test::WsStep.new("send_text", "1"),
                Cybertrain::Test::WsStep.new("echo_until_close", "")])
  rx.start
  subscribe_prices(rx.url("/prices"))
  log = capture_log do
    assert WS.start!(Cybertrain::Config.new)
    assert await_ticks(1, 5.0)
    WS.stop!
  end
  rx.stop
  assert_includes log, " INFO [feed:prices] tick 1\n"
  assert_includes log, " INFO [feed:prices] WebSocket \"prices\" connected to 127.0.0.1:"
  # The thread that started the feeds keeps its own Scope.
  assert no_scope?
end

Cybertrain::Test.run!
