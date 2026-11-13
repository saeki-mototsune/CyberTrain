require "tmpdir"
require "stringio"
require "cybertrain/core"
require "cybertrain/test"
require "cybertrain/test/client"

# The core alone (`require "cybertrain/core"`, the optional-subsystems
# design, docs/superpowers/specs/2026-11-13-optional-subsystems-design.md):
# it compiles without jobs, the scheduler, the lease, cron, the jobs page,
# the worker role, Turbo Streams, the feeds, the mailer, the cache or rate
# limiting; an application built on it boots in-process and serves a page
# and `/up` (no worker or feed staleness to report, no stream endpoint);
# `worker`, `jobs` and `feeds` say which require they need instead of
# "Unknown command", and `help` lists none of them; a stream helper in a
# template is an undefined helper. No feature is registered. Runs from a fresh
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

test "no feature is registered, and none runs periodic work" do
  refute Cybertrain::Features.feature_loaded?("jobs")
  refute Cybertrain::Features.feature_loaded?("streams")
  refute Cybertrain::Features.feature_loaded?("feeds")
  assert_equal 0, Cybertrain::Features.feature_count
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

test "the stack has no stream endpoint: its path goes to the router" do
  names = Array.new(0) { "" }
  node = APP.stack
  until node.nil?
    names << node.class.name
    node = node.app
  end
  assert_nil names.join(",").index("Stream")
  assert_equal 404, CLIENT.get("/cybertrain/stream?s=x").status
end

test "a stream helper in a template is an undefined helper" do
  template = Cybertrain::Template::Template.parse("<%= turbo_stream_from \"alerts\" %>", "pages/inline")
  env = { "__template_dir" => [nil, 0, 0.0, "", true][3] }
  env["__template_dir"] = "pages"
  msg = ""
  begin
    Cybertrain::Template::Interpreter.new(Cybertrain::Template::Helpers.new(nil)).render(template, env)
  rescue StandardError => e
    msg = e.message
  end
  assert_equal "pages/inline:1: undefined helper 'turbo_stream_from'", msg
end

test "worker says which require it needs and exits 1" do
  assert_equal 1, run(["worker"])
end

test "jobs says which require it needs and exits 1" do
  assert_equal 1, run(["jobs", "list"])
end

test "feeds says which require it needs and exits 1" do
  assert_equal 1, run(["feeds"])
  assert_equal 1, run(["feeds", "status"])
end

test "help lists neither worker, jobs nor feeds" do
  assert_equal 0, run(["help"])
  usage = Cybertrain::Main.usage("blog")
  assert_nil usage.index("./blog worker")
  assert_nil usage.index("./blog jobs")
  assert_nil usage.index("./blog feeds")
  assert_includes usage, "./blog migrate"
end

test "an unknown word is still unknown" do
  assert_equal 1, run(["nosuch"])
end

Cybertrain::Test.run!
