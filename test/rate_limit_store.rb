require "stringio"
require "tmpdir"
require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/rate_limit"
require "cybertrain/router"
require "cybertrain/middleware/session_store"
require "cybertrain/test/client"

# A rate_limit's default store keeps its counts in Cybertrain::Cache, so
# two processes on one database count together (plan decision 17). This
# program runs itself again as a child (RATE_LIMIT_CHILD=1), which makes
# two requests to the limited action and exits; then the parent, on the
# same SQLite file, has only the rest of the window's allowance. Both pin
# the cache's clock to one second, so they share a window. Process.spawn
# and Process.wait as spikes/NOTES.md rule 75; the snapshot comes from the
# compiled binary (SQLite through FFI, rule 23).
CHILD_FLAG = "RATE_LIMIT_CHILD"
DB_PATH_VAR = "RATE_LIMIT_DB"

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)
Cybertrain::Cache.clock = -> { 1_000_000 }

class SharedController < Cybertrain::Controller
  rate_limit to: 5, within: 60

  def create
    render plain: "shared"
  end
end

def build_app
  router = Cybertrain::Router.new
  router.post("/shared") { |ctx| SharedController.new(ctx).process(:create) { |c| c.create } }
  Cybertrain::SessionStore.new(router, secret: "rate-limit-store-secret")
end

APP = build_app

if ENV[CHILD_FLAG] == "1"
  Cybertrain::DB.connect(ENV[DB_PATH_VAR].to_s)
  client = Cybertrain::Test::Client.new(APP)
  client.post("/shared")
  client.post("/shared")
  exit(0)
end

DIR = Dir.mktmpdir("cybertrain-rate-limit-store")
DB_PATH = "#{DIR}/shared.sqlite3"
at_exit do
  Dir.children(DIR).each { |f| File.delete("#{DIR}/#{f}") }
  Dir.rmdir(DIR)
end

# Runs the child against DB_PATH and waits for it.
def run_child
  ENV[CHILD_FLAG] = "1"
  ENV[DB_PATH_VAR] = DB_PATH
  pid = 0
  if RUBY_ENGINE == "ruby"
    pid = Process.spawn("ruby", "-I", File.expand_path("..", __dir__), $0)
  else
    pid = Process.spawn(File.expand_path($0))
  end
  ENV.delete(CHILD_FLAG)
  ENV.delete(DB_PATH_VAR)
  Process.wait(pid)
  nil
end

test "the count is shared across two processes" do
  run_child
  Cybertrain::DB.connect(DB_PATH)
  client = Cybertrain::Test::Client.new(APP)
  # The child made 2 of the 5; this process has 3 left.
  3.times { assert_equal "shared", client.post("/shared").body }
  res = client.post("/shared")
  assert_equal 429, res.status
  assert_equal "20", res.header("Retry-After")
end

Cybertrain::Test.run!
