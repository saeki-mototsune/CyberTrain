# The WebSocket client and its long-lived feeds compiled together with the
# whole framework.
#
# test/websocket_client.rb and test/websocket_subscription.rb require only
# the WebSocket files, so a method name they share with another framework
# file (WebSocket.status next to DB::CLI.status and Migrator#status:
# spikes/NOTES.md rules 10, 34 and 41) would compile there and break only
# once both are in one program, which every application binary is. This
# program requires the framework entry point, cybertrain/websocket and the
# TLS layer (the openssl package, rule 62), and runs one feed the way
# Application#serve does: Background.start_all, a message into on_message,
# feed_status, Background.stop_all. Every wait is bounded; ports and timings
# are never printed.
#
# It links SQLite through FFI, so it cannot run under CRuby: its snapshot
# comes from the compiled binary (spikes/NOTES.md rule 23):
# script/regen-snapshot test/websocket_integration.rb.
require "stringio"
require "cybertrain"
require "cybertrain/websocket"
require "cybertrain/net/tls"
require "cybertrain/test/websocket_receiver"
require "cybertrain/test"

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
Cybertrain::WebSocket.random_source = -> { 0.5 }

# What the feed received (a constant: NOTES rule 64).
GOT = Array.new(0) { "" }

def mono_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def await_got(count, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if GOT.size >= count

    sleep(0.05)
  end
  GOT.size >= count
end

def subscribe_trades(url)
  Cybertrain::WebSocket.subscribe("trades", url, allow_private: true)
    .on_open { |conn| conn.send_text("subscribe") }
    .on_message { |conn, data| GOT << "#{conn.last_opcode}:#{data}" }
end

test "a feed runs through Background next to the whole framework" do
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 10.0, read_timeout: 5.0)
  rx.ws_script([Cybertrain::Test::WsStep.new("accept"), Cybertrain::Test::WsStep.new("expect"),
                Cybertrain::Test::WsStep.new("send_text", "tick"), Cybertrain::Test::WsStep.new("echo_until_close")])
  rx.start
  subscribe_trades(rx.url("/trades"))
  assert_equal 1, Cybertrain::Background.start_all(Cybertrain::Config.new)
  assert await_got(1, 5.0)
  assert_equal ["text:tick"], GOT
  assert Cybertrain::WebSocket.feed_status("trades").connected?
  assert_nil Cybertrain::Background.stop_all
  refute Cybertrain::WebSocket.running?
  refute Cybertrain::WebSocket.feed_status("trades").connected?
  frames = rx.ws_received(0.0)
  assert_equal "subscribe", frames[0].rec_data
  rx.stop
end

Cybertrain::Test.run!
