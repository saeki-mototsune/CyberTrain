require "tmpdir"
require "cybertrain"
require "cybertrain/websocket"
require "cybertrain/test/websocket_receiver"
require "cybertrain/test"

# The exit rule of a `feeds` process (spec section 9): when one feed's
# thread dies again after Config#feed_restart_limit restarts within
# Config#feed_restart_window, the supervisor logs `[FATAL] feed NAME
# restarted N times in W s; exiting` and the process exits with status 1
# once the feeds are stopped, so the container's restart policy starts a
# fresh one. The process exits, so the case runs this program again as a
# child (the pattern of test/boot_encryption.rb) through Main.run's
# `feeds` role, with a feed whose on_tick raises an Exception that is not a
# StandardError (past every rescue of the feed loop) and a limit of 2. Boot
# connects SQLite (FFI), so the snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).
CHILD_FLAG = "CYBERTRAIN_FEEDS_EXIT_CHILD"

# Not a StandardError: the feed loop's rescues let it through.
class FeedCrash < Exception
end

def resolver = ->(name, args, options) { "/" }

def no_views
  none = { "" => "" }
  none.delete("")
  none
end

def subscribe_crashy(url)
  Cybertrain::WebSocket.subscribe("crashy", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
    .on_tick(1) { |conn| raise FeedCrash, "crashy died" }
end

if ENV[CHILD_FLAG] == "1"
  Dir.chdir(ENV["CT_TEST_DIR"].to_s)
  subscribe_crashy(ENV["CT_TEST_URL"].to_s)
  status = Cybertrain::Main.run("blog", ["feeds"], router: Cybertrain::Router.new, url_resolver: resolver,
                                                   views: no_views)
  puts "returned #{status}"
  STDOUT.flush
  exit(status)
end

TMP = Dir.mktmpdir("cybertrain-feeds-exit")
OUT_PATH = "#{TMP}/stdout.log"
ERR_PATH = "#{TMP}/stderr.log"

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit { rm_tree(TMP) }

# A port nothing listens on any more.
def dead_url(path)
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 1.0, read_timeout: 1.0)
  rx.start
  rx.stop
  rx.url(path)
end

# Runs the child; [exit status, stdout].
def feeds_child
  ENV[CHILD_FLAG] = "1"
  ENV["CT_TEST_DIR"] = TMP
  ENV["CT_TEST_URL"] = dead_url("/crashy")
  ENV["CYBERTRAIN_ENV"] = "test"
  ENV["CYBERTRAIN_DATABASE"] = "feeds.sqlite3"
  ENV["CYBERTRAIN_FEED_RESTART_LIMIT"] = "2"
  ENV["CYBERTRAIN_FEED_RESTART_WINDOW"] = "600"
  ENV["CYBERTRAIN_FEED_STATUS_INTERVAL"] = "1"
  pid = 0
  if RUBY_ENGINE == "ruby"
    pid = Process.spawn("ruby", "-I", File.expand_path("..", __dir__), $0, out: OUT_PATH, err: ERR_PATH)
  else
    pid = Process.spawn(File.expand_path($0), out: OUT_PATH, err: ERR_PATH)
  end
  ENV.delete(CHILD_FLAG)
  ENV.delete("CYBERTRAIN_FEED_RESTART_LIMIT")
  ENV.delete("CYBERTRAIN_FEED_RESTART_WINDOW")
  ENV.delete("CYBERTRAIN_FEED_STATUS_INTERVAL")
  status = Process.waitpid2(pid)[1].exitstatus.to_i
  [status.to_s, File.read(OUT_PATH)]
end

test "a feed that keeps dying makes a feeds process exit 1 with the FATAL line" do
  result = feeds_child
  out = result[1]
  assert_equal "1", result[0]
  assert_includes out, "=> feeds: crashy"
  assert_includes out, "[WARN] feed crashy: its thread ended; restarting in 1s"
  assert_includes out, "[INFO] WebSocket restarted: crashy (restart 1)"
  assert_includes out, "[FATAL] feed crashy restarted 2 times in 600 s; exiting"
  # The FATAL line comes before the feeds are stopped and the role returns.
  assert out.index("[FATAL]") < out.index("returned 1")
  # A process that gave up keeps its status row, so `/up` reports the feed
  # once the row is stale (a clean stop deletes it: test/main_roles.rb).
  Cybertrain::DB.connect("#{TMP}/feeds.sqlite3")
  rows = Cybertrain::WebSocket::FeedTable.read_feeds
  assert_equal 1, rows.size
  assert_equal "crashy", Cybertrain::Cast.str(rows[0]["name"])
  Cybertrain::DB.disconnect
end

Cybertrain::Test.run!
