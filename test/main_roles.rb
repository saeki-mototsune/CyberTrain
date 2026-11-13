require "tmpdir"
require "stringio"
require "cybertrain/test"
require "cybertrain"
require "cybertrain/websocket"
require_relative "support/log_capture"

# Requiring the framework must not create Cybertrain.config: one made then
# keeps the environment of that moment (development), before the lines
# below set CYBERTRAIN_ENV (or an embedded build's gen/views.rb defaults it
# to production). cybertrain/cache's prune task once read its interval
# through it at require time.
CONFIG_AT_REQUIRE = Cybertrain.config_loaded?

# The `worker` and `feeds` process roles of Cybertrain::Main.run: the
# predicates, `help`, a worker that boots, runs a job on its job threads
# and returns 0 once stopped, argument errors, and `feeds` refusing an
# unknown name (listing the registered ones), running only the named
# subscription, and saying so when none is registered. A thread stops each
# role through Application.request_stop_roles (what the TERM trap calls).
# Runs from a fresh temp directory (boot writes tmp/secret_key and the
# database there). It links SQLite through FFI, so its snapshot comes from
# the compiled binary (spikes/NOTES.md rule 23). It requires the whole
# framework, as an application does (boot reaches every part of it).
TMP = Dir.mktmpdir("cybertrain-roles")
Dir.chdir(TMP)
ENV["CYBERTRAIN_ENV"] = "test"
ENV["CYBERTRAIN_DATABASE"] = "roles.sqlite3"
ENV.delete("CYBERTRAIN_WORKER")
ENV.delete("CYBERTRAIN_JOB_THREADS")

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

# What the job ran (a constant: NOTES rule 64).
DONE = Array.new(0) { "" }

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def resolver = ->(name, args, options) { "/" }

def run(argv)
  Cybertrain::Main.run("blog", argv, router: Cybertrain::Router.new, url_resolver: resolver, views: no_views)
end

# Through a method whose parameter the closure captures (NOTES rule 21).
def spawn_stopper(delay)
  Thread.new { stop_after(delay) }
end

def stop_after(delay)
  sleep delay
  Cybertrain::Application.request_stop_roles
  nil
end

