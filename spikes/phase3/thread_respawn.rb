# Phase 3 spike, check 3 (spec section 14): Thread#alive? on a thread that
# ended by raising, and its replacement spawned from another thread through
# a method, in a program whose WebSocket client is running a feed at the
# same time. A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase3/):
#   spinel $(spin flags) thread_respawn.rb -o /tmp/thread_respawn && /tmp/thread_respawn
# and `ruby -I../.. thread_respawn.rb` under CRuby 3.3.6. Output (stdout
# identical under both; the two stderr lines are Spinel's report of the
# thread's exception, which CRuby words as `run` with a backtrace):
#   (stderr) #<Thread:0x… thread_respawn.rb:45 aborting> terminated with exception (report_on_exception is true):
#   (stderr) loop 1 died (RuntimeError)
#   feed started: true
#   watcher alive after join: false
#   first alive?: false
#   supervisor saw it dead: true, restarts: 1
#   replacement alive? after join: false
#   runs: loop 1 started, loop 2 started, loop 2 finished
#   join on the dead thread: join raised RuntimeError: loop 1 died
#   feed messages: tick
#   feed thread alive? while running: true
#   feed thread alive? after stop!: false
#   log has connected: true
require "stringio"
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
WS = Cybertrain::WebSocket

# Constants, not class variables (NOTES rule 64).
MESSAGES = Array.new(0) { "" }
RUNS = Array.new(0) { "" }
LOCK = Mutex.new

def mono_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def note(text)
  LOCK.synchronize { RUNS << text }
  nil
end

# The feed loop stand-in: the first generation raises past every rescue,
# the second runs to the end.
def feed_loop(generation)
  note("loop #{generation} started")
  text = "loop #{generation} died"
  raise RuntimeError, text if generation == 1

  note("loop #{generation} finished")
  nil
end

# Through a method, the closure capturing the parameter (NOTES rule 21).
def spawn_loop(generation)
  Thread.new { feed_loop(generation) }
end

class Supervisor
  def initialize(thread)
    @watched = thread
    @restarts = 0
    @seen_dead = false
  end

  def restarts
    @restarts
  end

  def seen_dead?
    @seen_dead
  end

  def watched
    @watched
  end

  # Runs on the supervisor's own thread: reads alive? on a thread another
  # thread started, and starts the replacement from here.
  def watch_once(wait)
    ends_at = mono_now + wait
    while mono_now < ends_at
      unless @watched.alive?
        @seen_dead = true
        @restarts += 1
        @watched = spawn_loop(@restarts + 1)
        return true
      end
      sleep(0.02)
    end
    false
  end
end

def spawn_supervisor(sup)
  Thread.new { sup.watch_once(5.0) }
end

rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 10.0, read_timeout: 5.0)
rx.ws_script([Cybertrain::Test::WsStep.new("accept", ""), Cybertrain::Test::WsStep.new("send_text", "tick"),
              Cybertrain::Test::WsStep.new("echo_until_close", "")])
rx.start
WS.random_source = -> { 0.5 }
sub = WS.subscribe("ticks", rx.url("/ticks"), allow_private: true)
sub.on_message { |conn, data| LOCK.synchronize { MESSAGES << data } }
puts "feed started: #{WS.start!(Cybertrain::Config.new)}"

first = spawn_loop(1)
sup = Supervisor.new(first)
watcher = spawn_supervisor(sup)
watcher.join(6.0)
puts "watcher alive after join: #{watcher.alive?}"
puts "first alive?: #{first.alive?}"
puts "supervisor saw it dead: #{sup.seen_dead?}, restarts: #{sup.restarts}"
replacement = sup.watched
replacement.join(2.0)
puts "replacement alive? after join: #{replacement.alive?}"
LOCK.synchronize { puts "runs: #{RUNS.join(", ")}" }

joined = "no error"
begin
  first.join(1.0)
rescue RuntimeError => e
  joined = "join raised #{e.class.name}: #{e.message}"
end
puts "join on the dead thread: #{joined}"

ends_at = mono_now + 5.0
sleep(0.05) while mono_now < ends_at && LOCK.synchronize { MESSAGES.size } < 1
LOCK.synchronize { puts "feed messages: #{MESSAGES.join(",")}" }
feed_thread = sub.sub_thread
puts "feed thread alive? while running: #{!feed_thread.nil? && feed_thread.alive?}"
WS.stop!
sleep(0.2)
puts "feed thread alive? after stop!: #{!feed_thread.nil? && feed_thread.alive?}"
rx.stop
puts "log has connected: #{LOG.string.include?("connected to 127.0.0.1:")}"
