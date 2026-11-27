require "stringio"
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/client"

# A handler, an expectation or a retry policy that names Cybertrain::DB::Error
# keeps catching the constraint failures, which are now its subclasses
# (UniqueViolation, ForeignKeyViolation): rescue_from and assert_raises compare
# classes by name, a job's retry_on is a literal `rescue` arm. SQLite is FFI,
# so the snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Job = Cybertrain::Job

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

SCHEMA = "CREATE TABLE items (id INTEGER PRIMARY KEY, slug TEXT NOT NULL); " \
         "CREATE UNIQUE INDEX index_items_on_slug ON items (slug); " \
         "CREATE TABLE notes (id INTEGER PRIMARY KEY, item_id INTEGER, " \
         "FOREIGN KEY(item_id) REFERENCES items(id));"

def fresh_db
  DB.connect(":memory:")
  DB.with { |c| c.exec_script(SCHEMA) }
  nil
end

class DuplicatesController < Cybertrain::Controller
  rescue_from(Cybertrain::DB::Error) { |c, e| c.render plain: "handled: #{e.class.name}", status: 422 }

  def create
    DB.with do |c|
      c.execute("INSERT INTO items (slug) VALUES (?)", ["a"])
      c.execute("INSERT INTO items (slug) VALUES (?)", ["a"])
    end
    render plain: "created"
  end

  def orphan
    DB.with { |c| c.execute("INSERT INTO notes (item_id) VALUES (?)", [99]) }
    render plain: "created"
  end
end

def run_action(action)
  headers = { "host" => "example.test" }
  ctx = Cybertrain::Context.new(Cybertrain::Request.new("GET", "/items", headers, ""))
  c = DuplicatesController.new(ctx)
  case action
  when :create then c.process(:create) { |x| x.create }
  when :orphan then c.process(:orphan) { |x| x.orphan }
  else raise ArgumentError, "no action #{action}"
  end
  c
end

# What gen/jobs.rb has for `retry_on Cybertrain::DB::Error, wait: 60, attempts: 3`.
class OrphanNoteJob < Cybertrain::Job::Base
  def self.job_kind
    "OrphanNoteJob"
  end

  def self.perform_at(time, args = {})
    Cybertrain::Job.enqueue(job_kind, JSON.generate(args), run_at: time)
  end

  def perform(args)
    DB.with { |c| c.execute("INSERT INTO notes (item_id) VALUES (?)", [99]) }
    nil
  end

  def self.run_job(run)
    job = new
    begin
      job.perform(run.run_args)
    rescue ::Cybertrain::DB::Error => e
      if Cybertrain::Job.retry_later(run, e, 60, false, 3) == Cybertrain::Job::OUTCOME_FAILED
        job.retries_exhausted(e)
      end
    end
    nil
  end
end

Cybertrain::Job.register("OrphanNoteJob", concurrency: 0, concurrency_key: "", max_attempts: 0) { |run| OrphanNoteJob.run_job(run) }

test "rescue_from Cybertrain::DB::Error handles a unique violation" do
  fresh_db
  c = run_action(:create)
  assert_equal 422, c.response.status
  assert_equal "handled: Cybertrain::DB::UniqueViolation", c.response.body
end

test "rescue_from Cybertrain::DB::Error handles a foreign key violation" do
  fresh_db
  c = run_action(:orphan)
  assert_equal 422, c.response.status
  assert_equal "handled: Cybertrain::DB::ForeignKeyViolation", c.response.body
end

test "assert_raises(Cybertrain::DB::Error) accepts a unique violation" do
  fresh_db
  DB.with { |c| c.execute("INSERT INTO items (slug) VALUES (?)", ["a"]) }
  message = assert_raises(Cybertrain::DB::Error) do
    DB.with { |c| c.execute("INSERT INTO items (slug) VALUES (?)", ["a"]) }
  end
  assert_includes message, "UNIQUE constraint failed: items.slug"
end

test "assert_raises with a name accepts the subclasses of DB::Error and names them" do
  fresh_db
  assert_raises("Cybertrain::DB::Error") { DB.with { |c| c.execute("INSERT INTO notes (item_id) VALUES (?)", [99]) } }
  assert_raises("DB::Error") { DB.with { |c| c.execute("INSERT INTO notes (item_id) VALUES (?)", [99]) } }
  assert_raises("ForeignKeyViolation") { DB.with { |c| c.execute("INSERT INTO notes (item_id) VALUES (?)", [99]) } }
  assert_raises(Cybertrain::DB::ForeignKeyViolation) { DB.with { |c| c.execute("INSERT INTO notes (item_id) VALUES (?)", [99]) } }
  assert_raises("") { DB.with { |c| c.execute("INSERT INTO notes (item_id) VALUES (?)", [99]) } }
end

test "a job with retry_on Cybertrain::DB::Error is requeued on a foreign key violation" do
  fresh_db
  id = OrphanNoteJob.perform_at(Time.at(1000), {})
  assert Job.work_one(1000)
  rows = DB.with { |c| c.execute("SELECT state, attempts, run_at FROM cybertrain_jobs WHERE id = ?", [id]) }
  assert_equal "queued", Cybertrain::Cast.str(rows[0]["state"])
  assert_equal 1, Cybertrain::Cast.int(rows[0]["attempts"])
  assert_equal 1060, Cybertrain::Cast.int(rows[0]["run_at"])
  last = DB.with { |c| c.execute("SELECT last_error FROM cybertrain_jobs WHERE id = ?", [id]) }
  assert_includes Cybertrain::Cast.str(last[0]["last_error"]), "FOREIGN KEY constraint failed"
end

Cybertrain::Test.run!
