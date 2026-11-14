require "stringio"
require "cybertrain/websocket"
require "cybertrain/net/tls"
require "cybertrain/test/websocket_receiver"
require "cybertrain/test"
require_relative "support/log_capture"

# Cybertrain::WebSocket.subscribe: the long-lived feeds Application#serve
# runs through Cybertrain::Background. The checks that need no thread come
# first (the retry delay, the registration errors, start!'s refusals); the
# ones that start the real feed threads against
# Cybertrain::Test::WebSocketReceiver come last, because start! starts every
# subscription registered so far and the threads of earlier tests keep
# retrying their (stopped) receivers until the next stop!. Each threaded
# test therefore uses a feed name of its own and asserts on that name's log
# lines. Every wait is a bounded poll; ports and timings are never printed.
#
# The TLS layer is in the program (cybertrain/net/tls requires Spinel's
# openssl package), so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23): script/regen-snapshot test/websocket_subscription.rb.

WS = Cybertrain::WebSocket

LOG = StringIO.new

# The framework's logger, except that the "connected" line of the feed
# named "dropper" raises: an error inside a feed session while its
# connection is open, which feed_session's rescue arms catch.
class DropperLogger < Cybertrain::Logger
  def info(msg)
    raise IOError, "the log refused the line" if msg.include?("\"dropper\" connected to")

    super
  end
end

Cybertrain.logger = DropperLogger.new(LOG)

# No jitter: every retry delay is exactly 1, 2, 4, ... seconds.
WS.random_source = -> { 0.5 }

# What the feeds' blocks received, read back by the tests (constants:
# NOTES rule 64).
TICKS = Array.new(0) { "" }
FLAKY = Array.new(0) { "" }
OPENS = Array.new(0) { "" }
TICKS_OFF = Array.new(0) { "" }
TICKS_ON = Array.new(0) { "" }
TICKS_BAD = Array.new(0) { "" }

# Registered at top level, as an application's config/app.rb does, and
# without on_message (the start! test gives it one). It keeps the default
# allow_private (false), so once it runs it is refused at once and never
# opens a socket.
BARE = WS.subscribe("bare", "ws://127.0.0.1:9/")

def step(kind, data = "")
  Cybertrain::Test::WsStep.new(kind, data)
end

def mono_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

