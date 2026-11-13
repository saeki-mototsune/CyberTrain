require "tmpdir"
require "stringio"
require "cybertrain"
require "cybertrain/test"

# The jobs feature as the core reaches it (cybertrain/jobs.rb's JobsFeature,
# through Cybertrain::Features; docs/superpowers/specs/
# 2026-11-13-optional-subsystems-design.md, section 4), with the whole
# framework required: the features register in the order cybertrain.rb
# requires them (help and `/up` follow it); boot's feature check is
# Scheduler.job_kinds_error; the server role's TERM trap
# (Features.request_stop_features) stops the job threads claiming; and with
# jobs loaded the cache's prune is the scheduler's task, so a write does
# not prune. Each would otherwise fall back silently to Feature's no-op if
# an override were misspelled. It links SQLite through FFI, so its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23).

DB = Cybertrain::DB
Job = Cybertrain::Job
S = Cybertrain::Scheduler
Cache = Cybertrain::Cache
Features = Cybertrain::Features

TMP = Dir.mktmpdir("cybertrain-features-jobs")
PATH = File.join(TMP, "jobs.sqlite3")

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit { rm_tree(TMP) }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

Job.handle("report") { |payload| nil }

DB.connect(PATH)

def cache_rows
  rows = DB.with { |c| c.execute("SELECT COUNT(*) AS n FROM cybertrain_cache") }
  Cybertrain::Cast.int(rows[0]["n"])
end

test "require \"cybertrain\" registers the features in a fixed order" do
  # jobs before feeds: `help` lists worker before feeds, `/up` checks the
  # worker before the feeds, and the server role stops Job and Scheduler
  # before Background (cybertrain.rb's order).
  assert_equal "jobs,feeds,streams,cache,rate_limit", Features.feature_names.join(",")
end

test "with jobs, the scheduler owns the cache prune and a write does not prune" do
  assert Features.periodic_scheduler?
  assert S.task_index(Cache::PRUNE_TASK) >= 0
  travel_to(Time.at(1000))
  assert Cache.write("old", "o", expires_in: 1)
  assert Cache.write("keep", "k")
  # Far past Config#cache_prune_interval: still no prune from a write.
  travel_to(Time.at(1000 + 10 * Cache.prune_interval))
  assert Cache.write("new", "n")
  assert_equal 1, Cache.increment("hits")
  assert_equal 4, cache_rows
  # The scheduler's task prunes.
  assert_equal 1, Cache.prune(Cache.now)
  assert_equal 3, cache_rows
end

test "the server role's stop request stops the job threads" do
  config = Cybertrain::Config.new
  config.job_threads = 1
  config.job_poll_interval = 1
  config.job_drain_timeout = 1
  assert Job.start!(config)
  assert Job.running?
  Features.request_stop_features
  refute Job.running?
  Features.stop_features
  assert_equal 0, Job.live_loops
  refute S.running?
end

test "boot refuses a cron task whose job kind is not registered" do
  config = Cybertrain::Config.new
  assert_equal "", Features.boot_problem(config)
  S.cron("0 9 * * *", "nightly", job: "unknown")
  message = "Scheduler.cron \"nightly\": job \"unknown\" is not a registered job kind (registered: cybertrain mail, report)"
  assert_equal message, S.job_kinds_error
  # Application#validate_boot fails the boot with this answer (the
  # mailer's kind is registered by cybertrain/mailer/later).
  assert_equal message, Features.boot_problem(config)
end

Cybertrain::Test.run!
