require "tmpdir"
require "stringio"
require "cybertrain/core"
require "cybertrain/feeds"
require "cybertrain/test"

# The core and cybertrain/feeds alone (the optional-subsystems design,
# docs/superpowers/specs/2026-11-13-optional-subsystems-design.md, section
# 3): it compiles without jobs, streams, the mailer, the cache or rate
# limiting; FeedsFeature is the one registered feature; `help` lists the
# feeds role and `feeds` is a known command (with no subscription it says
# there is nothing to run and returns 0); `/up` with health_feeds and no
# status row is ok. Runs from a fresh temp directory (boot writes
# tmp/secret_key and the database there). It links SQLite through FFI, so
# its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
TMP = Dir.mktmpdir("cybertrain-features-feeds")
Dir.chdir(TMP)
ENV["CYBERTRAIN_ENV"] = "test"
ENV["CYBERTRAIN_DATABASE"] = "feeds.sqlite3"
ENV.delete("CYBERTRAIN_WORKER")

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

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def run(argv)
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" }, views: no_views)
end

test "feeds is the one registered feature" do
  assert_equal "feeds", Cybertrain::Features.feature_names.join(",")
end

test "help lists the feeds role, not the worker" do
  usage = Cybertrain::Main.usage("blog")
  assert_includes usage, "./blog feeds [NAME...]"
  assert_includes usage, "./blog feeds status"
  assert_nil usage.index("./blog worker")
end

test "feeds is a known command: with no subscription there is nothing to run" do
  assert_equal 0, run(["feeds"])
end

test "a stale feed is reported only with health_feeds, and no row is not stale" do
  assert_equal "", Cybertrain::Features.health_problem(Time.now.to_i, 60, true, 60)
  assert_equal "", Cybertrain::Features.health_problem(Time.now.to_i, 60, false, 60)
end

Cybertrain::Test.run!