# Waits (at most `wait` seconds) until the log holds `needle` `count` times.
def await_log(needle, count, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if count_of(LOG.string, needle) >= count

    sleep(0.05)
  end
  count_of(LOG.string, needle) >= count
end

# Waits until `list` has `count` entries.
def await_size(list, count, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if list.size >= count

    sleep(0.05)
  end
  list.size >= count
end

# Waits until the receiver has recorded `count` frames of `opcode`.
def await_frames(rx, opcode, count, wait)
  ends_at = mono_now + wait
  while true
    n = frames_of(rx, opcode).size
    return true if n >= count
    return false if mono_now >= ends_at

    sleep(0.05)
  end
  false
end

# The payloads of the recorded frames of `opcode`, without waiting.
def frames_of(rx, opcode)
  out = Array.new(0) { "" }
  frames = rx.ws_received(0.0)
  i = 0
  while i < frames.size
    out << frames[i].rec_data if frames[i].rec_opcode == opcode
    i += 1
  end
  out
end

# Waits until the feed's status has counted `count` reconnects.
def await_reconnects(name, count, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if WS.feed_status(name).reconnects >= count

    sleep(0.05)
  end
  WS.feed_status(name).reconnects >= count
end

# Waits until the feed's status reads connected.
def await_connected(name, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if WS.feed_status(name).connected?

    sleep(0.05)
  end
  WS.feed_status(name).connected?
end

def receiver_for(max, steps_list)
  rx = Cybertrain::Test::WebSocketReceiver.new(max: max, accept_window: 10.0, read_timeout: 5.0)
  i = 0
  while i < steps_list.size
    rx.ws_script(steps_list[i])
    i += 1
  end
  rx.start
  rx
end

# The subscriptions, in methods (each block is written where its
# parameters are used: NOTES rules 68/69).
def subscribe_ticks(url)
  WS.subscribe("ticks", url, allow_private: true)
    .on_message { |conn, data| TICKS << "#{conn.last_opcode}:#{data}" }
end

def subscribe_feed(url)
  WS.subscribe("feed", url, timeout: 2, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe trades") }
    .on_message { |conn, data| OPENS << data }
end

def subscribe_flaky(url)
  WS.subscribe("flaky", url, allow_private: true)
    .on_message do |conn, data|
      raise "cannot parse #{data}" if data == "1"

      FLAKY << data
    end
end

def subscribe_quiet(url)
  WS.subscribe("quiet", url, timeout: 2, ping_interval: 1, stale_after: 2, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
end

def subscribe_gone(url)
  WS.subscribe("gone", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
end

def subscribe_deaf(name, url)
  WS.subscribe(name, url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
end

# on_tick blocks: each records whether it was given a Connection (the
# parameter is nil while the feed is disconnected).
def subscribe_tick_off(url)
  WS.subscribe("tick_off", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
    .on_tick(1) { |conn| TICKS_OFF << (conn.nil? ? "nil" : "conn") }
end

def subscribe_tick_on(url)
  WS.subscribe("tick_on", url, allow_private: true)
    .on_message { |conn, data| TICKS_ON << data }
    .on_tick(1) do |conn|
      if conn.nil?
        TICKS_ON << "nil"
      else
        TICKS_ON << "conn"
        conn.send_text("tick #{TICKS_ON.size}")
      end
    end
end

def subscribe_tick_bad(url)
  WS.subscribe("tick_bad", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
    .on_tick(1) do |conn|
      TICKS_BAD << "tick"
      raise "tick failed #{TICKS_BAD.size}" if TICKS_BAD.size == 1
    end
end

TICKS_CONN_BAD = Array.new(0) { "" }

def subscribe_tick_conn_bad(url)
  WS.subscribe("tick_conn_bad", url, allow_private: true)
    .on_message { |conn, data| TICKS_CONN_BAD << data }
    .on_tick(1) do |conn|
      unless conn.nil?
        TICKS_CONN_BAD << "tick"
        raise "tick failed while connected" if TICKS_CONN_BAD.size == 1

        conn.send_text("after the error") if TICKS_CONN_BAD.size == 2
      end
    end
end

def subscribe_dropper(url)
  WS.subscribe("dropper", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
end

def subscribe_pongy(url)
  WS.subscribe("pongy", url, timeout: 2, ping_interval: 1, stale_after: 4, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
end

# A port nothing listens on any more.
def dead_url(path)
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 1.0, read_timeout: 1.0)
  rx.start
  rx.stop
  rx.url(path)
end

# ---- without threads --------------------------------------------------------

test "retry_delay doubles up to 60 seconds" do
  assert_equal 1.0, WS.retry_delay(1, 0.5)
  assert_equal 2.0, WS.retry_delay(2, 0.5)
  assert_equal 60.0, WS.retry_delay(7, 0.5)
  assert_equal 60.0, WS.retry_delay(20, 0.5)
  assert_equal 0.8, WS.retry_delay(1, 0.0)
  assert_equal 1.2, WS.retry_delay(1, 1.0)
end

test "subscribe refuses bad arguments" do
  assert_includes assert_raises("ArgumentError") { WS.subscribe("", "ws://127.0.0.1:9/") }, "empty"
  assert_includes assert_raises("ArgumentError") { WS.subscribe("bare", "ws://127.0.0.1:9/") }, "already registered"
  assert_includes assert_raises("ArgumentError") { WS.subscribe("web", "http://127.0.0.1:9/") }, "ws://"
  assert_includes assert_raises("ArgumentError") { WS.subscribe("zero", "ws://127.0.0.1:9/", ping_interval: 0) }, "ping_interval"
  assert_includes assert_raises("ArgumentError") { WS.subscribe("same", "ws://127.0.0.1:9/", stale_after: 15, ping_interval: 15) }, "stale_after"
  assert_includes assert_raises("ArgumentError") { WS.subscribe("header", "ws://127.0.0.1:9/", headers: { "Upgrade" => "h2c" }) }, "Upgrade"
  # `./<app> feeds status` is a command, so no feed takes that name.
  assert_equal "WebSocket.subscribe: the name \"status\" is reserved (./<app> feeds status)",
               assert_raises("ArgumentError") { WS.subscribe("status", "ws://127.0.0.1:9/") }
  assert_equal(-1, WS.subscription_index("status"))
end

test "start! refuses a subscription without on_message" do
  assert_includes assert_raises("ArgumentError") { WS.start!(Cybertrain::Config.new) }, "\"bare\" has no on_message"
  refute WS.running?
  # Application#serve finds it before binding the port.
  assert_equal "WebSocket subscription \"bare\" has no on_message",
               Cybertrain::Background.boot_problem(Cybertrain::Config.new)
  # Given one, "bare" is accepted from now on.
  assert_equal "bare", BARE.on_message { |conn, data| conn.send_text(data) }.sub_name
  assert_equal "", Cybertrain::Background.boot_problem(Cybertrain::Config.new)
end

test "start! does nothing when the worker is off" do
  config = Cybertrain::Config.new
  config.worker = false
  before = count_of(LOG.string, "\n")
  refute WS.start!(config)
  refute WS.running?
  assert_equal before + 1, count_of(LOG.string, "\n")
  assert_logged LOG.string, "INFO", "Background worker off (CYBERTRAIN_WORKER=0): WebSocket subscriptions run elsewhere"
end

test "stop! when not running does nothing" do
  assert_nil WS.stop!
  refute WS.running?
end

test "feed_status of an unknown name is an ArgumentError" do
  assert_includes assert_raises("ArgumentError") { WS.feed_status("nope") }, "\"nope\""
  status = WS.feed_status("bare")
  refute status.connected?
  assert_equal 0, status.last_message_at
  assert_equal 0, status.reconnects
end

test "on_tick takes whole seconds, at least 1, once per subscription" do
  sub = WS.subscribe("tick_args", "ws://127.0.0.1:9/").on_message { |conn, data| conn.send_text(data) }
  assert_includes assert_raises("ArgumentError") { sub.on_tick(0) { |conn| conn } }, "at least 1"
  assert_includes assert_raises("ArgumentError") { sub.on_tick(-1) { |conn| conn } }, "at least 1"
  assert_equal "tick_args", sub.on_tick(2) { |conn| conn }.sub_name
  assert_equal 2, sub.sub_tick_seconds
  assert_includes assert_raises("ArgumentError") { sub.on_tick(3) { |conn| conn } }, "already has on_tick"
end

test "sub_tick_due? counts from the start of the feed" do
  sub = WS.subscribe("tick_due", "ws://127.0.0.1:9/").on_message { |conn, data| conn.send_text(data) }
  refute sub.sub_tick_due?(100.0)
  sub.on_tick(5) { |conn| conn }
  sub.sub_tick_start!(100.0)
  refute sub.sub_tick_due?(104.9)
  assert sub.sub_tick_due?(105.0)
  sub.sub_ticked!(105.5)
  refute sub.sub_tick_due?(110.0)
  assert sub.sub_tick_due?(110.5)
end

test "feed_status has restarts and thread_alive? before the feeds run" do
  status = WS.feed_status("bare")
  assert_equal 0, status.restarts
  refute status.thread_alive?
  refute WS.thread_alive?("bare")
  refute WS.restart_feed("bare")
  assert_equal 0, WS.feed_status("bare").restarts
end

test "the service is registered with Background" do
  assert Cybertrain::Background.service_index("websocket") >= 0
end

# ---- with the feed threads (last) -------------------------------------------

test "messages reach on_message and status follows" do
  rx = receiver_for(1, [[step("accept"), step("send_text", "a"), step("send_text", "b"), step("echo_until_close")]])
  subscribe_ticks(rx.url("/ticks?key=secret"))
  assert WS.start!(Cybertrain::Config.new)
  assert WS.running?
  refute WS.start!(Cybertrain::Config.new)
  assert await_size(TICKS, 2, 5.0)
  assert_equal ["text:a", "text:b"], TICKS
  status = WS.feed_status("ticks")
  assert status.connected?
  assert status.last_message_at > 0
  assert_equal 0, status.reconnects
  assert_logged LOG.string, "INFO", "WebSocket started: ticks (ws://127.0.0.1:"
  assert_logged LOG.string, "INFO", "WebSocket \"ticks\" connected to 127.0.0.1:"
  refute LOG.string.include?("secret")
  WS.stop!
  refute WS.running?
  refute WS.feed_status("ticks").connected?
  # stop! closed the connection with 1000.
  closes = frames_of(rx, 8)
  assert_equal 1, closes.size
  assert_equal 1000, (closes[0].getbyte(0) << 8) | closes[0].getbyte(1)
  rx.stop
end

test "on_open runs again after every reconnect" do
  rx = receiver_for(2, [
    [step("accept"), step("expect"), step("close", "1001")],
    [step("accept"), step("expect"), step("echo_until_close")]
  ])
  subscribe_feed(rx.url("/feed"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_frames(rx, 1, 2, 8.0)
  assert_equal ["subscribe trades", "subscribe trades"], frames_of(rx, 1)
  assert await_reconnects("feed", 1, 5.0)
  assert_equal 1, WS.feed_status("feed").reconnects
  assert WS.feed_status("feed").connected?
  assert_logged LOG.string, "WARN", "WebSocket \"feed\" disconnected: Cybertrain::WebSocket::ClosedError: 127.0.0.1:"
  assert_includes LOG.string, ": closed by the server (1001) (retry in 1s)"
  assert_equal 2, count_of(LOG.string, "WebSocket \"feed\" connected to")
  WS.stop!
  rx.stop
end

test "an exception in on_message keeps the connection" do
  rx = receiver_for(1, [[step("accept"), step("send_text", "1"), step("send_text", "2"), step("echo_until_close")]])
  subscribe_flaky(rx.url("/flaky"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_size(FLAKY, 1, 5.0)
  assert_equal ["2"], FLAKY
  assert_logged LOG.string, "ERROR", "WebSocket \"flaky\" on_message failed: RuntimeError: cannot parse 1"
  assert_equal 0, WS.feed_status("flaky").reconnects
  assert WS.feed_status("flaky").connected?
  WS.stop!
  rx.stop
end

test "a silent feed is pinged, then reconnected" do
  # The first connection reads the ping and then says nothing for 5 s
  # (the receiver serves one connection at a time, so the second
  # connection is accepted once that pause is over).
  rx = receiver_for(2, [
    [step("accept"), step("expect"), step("silent", "5")],
    [step("accept"), step("echo_until_close")]
  ])
  subscribe_quiet(rx.url("/quiet"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_log("WebSocket \"quiet\" silent for 2s; reconnecting", 1, 6.0)
  assert_logged LOG.string, "WARN", "WebSocket \"quiet\" silent for 2s; reconnecting"
  assert await_reconnects("quiet", 1, 10.0)
  assert_equal 2, count_of(LOG.string, "WebSocket \"quiet\" connected to")
  # The first frame of the first connection was the ping.
  frames = rx.ws_received(0.0)
  assert_equal 9, frames[0].rec_opcode
  WS.stop!
  rx.stop
end

test "stop! ends a thread waiting to reconnect" do
  # A port nothing listens on any more.
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 1.0, read_timeout: 1.0)
  rx.start
  rx.stop
  subscribe_gone(rx.url("/gone"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_log("WebSocket \"gone\" disconnected: Cybertrain::WebSocket::RefusedError:", 1, 5.0)
  started = mono_now
  assert_nil WS.stop!
  assert mono_now - started < 3.0
  refute WS.running?
  seen = count_of(LOG.string, "disconnected:")
  sleep(1.5)
  assert_equal seen, count_of(LOG.string, "disconnected:")
end

test "stop! is bounded when servers ignore the close" do
  # Two servers that accept and then say nothing, not even close.
  rx1 = receiver_for(1, [[step("accept"), step("silent", "10")]])
  rx2 = receiver_for(1, [[step("accept"), step("silent", "10")]])
  subscribe_deaf("deaf1", rx1.url("/deaf"))
  subscribe_deaf("deaf2", rx2.url("/deaf"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_connected("deaf1", 5.0)
  assert await_connected("deaf2", 5.0)
  started = mono_now
  assert_nil WS.stop!
  assert mono_now - started < 3.0
  refute WS.feed_status("deaf1").connected?
  refute WS.feed_status("deaf2").connected?
  rx1.stop
  rx2.stop
end

test "on_tick fires every second while disconnected, with no connection" do
  subscribe_tick_off(dead_url("/tick_off"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_size(TICKS_OFF, 2, 5.0)
  assert_equal ["nil", "nil"], [TICKS_OFF[0], TICKS_OFF[1]]
  assert WS.thread_alive?("tick_off")
  assert WS.feed_status("tick_off").thread_alive?
  WS.stop!
  refute WS.feed_status("tick_off").connected?
end

test "on_tick fires every second while connected, with the connection" do
  rx = receiver_for(1, [[step("accept"), step("echo_until_close")]])
  subscribe_tick_on(rx.url("/tick_on"))
  assert WS.start!(Cybertrain::Config.new)
  # Each tick sends "tick N"; the receiver echoes it back to on_message.
  assert await_frames(rx, 1, 2, 6.0)
  sent = frames_of(rx, 1)
  assert_equal "tick 1", sent[0]
  assert_equal "conn", TICKS_ON[0]
  refute TICKS_ON.include?("nil")
  WS.stop!
  rx.stop
end

test "an exception in on_tick is logged and the loop continues" do
  subscribe_tick_bad(dead_url("/tick_bad"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_size(TICKS_BAD, 3, 6.0)
  assert_logged LOG.string, "ERROR", "WebSocket \"tick_bad\" on_tick failed: RuntimeError: tick failed 1"
  assert_equal 1, count_of(LOG.string, "on_tick failed")
  assert WS.thread_alive?("tick_bad")
  WS.stop!
end

test "an exception in on_tick while connected is logged and keeps the connection" do
  rx = receiver_for(1, [[step("accept"), step("echo_until_close")]])
  subscribe_tick_conn_bad(rx.url("/tick_conn_bad"))
  assert WS.start!(Cybertrain::Config.new)
  # The first tick raises; the second still has the same connection and
  # sends through it.
  assert await_frames(rx, 1, 1, 6.0)
  assert_equal "after the error", frames_of(rx, 1)[0]
  assert_logged LOG.string, "ERROR", "WebSocket \"tick_conn_bad\" on_tick failed: RuntimeError: tick failed while connected"
  assert_equal 0, WS.feed_status("tick_conn_bad").reconnects
  assert WS.feed_status("tick_conn_bad").connected?
  assert_equal 1, count_of(LOG.string, "WebSocket \"tick_conn_bad\" connected to")
  WS.stop!
  rx.stop
end

test "a pong refreshes the feed's activity, not its last message" do
  rx = receiver_for(1, [[step("accept"), step("echo_until_close")]])
  sub = subscribe_pongy(rx.url("/pongy"))
  assert_equal 0, sub.sub_last_activity_at
  before = Time.now.to_i
  assert WS.start!(Cybertrain::Config.new)
  # The ping goes out after 1 s of quiet; the receiver answers with a pong.
  assert await_frames(rx, 9, 1, 5.0)
  ends_at = mono_now + 3.0
  sleep(0.05) while sub.sub_last_activity_at == 0 && mono_now < ends_at
  assert sub.sub_last_activity_at >= before
  assert_equal 0, WS.feed_status("pongy").last_message_at
  WS.stop!
  rx.stop
end

test "an error inside a feed session closes the connection it had open" do
  rx = receiver_for(1, [[step("accept"), step("echo_until_close")]])
  subscribe_dropper(rx.url("/dropper"))
  assert WS.start!(Cybertrain::Config.new)
  assert await_log("WebSocket \"dropper\" disconnected: IOError: the log refused the line", 1, 5.0)
  # The client sent its close (1000) before the reconnect wait, rather
  # than forgetting a connection that stays open.
  assert await_frames(rx, 8, 1, 3.0)
  closes = frames_of(rx, 8)
  assert_equal 1000, (closes[0].getbyte(0) << 8) | closes[0].getbyte(1)
  WS.stop!
  rx.stop
end

Cybertrain::Test.run!
