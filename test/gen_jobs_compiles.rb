require "stringio"
require "cybertrain"
require "cybertrain/mailer"
require "cybertrain/test"
require "cybertrain/generator/job_scan"
require "cybertrain/generator/jobs_emitter"

# Proves the job generator's output compiles and runs: the fixture app's
# job classes and its checked-in gen/jobs.rb, in the order gen/app.rb
# loads them (cybertrain/mailer first: WelcomeJob names its TimeoutError),
# worked through Job.work_one with chosen epoch times against an
# in-memory database. SQLite is FFI, so the snapshot comes from the
# compiled binary (spikes/NOTES.md rule 23).
require_relative "fixtures/gen_app/app/jobs/admin/report_job"
require_relative "fixtures/gen_app/app/jobs/digest_job"
require_relative "fixtures/gen_app/app/jobs/welcome_job"
require_relative "fixtures/gen_app/gen/jobs"

FIXTURE = "test/fixtures/gen_app"
DB = Cybertrain::DB
Job = Cybertrain::Job

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

def fresh_db
  DB.connect(":memory:")
  WELCOME_LOG.pop until WELCOME_LOG.empty?
  nil
end

def job_value(id, column)
  rows = DB.with { |c| c.execute("SELECT #{column} AS v FROM cybertrain_jobs WHERE id = ?", [id]) }
  rows[0]["v"]
end

def job_state(id) = Cybertrain::Cast.str(job_value(id, "state"))
def job_run_at(id) = Cybertrain::Cast.int(job_value(id, "run_at"))
def job_attempts(id) = Cybertrain::Cast.int(job_value(id, "attempts"))

def set_attempts(id, attempts)
  DB.with { |c| c.execute("UPDATE cybertrain_jobs SET attempts = ? WHERE id = ?", Cybertrain::Cast.binds(attempts, id)) }
  nil
end

def exhausted_count
  WELCOME_LOG.count { |line| line.start_with?("exhausted ") }
end

test "the checked-in gen/jobs.rb matches the emitter (fixture stale otherwise)" do
  source = Cybertrain::Gen::JobsEmitter.emit(Cybertrain::Gen::JobScan.scan_dir(FIXTURE + "/app/jobs"))
  Cybertrain::Test.count_assertion
  flunk("fixture stale: gen/jobs.rb") unless File.read(FIXTURE + "/gen/jobs.rb") == source
end

test "perform_later enqueues the class kind with the JSON args and perform runs it" do
  fresh_db
  assert_equal "WelcomeJob", WelcomeJob.job_kind
  assert_equal "Admin::ReportJob", Admin::ReportJob.job_kind
  id = WelcomeJob.perform_later({ "user_id" => 7, "mode" => "ok" })
  assert_equal "WelcomeJob", Cybertrain::Cast.str(job_value(id, "kind"))
  assert_equal "{\"user_id\":7,\"mode\":\"ok\"}", Cybertrain::Cast.str(job_value(id, "payload"))
  assert_equal "queued", job_state(id)
  assert Job.work_one(Time.now.to_i + 1)
  assert_equal "perform 7 ok", WELCOME_LOG.join("|")
  assert_equal "done", job_state(id)
  report = Admin::ReportJob.perform_later
  assert_equal "{}", Cybertrain::Cast.str(job_value(report, "payload"))
  msg = assert_raises("ArgumentError") { Admin::ReportJob.perform_later(["not", "a", "hash"]) }
  assert_equal "Admin::ReportJob.perform_later: args must be a Hash (a JSON object), not Array", msg
end

test "perform_at and perform_in set run_at; perform_now runs synchronously and propagates" do
  fresh_db
  at = WelcomeJob.perform_at(Time.at(5000), { "user_id" => 1 })
  assert_equal 5000, job_run_at(at)
  before = Time.now.to_i
  later = WelcomeJob.perform_in(30, { "user_id" => 2 })
  assert job_run_at(later) >= before + 30
  assert job_run_at(later) <= Time.now.to_i + 30
  refute Job.work_one(4999)
  assert_nil WelcomeJob.perform_now({ "user_id" => 3, "mode" => "now" })
  assert_equal "perform 3 now", WELCOME_LOG.join("|")
  msg = assert_raises("ArgumentError") { WelcomeJob.perform_now({ "user_id" => 4, "mode" => "bad" }) }
  assert_equal "no such user", msg
  msg = assert_raises("TimeoutError") { WelcomeJob.perform_now({ "user_id" => 5, "mode" => "timeout" }) }
  assert_equal "smtp timed out", msg
  # No row was written by perform_now, and no policy ran.
  assert_equal 2, Job.state_count("queued")
  assert_equal 0, exhausted_count
end

