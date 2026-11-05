require "tmpdir"
require "stringio"
require "cybertrain/test"
require "cybertrain"
require "cybertrain/websocket"

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

def resolver = ->(name, args) { "/" }

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

test "worker with no job handler and no task boots, waits for the stop and returns 0" do
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
  assert_includes LOG.string, "[INFO] Job threads started: 3"
  assert_includes LOG.string, "[INFO] Scheduler started: hourly every 3600s"
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
  assert_includes LOG.string, "[INFO] WebSocket started: trades"
  refute LOG.string.include?("WebSocket started: quotes")
end

Cybertrain::Test.run!