def job_state(id)
  rows = Cybertrain::DB.with { |c| c.execute("SELECT state FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["state"])
end

test "requiring the framework leaves the config to the first use, after CYBERTRAIN_ENV is set" do
  refute CONFIG_AT_REQUIRE
  assert_equal "test", Cybertrain.config.env
end

test "worker? and feeds? recognise their words; server? is false for both" do
  assert Cybertrain::Main.worker?(["worker"])
  refute Cybertrain::Main.worker?([])
  refute Cybertrain::Main.worker?(["server"])
  assert Cybertrain::Main.feeds?(["feeds"])
  assert Cybertrain::Main.feeds?(["feeds", "x"])
  refute Cybertrain::Main.feeds?(["worker"])
  refute Cybertrain::Main.server?(["worker"])
  refute Cybertrain::Main.server?(["feeds", "x"])
  assert_includes assert_raises("ArgumentError") { Cybertrain::Main.command("worker", "x") { |argv| 0 } }, "built-in"
  assert_includes assert_raises("ArgumentError") { Cybertrain::Main.command("feeds", "x") { |argv| 0 } }, "built-in"
end

test "help lists worker and feeds" do
  assert_equal 0, run(["help"])
end

test "feeds before any subscription: nothing to run is 0, any name is unknown" do
  assert_equal 0, run(["feeds"])
  assert_equal 1, run(["feeds", "nosuch"])
end

test "worker with only the built-in mail job and the cache prune task boots, waits for the stop and returns 0" do
  spawn_stopper(0.3)
  assert_equal 0, run(["worker"])
  refute Cybertrain::Job.running?
  refute Cybertrain::Scheduler.running?
end

test "worker takes no arguments" do
  assert_equal 1, run(["worker", "3000"])
end

test "worker runs a due job on its job threads and stops them" do
  Cybertrain::Job.handle("ping") { |payload| DONE << payload }
  Cybertrain::Scheduler.every(3600, "hourly") { DONE << "hourly" }
  # boot keeps a database that is already connected.
  Cybertrain::DB.connect("roles.sqlite3")
  id = Cybertrain::Job.enqueue("ping", "pong", run_at: Time.at(Time.now.to_i - 1))
  spawn_stopper(1.5)
  assert_equal 0, run(["worker"])
  assert_equal "pong", DONE.join(",")
  assert_equal "done", job_state(id)
  refute Cybertrain::Job.running?
  refute Cybertrain::Scheduler.running?
  assert_logged LOG.string, "INFO", "Job threads started: 3"
  assert_logged LOG.string, "INFO", "Scheduler started: cybertrain cache prune every 300s, hourly every 3600s"
end

test "feeds runs only the named subscription and stops it" do
  Cybertrain::WebSocket.subscribe("trades", "ws://127.0.0.1:1/", allow_private: true).on_message { |conn, text| DONE << text }
  Cybertrain::WebSocket.subscribe("quotes", "ws://127.0.0.1:1/", allow_private: true).on_message { |conn, text| DONE << text }
  assert_equal "", Cybertrain::WebSocket.unknown_feed(["trades", "quotes"])
  assert_equal "unknown feed \"nosuch\" (registered: trades, quotes)", Cybertrain::WebSocket.unknown_feed(["nosuch"])
  assert_equal "unknown feed \"nosuch\" (registered: trades, quotes)", Cybertrain::Background.unknown_feed(["trades", "nosuch"])
  assert_equal 1, run(["feeds", "nosuch"])
  spawn_stopper(0.3)
  assert_equal 0, run(["feeds", "trades"])
  refute Cybertrain::WebSocket.running?
  assert_logged LOG.string, "INFO", "WebSocket started: trades"
  refute LOG.string.include?("WebSocket started: quotes")
end

# What SlowSubscriber received: a subscriber slower than a role's own stop.
# It stays subscribed; other reports (a feed's) pass it by at once.
REPORTED = Array.new(0) { "" }

class SlowSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    text = event.error_message
    return nil unless text.start_with?("before the ")

    sleep 1.0
    REPORTED << text
    nil
  end
end

def report_runtime(message)
  raise message
rescue RuntimeError => e
  Cybertrain.error.report(e)
end

# After the feeds test above registered "trades".
test "worker and feeds wait for the queued error reports when they stop" do
  Cybertrain.error.subscribe(SlowSubscriber.new)
  report_runtime("before the worker stops")
  spawn_stopper(0.1)
  assert_equal 0, run(["worker"])
  assert_equal ["before the worker stops"], REPORTED
  report_runtime("before the feeds stop")
  spawn_stopper(0.1)
  assert_equal 0, run(["feeds", "trades"])
  assert_equal ["before the worker stops", "before the feeds stop"], REPORTED
end

test "worker and feeds give Spinel the SPINEL_WORKERS serve does" do
  Cybertrain.config.workers = 2
  expected = Cybertrain::Application.spinel_workers_for(Cybertrain.config).to_s
  spawn_stopper(0.3)
  worker_status = run(["worker"])
  worker_env = ENV["SPINEL_WORKERS"].to_s
  ENV["SPINEL_WORKERS"] = "1"
  spawn_stopper(0.3)
  feeds_status = run(["feeds", "trades"])
  feeds_env = ENV["SPINEL_WORKERS"].to_s
  ENV["SPINEL_WORKERS"] = "1"
  Cybertrain.config.workers = 1
  assert_equal 0, worker_status
  assert_equal 0, feeds_status
  assert_equal expected, worker_env
  assert_equal expected, feeds_env
end

test "in development the roles run on one worker, as serve does" do
  # A job or feed callback renders through the development engine, whose
  # parsed-template cache two workers must not write at once.
  saved = Cybertrain.config.env
  Cybertrain.config.env = "development"
  Cybertrain.config.workers = 2
  spawn_stopper(0.3)
  status = run(["worker"])
  env = ENV["SPINEL_WORKERS"].to_s
  ENV["SPINEL_WORKERS"] = "1"
  Cybertrain.config.workers = 1
  Cybertrain.config.env = saved.to_s
  assert_equal 0, status
  assert_equal "1", env
end

# A thread that sends the process a signal, through a method whose
# parameters the closure captures (NOTES rule 21), like spawn_stopper.
def spawn_signaller(delay, signal)
  Thread.new { signal_after(delay, signal) }
end

def signal_after(delay, signal)
  sleep delay
  Process.kill(signal, Process.pid)
  nil
end

# The INT handler of a caller of the roles (a block seeing only a constant,
# NOTES rule 64), installed to see it come back after a role ran.
def install_caller_int_handler
  trap("INT") { DONE << "caller's INT handler" }
  nil
end

test "worker stops on SIGINT and feeds on SIGTERM, as the traps ask" do
  spawn_signaller(0.3, "INT")
  assert_equal 0, run(["worker"])
  refute Cybertrain::Job.running?
  spawn_signaller(0.3, "TERM")
  assert_equal 0, run(["feeds", "trades"])
  refute Cybertrain::WebSocket.running?
end

test "a role hands back the INT and TERM handlers it replaced" do
  install_caller_int_handler
  spawn_stopper(0.3)
  assert_equal 0, run(["worker"])
  # Delivered to the caller's handler again, not to the role's.
  Process.kill("INT", Process.pid)
  sleep 0.2
  trap("INT", "DEFAULT")
  assert_includes DONE, "caller's INT handler"
  # TERM was the default before any role ran here, and is again.
  assert_equal "DEFAULT", trap("TERM", "DEFAULT").to_s
end

test "feeds status prints one line per status row and returns 0; with none it says so" do
  Cybertrain::DB.connect("roles.sqlite3")
  Cybertrain::WebSocket::FeedTable.ensure_installed
  Cybertrain::DB.with { |c| c.execute("DELETE FROM cybertrain_feeds") }
  now = 2_000_000_000
  travel_to(Time.at(now))
  assert_equal 0, run(["feeds", "status"])
  Cybertrain::WebSocket::FeedTable.upsert_feed("quotes", "host:42", false, now - 100, 0, 2, now - 5)
  Cybertrain::WebSocket::FeedTable.upsert_feed("trades", "host:42", true, now - 100, now - 7, 0, now - 5)
  assert_equal 0, run(["feeds", "status"])
  rows = Cybertrain::WebSocket::FeedTable.read_feeds
  assert_equal 2, rows.size
  quotes = Cybertrain::Application.feed_status_line(rows[0], now)
  trades = Cybertrain::Application.feed_status_line(rows[1], now)
  assert_equal "quotes  disconnected  host:42  last activity never  restarts 2  updated 5s ago", quotes
  assert_equal "trades  connected  host:42  last activity 7s ago  restarts 0  updated 5s ago", trades
  # A row no subscription of this binary names is marked.
  Cybertrain::WebSocket::FeedTable.upsert_feed("gone", "host:41", false, now - 900, 0, 0, now - 800)
  assert_equal 0, run(["feeds", "status"])
  gone = Cybertrain::WebSocket::FeedTable.read_feeds[0]
  assert_equal "gone  disconnected  host:41  last activity never  restarts 0  updated 800s ago  (not registered)",
               Cybertrain::Application.feed_status_line(gone, now)
  travel_back
  # status starts nothing.
  refute Cybertrain::WebSocket.running?
end

test "a feeds process stopped cleanly deletes its own status rows, not another process's" do
  Cybertrain::DB.connect("roles.sqlite3")
  Cybertrain::WebSocket::FeedTable.ensure_installed
  Cybertrain::DB.with { |c| c.execute("DELETE FROM cybertrain_feeds") }
  now = Time.now.to_i
  mine = Cybertrain::WebSocket.status_process
  assert_equal "#{Socket.gethostname}:#{Process.pid}", mine
  Cybertrain::WebSocket::FeedTable.upsert_feed("trades", mine, true, now - 100, now - 1, 0, now - 1)
  Cybertrain::WebSocket::FeedTable.upsert_feed("quotes", "elsewhere:7", true, now - 100, now - 1, 0, now - 1)
  spawn_stopper(0.3)
  assert_equal 0, run(["feeds", "trades"])
  Cybertrain::DB.connect("roles.sqlite3")
  rows = Cybertrain::WebSocket::FeedTable.read_feeds
  assert_equal 1, rows.size
  assert_equal "quotes", Cybertrain::Cast.str(rows[0]["name"])
end

Cybertrain::Test.run!