test "retry_on requeues with the declared wait and attempts; retries_exhausted runs once after the failed write" do
  fresh_db
  id = WelcomeJob.perform_at(Time.at(1000), { "user_id" => 9, "mode" => "timeout" })
  now = 1000
  4.times do |i|
    assert Job.work_one(now)
    assert_equal "queued", job_state(id)
    assert_equal i + 1, job_attempts(id)
    assert_equal now + 60, job_run_at(id)
    now += 60
  end
  assert_equal 0, exhausted_count
  assert Job.work_one(now)
  assert_equal "failed", job_state(id)
  assert_equal 5, job_attempts(id)
  assert_equal "Cybertrain::Mailer::TimeoutError: smtp timed out", Cybertrain::Cast.str(job_value(id, "last_error"))
  assert_equal 1, exhausted_count
  assert_equal "exhausted smtp timed out", WELCOME_LOG.last
  refute Job.work_one(999_999)
  assert_equal 1, exhausted_count
end

test "retries_exhausted does not run for a stale attempt" do
  fresh_db
  id = WelcomeJob.perform_at(Time.at(1000), { "user_id" => 9, "mode" => "steal" })
  set_attempts(id, 4)
  assert Job.work_one(1000)
  # The 5th attempt's write was fenced off: the thief's claim stands.
  assert_equal "running", job_state(id)
  assert_equal "thief:1:1:abcdef", Cybertrain::Cast.str(job_value(id, "claimed_by"))
  assert_equal 0, exhausted_count
  assert_includes LOG.string, "job #{id} (WelcomeJob) finished after it was reclaimed; outcome discarded"
end

test "discard_on writes discarded without a retry" do
  fresh_db
  id = WelcomeJob.perform_at(Time.at(1000), { "user_id" => 9, "mode" => "bad" })
  assert Job.work_one(1000)
  assert_equal "discarded", job_state(id)
  assert_equal 1, job_attempts(id)
  assert_equal "ArgumentError: no such user", Cybertrain::Cast.str(job_value(id, "last_error"))
  assert_equal 0, exhausted_count
  refute Job.work_one(999_999)
end

test "the first declared policy wins" do
  fresh_db
  # Admin::ReportJob: retry_on StandardError before discard_on ArgumentError.
  id = Admin::ReportJob.perform_at(Time.at(1000), { "fail" => "argument", "name" => "q3" })
  assert Job.work_one(1000)
  assert_equal "queued", job_state(id)
  # Polynomially longer: 1 ** 4 + 2 seconds after the first attempt.
  assert_equal 1003, job_run_at(id)
  assert_equal "ArgumentError: bad report q3", Cybertrain::Cast.str(job_value(id, "last_error"))
end

test "a grandchild enqueues under its own kind and runs its parent's perform and arms after its own" do
  fresh_db
  assert_equal "DigestJob", DigestJob.job_kind
  id = DigestJob.perform_at(Time.at(1000), { "fail" => "argument", "name" => "weekly" })
  assert_equal "DigestJob", Cybertrain::Cast.str(job_value(id, "kind"))
  assert Job.work_one(1000)
  # Admin::ReportJob#perform raised ArgumentError; DigestJob's own KeyError
  # arm did not match, the parent's retry_on StandardError did.
  assert_equal "queued", job_state(id)
  assert_equal 1003, job_run_at(id)
  assert_equal "ArgumentError: bad report weekly", Cybertrain::Cast.str(job_value(id, "last_error"))
  assert_equal 20, Job.recovery_limit("DigestJob")
end

test "limits_concurrency key: refuses a payload without the field and keys the row" do
  fresh_db
  msg = assert_raises("ArgumentError") { WelcomeJob.perform_later({ "mode" => "ok" }) }
  assert_equal "Job.enqueue \"WelcomeJob\": the payload has no \"user_id\" field for limits_concurrency", msg
  id = WelcomeJob.perform_later({ "user_id" => 3 })
  assert_equal "3", Cybertrain::Cast.str(job_value(id, "concurrency_key"))
  assert_equal "", Job.concurrency_key_for("Admin::ReportJob", "{\"user_id\":3}")
end

test "a stale row of Admin::ReportJob at attempt 5 is requeued (max_attempts 20)" do
  fresh_db
  assert_equal 20, Job.recovery_limit("Admin::ReportJob")
  assert_equal 5, Job.recovery_limit("WelcomeJob")
  report = Admin::ReportJob.perform_at(Time.at(1000))
  welcome = WelcomeJob.perform_at(Time.at(1000), { "user_id" => 1 })
  DB.with do |c|
    c.execute("UPDATE cybertrain_jobs SET state = 'running', attempts = 5, claimed_by = 'gone:1:1:aaaaaa', heartbeat_at = 1000")
  end
  assert_equal 1, Job.recover!(5000, 300)
  assert_equal "queued", job_state(report)
  assert_equal "failed", job_state(welcome)
end

Cybertrain::Test.run!
