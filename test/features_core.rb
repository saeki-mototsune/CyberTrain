require "tmpdir"
require "stringio"
require "cybertrain/core"
require "cybertrain/test"
require "cybertrain/test/client"

# The core alone (`require "cybertrain/core"`, the optional-subsystems
# design, docs/superpowers/specs/2026-11-13-optional-subsystems-design.md):
# it compiles without jobs, the scheduler, the lease, cron, the jobs page
# or the worker role; an application built on it boots in-process and
# serves a page and `/up` (no worker staleness to report); `worker` and
# `jobs` say which require they need instead of "Unknown command", and
# `help` lists neither. No registered feature is jobs. Runs from a fresh
# temp directory (boot may write tmp/secret_key there). It links SQLite
# through FFI, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
TMP = Dir.mktmpdir("cybertrain-features-core")
Dir.chdir(TMP)
Dir.mkdir("public")

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

class PagesController < Cybertrain::Controller
  def index
    render plain: "home"
  end
end

def build_config
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = ":memory:"
  c.pool_size = 1
  c.public_root = "public"
  c.secret_key_base = "features-core-secret"
  c.log_level = :info
  c
end

ROUTER = Cybertrain::Router.new
ROUTER.get("/", "root") { |ctx| PagesController.new(ctx).process(:index) { |c| c.index } }

APP = Cybertrain::Application.new(router: ROUTER, url_resolver: ->(name, args, options) { "/" }, config: build_config)
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def run(argv)
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" }, views: no_views)
end

test "no registered feature is jobs, and none runs periodic work" do
  refute Cybertrain::Features.feature_loaded?("jobs")
  assert_nil Cybertrain::Features.feature_names.join(",").index("jobs")
  refute Cybertrain::Features.periodic_scheduler?
end

test "an application on the core boots and serves a page" do
  res = CLIENT.get("/")
  assert_equal 200, res.status
  assert_equal "home", res.body
end

test "/up answers ok: with no jobs there is no worker to be stale" do
  res = CLIENT.get("/up")
  assert_equal 200, res.status
  assert_equal "ok", res.body
end

test "worker says which require it needs and exits 1" do
  assert_equal 1, run(["worker"])
end

test "jobs says which require it needs and exits 1" do
  assert_equal 1, run(["jobs", "list"])
end

test "help lists neither worker nor jobs" do
  assert_equal 0, run(["help"])
  usage = Cybertrain::Main.usage("blog")
  assert_nil usage.index("./blog worker")
  assert_nil usage.index("./blog jobs")
  assert_includes usage, "./blog migrate"
end

test "an unknown word is still unknown" do
  assert_equal 1, run(["nosuch"])
end

Cybertrain::Test.run!
