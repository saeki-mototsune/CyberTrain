require "stringio"
require "cybertrain/config"
require "cybertrain/background"
require "cybertrain/db"
require "cybertrain/websocket"
require "cybertrain/websocket/feed_table"
require "cybertrain/test/websocket_receiver"
require "cybertrain/test"

# Cybertrain::Background: a service registered from outside
# application.rb (as cybertrain/websocket.rb will register itself) is
# started by start_all and stopped by stop_all through the base class's
# methods, start_all honours Config#worker, and a name is registered once.
# Application#serve calls start_all/stop_all next to Scheduler's.
#
# The feed supervisor (cybertrain/background/supervisor.rb): start_all
# starts it when feeds run and stop_all stops it before the feeds; one pass
# (Background.supervise_pass, what its thread runs every second) restarts
# a dead feed thread after min(30, 2 ** restarts) seconds, measured with
# the `now` it is given, and publishes the cybertrain_feeds rows every
# feed_status_interval. The feeds that die raise an Exception that is not
# a StandardError from on_tick, past every rescue of the feed loop (the
# thread logs it as it ends). It links SQLite through FFI, so the
# snapshot comes from the compiled binary (spikes/NOTES.md rule 23).

B = Cybertrain::Background

# What the probe did, read back by the tests (a constant: NOTES rule 64).
CALLS = Array.new(0) { "" }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# A subclass held in the registry typed by the base class: the calls
# dispatch to its methods.
class ProbeService < Cybertrain::Background::Service
  def service_name
    "probe"
  end

  def service_start(config)
    CALLS << "start"
    true
  end

  def service_stop
    CALLS << "stop"
    nil
  end
end

# A second subclass, which would refuse to start: its problem is what
# Application#serve fails the boot with.
class MisconfiguredService < Cybertrain::Background::Service
  def service_name
    "misconfigured"
  end

  def service_problem
    "misconfigured has no handler"
  end
end

# Registered at top level, as a required file does.
B.register(ProbeService.new)
B.register(MisconfiguredService.new)

WS = Cybertrain::WebSocket
WS.random_source = -> { 0.5 }
Cybertrain::DB.connect(":memory:")

# Raised from on_tick: not a StandardError, so no rescue of the feed loop
# takes it and the feed's thread ends.
class FeedCrash < Exception
end

def mono_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# A port nothing listens on any more.
def dead_url(path)
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 1.0, read_timeout: 1.0)
  rx.start
  rx.stop
  rx.url(path)
end

