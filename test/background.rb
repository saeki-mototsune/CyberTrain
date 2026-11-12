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

# What FailingWriter does: "" nothing, "error" raises a RuntimeError,
# "crash" an Exception that is not a StandardError (a constant: NOTES
# rule 64).
WRITER_MODE = Array.new(0) { "" }

class WriterCrash < Exception
end

# A status writer that fails on demand, next to the FeedTable one.
class FailingWriter < Cybertrain::WebSocket::StatusWriter
  def status_write(name, process, connected, started_at, last_activity_at, restarts, now)
    mode = WRITER_MODE.empty? ? "" : WRITER_MODE[0]
    raise "status write failed" if mode == "error"
    raise WriterCrash, "status write crashed" if mode == "crash"

    false
  end
end

WS::STATUS_WRITERS << FailingWriter.new

def writer_mode(mode)
  WRITER_MODE.clear
  WRITER_MODE << mode
  nil
end

def count_of(text, needle)
  n = 0
  at = text.index(needle)
  until at.nil?
    n += 1
    at = text.index(needle, at + needle.size)
  end
  n
end

def await_log(needle, count, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if count_of(LOG.string, needle) >= count

    sleep(0.05)
  end
  count_of(LOG.string, needle) >= count
end

# Each feed test starts from here, whatever the tests before it left: the
# feeds and the supervisor stopped, the supervisor's state reset, the
# clock real again, not a feeds process, the writers quiet, and the feeds it needs
# registered (start! starts every registered feed).
def fresh_feeds(names)
  B.stop_all
  B.reset_supervisor!
  travel_back
  B.exit_on_feed_death = false
  writer_mode("")
  subscribe_steady(dead_url("/steady")) if names.include?("steady") && WS.subscription_index("steady") < 0
  subscribe_crashy(dead_url("/crashy")) if names.include?("crashy") && WS.subscription_index("crashy") < 0
  nil
end

def restarts_of(name)
  WS.feed_status(name).restarts
end

def step(kind)
  Cybertrain::Test::WsStep.new(kind, "")
end

# The close frames the receiver got from the client.
def closes_seen(rx)
  frames = rx.ws_received(0.0)
  n = 0
  frames.each { |f| n += 1 if f.rec_opcode == 8 }
  n
end

def await_closes(rx, count, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if closes_seen(rx) >= count

    sleep(0.05)
  end
  closes_seen(rx) >= count
end

# Dies (a non-StandardError) at its first tick while connected.
def subscribe_leaky(url)
  WS.subscribe("leaky", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
    .on_tick(1) { |conn| raise FeedCrash, "leaky died" unless conn.nil? }
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
  fresh_feeds(["steady"])
  refute B.supervising?
  # The supervisor thread reads the Clock for the rows.
  travel_to(Time.at(5000))
  assert B.start_all(feeds_config) >= 1
  assert B.supervising?
  assert WS.running?
  # Its first pass publishes the rows at once.
  ends_at = mono_now + 3.0
  sleep(0.05) while feed_row("steady") != "0/0/5000" && mono_now < ends_at
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
  travel_back
end

test "a feed thread that dies is restarted after the backoff and restarts counts it" do
  fresh_feeds(["crashy"])
  config = feeds_config
  base = restarts_of("crashy")
  first = B.restart_backoff(base)
  second = B.restart_backoff(base + 1)
  assert WS.start!(config)
  assert await_alive("crashy", false, 4.0)
  # The first pass sees it dead: a warning, the restart after the backoff.
  B.supervise_pass(config, 1000, 1000)
  assert_includes LOG.string, "[ERROR] WebSocket \"crashy\" thread ended: FeedCrash: crashy died"
  assert_includes LOG.string, "[WARN] feed crashy: its thread ended; restarting in #{first}s"
  B.supervise_pass(config, 1000, 1000 + first - 1)
  refute WS.thread_alive?("crashy")
  assert_equal base, restarts_of("crashy")
  B.supervise_pass(config, 1000, 1000 + first)
  assert_equal base + 1, restarts_of("crashy")
  # It dies again (at its first tick): the next backoff doubles.
  assert await_alive("crashy", false, 4.0)
  m = 1000 + first + 1
  B.supervise_pass(config, 1000, m)
  assert_includes LOG.string, "[WARN] feed crashy: its thread ended; restarting in #{second}s"
  B.supervise_pass(config, 1000, m + second - 1)
  assert_equal base + 1, restarts_of("crashy")
  B.supervise_pass(config, 1000, m + second)
  assert_equal base + 2, restarts_of("crashy")
  # Not a feeds process (exit_on_feed_death is off): it never gives up.
  refute B.feeds_failed?
  WS.stop!
end

test "a feed that dies while connected closes its connection; restarts leave no socket open" do
  fresh_feeds([])
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 3, accept_window: 20.0, read_timeout: 10.0)
  rx.ws_script([step("accept"), step("echo_until_close")])
  rx.ws_script([step("accept"), step("echo_until_close")])
  rx.ws_script([step("accept"), step("echo_until_close")])
  rx.start
  subscribe_leaky(rx.url("/leaky")) if WS.subscription_index("leaky") < 0
  config = feeds_config
  assert WS.start!(config)
  m = 10_000
  deaths = 0
  while deaths < 3
    assert await_alive("leaky", false, 6.0)
    deaths += 1
    # The dying thread closed its client: the server got close 1000.
    assert await_closes(rx, deaths, 3.0)
    break if deaths == 3

    B.supervise_pass(config, m, m)
    m += 40
    B.supervise_pass(config, m, m)
    assert WS.thread_alive?("leaky")
  end
  assert_equal 2, restarts_of("leaky")
  assert_equal 3, closes_seen(rx)
  assert_equal 3, count_of(LOG.string, "[ERROR] WebSocket \"leaky\" thread ended: FeedCrash: leaky died")
  WS.stop!
  rx.stop
end

test "status rows are written with started_at, last_activity_at and restarts" do
  fresh_feeds(["steady", "crashy"])
  config = feeds_config
  restarts = restarts_of("crashy")
  assert WS.start!(config)
  # A supervisor's first pass publishes; the next after 10 s.
  B.supervise_pass(config, 2000, 2000)
  assert_equal "0/0/2000", feed_row("steady")
  assert_equal "0/#{restarts}/2000", feed_row("crashy")
  B.supervise_pass(config, 2005, 2005)
  assert_equal "0/#{restarts}/2000", feed_row("crashy")
  B.supervise_pass(config, 2010, 2010)
  assert_equal "0/#{restarts}/2010", feed_row("crashy")
  row = feed_row_hash("crashy")
  refute row.nil?
  started = Cybertrain::Cast.int(row["started_at"])
  assert started > 0
  assert started <= Time.now.to_i
  assert_nil row["last_activity_at"]
  WS.stop!
end

test "after stop! nothing is restarted" do
  fresh_feeds(["crashy"])
  config = feeds_config
  assert WS.start!(config)
  assert await_alive("crashy", false, 4.0)
  B.supervise_pass(config, 3000, 3000)
  WS.stop!
  restarts = restarts_of("crashy")
  B.supervise_pass(config, 3100, 3100)
  B.supervise_pass(config, 3200, 3200)
  assert_equal restarts, restarts_of("crashy")
  refute WS.thread_alive?("crashy")
end

test "a pass of a stopped supervisor restarts nothing" do
  fresh_feeds(["crashy"])
  config = feeds_config
  assert WS.start!(config)
  assert await_alive("crashy", false, 4.0)
  B.supervise_pass(config, 3500, 3500)
  restarts = restarts_of("crashy")
  # Generation 7 is not the running supervisor's (none runs): a pass of a
  # supervisor that outlived stop_supervisor!'s wait.
  B.supervise_pass(config, 3600, 3600, 7)
  assert_equal restarts, restarts_of("crashy")
  refute WS.thread_alive?("crashy")
  # A direct pass while no supervisor runs still restarts it.
  B.supervise_pass(config, 3600, 3600)
  assert_equal restarts + 1, restarts_of("crashy")
  WS.stop!
end

test "a failing status write leaves the supervisor and the feeds running" do
  fresh_feeds(["steady"])
  config = feeds_config
  config.feed_status_interval = 1
  writer_mode("error")
  assert B.start_all(config) >= 1
  # One error a second: the supervisor goes on after each.
  assert await_log("[ERROR] feed supervisor: RuntimeError: status write failed", 2, 5.0)
  assert B.supervising?
  assert WS.thread_alive?("steady")
  # Nor does an exception that is not a StandardError stop it.
  writer_mode("crash")
  assert await_log("[ERROR] feed supervisor: WriterCrash: status write crashed", 2, 5.0)
  assert B.supervising?
  assert WS.thread_alive?("steady")
  writer_mode("")
  assert_nil B.stop_all
  refute B.supervising?
end

test "a feeds process gives up when a feed dies after feed_restart_limit restarts in the window" do
  fresh_feeds(["crashy"])
  config = feeds_config
  config.feed_restart_limit = 2
  B.exit_on_feed_death = true
  assert WS.start!(config)
  assert await_alive("crashy", false, 4.0)
  B.supervise_pass(config, 4000, 4000)
  B.supervise_pass(config, 4100, 4100)
  assert await_alive("crashy", false, 4.0)
  B.supervise_pass(config, 4200, 4200)
  B.supervise_pass(config, 4300, 4300)
  refute B.feeds_failed?
  assert await_alive("crashy", false, 4.0)
  # The third death, after two restarts within 600 s.
  B.supervise_pass(config, 4400, 4400)
  assert B.feeds_failed?
  assert_includes LOG.string, "[FATAL] feed crashy restarted 2 times in 600 s; exiting"
  B.exit_on_feed_death = false
  B.reset_supervisor!
  refute B.feeds_failed?
  WS.stop!
end

Cybertrain::Test.run!
