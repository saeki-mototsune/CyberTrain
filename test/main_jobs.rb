require "tmpdir"
require "stringio"
require "cybertrain/test"
require "cybertrain"

# `./<app> jobs ...` (Cybertrain::Main.run -> Job::CLI.run): list, retry
# (one row and --all), discard, delete and prune on a database file in a
# fresh temp directory, their printed output and exit statuses, and the
# usage errors. The rows are made through Job.enqueue and then put into the
# state each case needs with fixed times, so the snapshot is stable. It
# links SQLite through FFI, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
TMP = Dir.mktmpdir("cybertrain-main-jobs")
Dir.chdir(TMP)
ENV["CYBERTRAIN_ENV"] = "test"
ENV["CYBERTRAIN_DATABASE"] = "jobs.sqlite3"

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

Cybertrain::Job.handle("Mailer") { |payload| nil }
Cybertrain::Job.register("Welcome", concurrency: 1, concurrency_key: "user_id") { |payload| nil }

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def resolver = ->(name, args) { "/" }

def run(argv)
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: resolver, views: no_views)
end

# Runs block with the database connected (Main disconnects after each command).
def with_db
  Cybertrain::DB.connect("jobs.sqlite3", size: 1)
  yield
ensure
  Cybertrain::DB.disconnect
end

# A row of kind in state with the given error, run_at 1_700_000_000 + id
# and updated_at `updated`.
def make_job(kind, payload, state, error, updated)
  id = 0
  with_db do
    id = Cybertrain::Job.enqueue(kind, payload)
    Cybertrain::DB.with do |c|
      c.execute("UPDATE cybertrain_jobs SET state = ?, last_error = ?, attempts = 3, run_at = ?, updated_at = ? WHERE id = ?",
                Cybertrain::Cast.binds(state, error, 1_700_000_000 + id, updated, id))
    end
  end
  id
end

def job_field(id, column)
  out = ""
  with_db do
    rows = Cybertrain::DB.with { |c| c.execute("SELECT #{column} AS v FROM cybertrain_jobs WHERE id = ?", [id]) }
    out = rows.empty? ? "(gone)" : Cybertrain::Cast.str(rows[0]["v"])
  end
  out
end

test "jobs is a built-in word, in the usage" do
  assert Cybertrain::Main::BUILTIN_WORDS.include?("jobs")
  assert_includes Cybertrain::Main.usage("blog"), "  ./blog jobs COMMAND      list [STATE] | retry ID | retry --all | discard ID | delete ID\n"
  assert_equal "Main.command \"jobs\": jobs is a built-in command",
               assert_raises("ArgumentError") { Cybertrain::Main.command("jobs", "x") { |argv| 0 } }
end

test "jobs list prints a table of failed rows by default, or of the state named" do
  long = "Net::ReadTimeout: " + ("x" * 80) + "\nbacktrace line"
  make_job("Mailer", "{\"to\":\"a@b.c\"}", "failed", "RuntimeError: boom", 10)
  make_job("Welcome", "{\"user_id\":3}", "failed", long, 10)
  make_job("Mailer", "{}", "discarded", "ArgumentError: bad address", 10)
  assert_equal 0, run(["jobs", "list"])
  assert_equal 0, run(["jobs", "list", "discarded"])
  assert_equal 0, run(["jobs", "list", "running"])
  assert_equal 1, run(["jobs", "list", "lost"])
  assert_equal 1, run(["jobs", "list", "failed", "extra"])
end

test "jobs retry ID requeues a failed row with its key; retry --all every failed row" do
  assert_equal 0, run(["jobs", "retry", "2"])
  assert_equal "queued", job_field(2, "state")
  assert_equal "0", job_field(2, "attempts")
  assert_equal "3", job_field(2, "concurrency_key")
  assert_equal 1, run(["jobs", "retry", "2"])
  assert_equal 1, run(["jobs", "retry", "99"])
  assert_equal 1, run(["jobs", "retry", "x"])
  assert_equal 1, run(["jobs", "retry"])
  make_job("Mailer", "{}", "failed", "e", 10)
  assert_equal 0, run(["jobs", "retry", "--all"])
  assert_equal "queued", job_field(1, "state")
  assert_equal "queued", job_field(4, "state")
  assert_equal "discarded", job_field(3, "state")
  assert_equal 0, run(["jobs", "retry", "--all"])
end

test "jobs discard and delete act only on failed or discarded rows" do
  failed = make_job("Mailer", "{}", "failed", "e", 10)
  assert_equal 0, run(["jobs", "discard", failed.to_s])
  assert_equal "discarded", job_field(failed, "state")
  assert_equal 1, run(["jobs", "discard", "1"])
  assert_equal "queued", job_field(1, "state")
  assert_equal 1, run(["jobs", "delete", "1"])
  assert_equal 0, run(["jobs", "delete", failed.to_s])
  assert_equal "(gone)", job_field(failed, "state")
  assert_equal 1, run(["jobs", "delete"])
end

test "jobs discard on a discarded row keeps its updated_at, so pruning is not put off" do
  old = make_job("Mailer", "{}", "discarded", "e", 10)
  assert_equal 0, run(["jobs", "discard", old.to_s])
  assert_equal "discarded", job_field(old, "state")
  assert_equal "10", job_field(old, "updated_at")
end

test "jobs prune deletes failed and discarded rows older than DAYS (7 by default)" do
  recent = make_job("Mailer", "{}", "failed", "e", Time.now.to_i - 3600)
  assert_equal 0, run(["jobs", "prune"])
  assert_equal "(gone)", job_field(3, "state")
  assert_equal "failed", job_field(recent, "state")
  assert_equal 0, run(["jobs", "prune", "--before", "0"])
  assert_equal "(gone)", job_field(recent, "state")
  assert_equal "queued", job_field(1, "state")
  assert_equal 1, run(["jobs", "prune", "--before"])
  assert_equal 1, run(["jobs", "prune", "--before", "-1"])
  assert_equal 1, run(["jobs", "prune", "7"])
end

test "jobs with no or an unknown subcommand prints the usage" do
  assert_equal 1, run(["jobs"])
  assert_equal 1, run(["jobs", "frobnicate"])
end

test "jobs list prints at most the newest 1000 rows and says how many there are" do
  assert_equal 1000, Cybertrain::Job::CLI::LIST_LIMIT
  make_job("Mailer", "{}", "done", "", 10)
  make_job("Mailer", "{}", "done", "", 10)
  newest = make_job("Mailer", "{}", "done", "", 10)
  # A limit of 2 stands for 1000: the two newest rows, then the count.
  with_db do
    assert_equal 0, Cybertrain::Job::CLI.list("done", 2)
    assert_equal 0, Cybertrain::Job::CLI.list("done", 3)
  end
  assert_equal "done", job_field(newest, "state")
end

Cybertrain::Test.run!