# Waits (at most `wait` seconds) until the feed's thread is alive or not.
def await_alive(name, alive, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if WS.thread_alive?(name) == alive

    sleep(0.05)
  end
  WS.thread_alive?(name) == alive
end

def subscribe_steady(url)
  WS.subscribe("steady", url, allow_private: true).on_message { |conn, data| conn.send_text(data) }
end

def subscribe_crashy(url)
  WS.subscribe("crashy", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
    .on_tick(1) { |conn| raise FeedCrash, "crashy died" }
end

# The cybertrain_feeds row of `name`, or nil.
def feed_row_hash(name)
  rows = WS::FeedTable.read_feeds
  i = 0
  while i < rows.size
    return rows[i] if Cybertrain::Cast.str(rows[i]["name"]) == name

    i += 1
  end
  nil
end

# The row of `name` as "connected/restarts/updated_at", "" when there is
# none.
def feed_row(name)
  row = feed_row_hash(name)
  return "" if row.nil?

  "#{Cybertrain::Cast.int(row["connected"])}/#{Cybertrain::Cast.int(row["restarts"])}/#{Cybertrain::Cast.int(row["updated_at"])}"
end

def feeds_config
  config = Cybertrain::Config.new
  config.feed_status_interval = 10
  config
end

test "start_all starts every registered service" do
  assert_equal 1, B.start_all(Cybertrain::Config.new)
  assert_equal ["start"], CALLS
end

test "stop_all stops them" do
  B.stop_all
  assert_equal "stop", CALLS[CALLS.size - 1]
end

test "start_all does nothing when the worker is off" do
  config = Cybertrain::Config.new
  config.worker = false
  before = CALLS.size
  assert_equal 0, B.start_all(config)
  assert_equal before, CALLS.size
end

test "boot_problem names the first service that would refuse to start" do
  assert_equal "misconfigured has no handler", B.boot_problem(Cybertrain::Config.new)
end

test "boot_problem is empty when the worker is off" do
  config = Cybertrain::Config.new
  config.worker = false
  assert_equal "", B.boot_problem(config)
end

test "a name registered twice is refused" do
  assert_includes assert_raises("ArgumentError") { B.register(ProbeService.new) }, "already registered"
end

test "restart_backoff is min(30, 2 ** restarts) seconds" do
  assert_equal 1, B.restart_backoff(0)
  assert_equal 2, B.restart_backoff(1)
  assert_equal 16, B.restart_backoff(4)
  assert_equal 30, B.restart_backoff(5)
  assert_equal 30, B.restart_backoff(70)
end

test "the feed settings: 10, 10 and 600, from the environment, each at least 1" do
  config = Cybertrain::Config.new
  assert_equal 10, config.feed_status_interval
  assert_equal 10, config.feed_restart_limit
  assert_equal 600, config.feed_restart_window
  assert_equal "", config.feeds_error
  ENV["CYBERTRAIN_FEED_STATUS_INTERVAL"] = "5"
  ENV["CYBERTRAIN_FEED_RESTART_LIMIT"] = "3"
  ENV["CYBERTRAIN_FEED_RESTART_WINDOW"] = "often"
  config = Cybertrain::Config.new
  assert_equal 5, config.feed_status_interval
  assert_equal 3, config.feed_restart_limit
  assert_equal 600, config.feed_restart_window
  ENV["CYBERTRAIN_FEED_RESTART_LIMIT"] = "0"
  assert_equal "feed_restart_limit must be at least 1 (got 0)", Cybertrain::Config.new.feeds_error
  ENV.delete("CYBERTRAIN_FEED_STATUS_INTERVAL")
  ENV.delete("CYBERTRAIN_FEED_RESTART_LIMIT")
  ENV.delete("CYBERTRAIN_FEED_RESTART_WINDOW")
  config = Cybertrain::Config.new
  config.feed_status_interval = 0
  assert_equal "feed_status_interval must be at least 1 (got 0)", config.feeds_error
  config = Cybertrain::Config.new
  config.feed_restart_window = 0
  assert_equal "feed_restart_window must be at least 1 (got 0)", config.feeds_error
end

test "start_all starts the supervisor with the feeds; stop_all stops it before them" do
  subscribe_steady(dead_url("/steady"))
  refute B.supervising?
  # The supervisor thread reads the injected clock.
  B.supervisor_clock = -> { 5000 }
  assert_equal 2, B.start_all(feeds_config)
  assert B.supervising?
  assert WS.running?
  # Its first pass publishes the rows at once.
  ends_at = mono_now + 3.0
  sleep(0.05) while feed_row("steady").empty? && mono_now < ends_at
  assert_equal "0/0/5000", feed_row("steady")
  row = feed_row_hash("steady")
  refute row.nil?
  assert Cybertrain::Cast.int(row["started_at"]) > 0
  assert_nil row["last_activity_at"]
  assert_includes Cybertrain::Cast.str(row["process"]), ":"
  assert_nil B.stop_all
  refute B.supervising?
  refute WS.running?
  # A second stop_all does nothing.
  assert_nil B.stop_all
end

test "a feed thread that dies is restarted after the backoff and restarts counts it" do
  subscribe_crashy(dead_url("/crashy"))
  config = feeds_config
  B.reset_supervisor!
  assert WS.start!(config)
  assert await_alive("crashy", false, 4.0)
  # The first pass sees it dead: a warning, the restart in 2 ** 0 s.
  B.supervise_pass(config, 1000)
  assert_includes LOG.string, "[ERROR] WebSocket \"crashy\" thread ended: FeedCrash: crashy died"
  assert_includes LOG.string, "[WARN] feed crashy: its thread ended; restarting in 1s"
  refute WS.thread_alive?("crashy")
  B.supervise_pass(config, 1000)
  refute WS.thread_alive?("crashy")
  assert_equal 0, WS.feed_status("crashy").restarts
  B.supervise_pass(config, 1001)
  assert_equal 1, WS.feed_status("crashy").restarts
  # It dies again (at its first tick): now 2 ** 1 s.
  assert await_alive("crashy", false, 4.0)
  B.supervise_pass(config, 1002)
  assert_includes LOG.string, "[WARN] feed crashy: its thread ended; restarting in 2s"
  B.supervise_pass(config, 1003)
  assert_equal 1, WS.feed_status("crashy").restarts
  B.supervise_pass(config, 1004)
  assert_equal 2, WS.feed_status("crashy").restarts
  # Not a feeds process (exit_on_feed_death is off): it never gives up.
  refute B.feeds_failed?
  WS.stop!
end

test "status rows are written with started_at, last_activity_at and restarts" do
  config = feeds_config
  # A supervisor's first pass publishes; the next after 10 s.
  B.reset_supervisor!
  assert WS.start!(config)
  B.supervise_pass(config, 2000)
  assert_equal "0/0/2000", feed_row("steady")
  assert_equal "0/2/2000", feed_row("crashy")
  B.supervise_pass(config, 2005)
  assert_equal "0/2/2000", feed_row("crashy")
  B.supervise_pass(config, 2010)
  assert_equal "0/2/2010", feed_row("crashy")
  row = feed_row_hash("crashy")
  refute row.nil?
  started = Cybertrain::Cast.int(row["started_at"])
  assert started > 0
  assert started <= Time.now.to_i
  assert_nil row["last_activity_at"]
  WS.stop!
end

test "after stop! nothing is restarted" do
  config = feeds_config
  restarts = WS.feed_status("crashy").restarts
  B.supervise_pass(config, 3000)
  B.supervise_pass(config, 3100)
  assert_equal restarts, WS.feed_status("crashy").restarts
  refute WS.thread_alive?("crashy")
end

test "a feeds process gives up after feed_restart_limit deaths in the window" do
  config = feeds_config
  config.feed_restart_limit = 2
  B.reset_supervisor!
  B.exit_on_feed_death = true
  assert WS.start!(config)
  assert await_alive("crashy", false, 4.0)
  B.supervise_pass(config, 4000)
  B.supervise_pass(config, 4100)
  refute B.feeds_failed?
  assert await_alive("crashy", false, 4.0)
  B.supervise_pass(config, 4200)
  assert B.feeds_failed?
  assert_includes LOG.string, "[FATAL] feed crashy restarted 2 times in 600 s; exiting"
  B.exit_on_feed_death = false
  B.reset_supervisor!
  refute B.feeds_failed?
  WS.stop!
end

Cybertrain::Test.run!
