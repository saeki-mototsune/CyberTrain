require "tmpdir"
require "stringio"
require "cybertrain/core"
require "cybertrain/feeds"
require "cybertrain/test"
require "cybertrain/test/client"
require "cybertrain/websocket"

# The core and cybertrain/feeds alone (the optional-subsystems design,
# docs/superpowers/specs/2026-11-13-optional-subsystems-design.md, section
# 3): it compiles without jobs, streams, the mailer, the cache or rate
# limiting; FeedsFeature is the one registered feature; `help` lists the
# feeds role and `feeds` is a known command (with no subscription it says
# there is nothing to run and returns 0); `/up` with health_feeds is ok
# with no status row, answers 503 "feed stale" for a stale row of a
# subscribed feed, and is ok with one WARN when the status table cannot be
# read (no rows and an unreadable table are both "not stale", told apart by
# the WARN). cybertrain/websocket, which loads feeds itself, makes the
# subscription. Runs from a fresh temp directory (boot writes
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

def build_config
  c = Cybertrain::Config.new
  c.env = "test"
  c.database_path = "feeds.sqlite3"
  c.pool_size = 1
  c.public_root = "."
  c.secret_key_base = "features-feeds-secret"
  c.health_feeds = true
  c.health_feed_stale = 60
  c
end

APP = Cybertrain::Application.new(router: Cybertrain::Router.new, url_resolver: ->(name, args, options) { "/" },
                                  config: build_config)
APP.boot
CLIENT = Cybertrain::Test::Client.new(APP)

def up_text
  res = CLIENT.get("/up")
  "#{res.status} #{res.body}"
end

test "/up with health_feeds: no status row is not stale" do
  assert_equal "200 ok", up_text
  assert_nil LOG.string.index("cannot be read")
end

test "/up with health_feeds: a stale row of a subscribed feed is 503 feed stale" do
  Cybertrain::WebSocket.subscribe("trades", "ws://127.0.0.1:1/", allow_private: true).on_message { |conn, text| nil }
  now = Time.now.to_i
  Cybertrain::WebSocket::FeedTable.upsert_feed("trades", "elsewhere:1", true, now - 600, now - 600, 0, now - 600)
  assert_equal "503 feed stale", up_text
  # A row no subscription of this binary has is not counted.
  Cybertrain::DB.with { |c| c.execute("UPDATE cybertrain_feeds SET name = 'renamed'") }
  assert_equal "200 ok", up_text
end

test "/up with health_feeds: an unreadable status table is not stale, with one WARN" do
  Cybertrain::DB.with do |c|
    c.execute("DROP TABLE cybertrain_feeds")
    c.execute("CREATE TABLE cybertrain_feeds (other INTEGER)")
  end
  assert_equal "200 ok", up_text
  assert_equal "200 ok", up_text
  warning = " WARN health: the feed status table cannot be read; feeds are not checked"
  assert_includes LOG.string, warning
  assert_equal LOG.string.index(warning), LOG.string.rindex(warning)
end

Cybertrain::Test.run!
