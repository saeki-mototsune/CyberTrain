require "stringio"
require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/router"
require "cybertrain/middleware/session_store"
require "cybertrain/test/client"

# Controller.rate_limit and Cybertrain::RateLimit (issue #70), through
# Cybertrain::Test::Client. cybertrain/controller pulls in the SQLite FFI
# bindings, so the snapshot comes from the compiled binary
# (script/regen-snapshot, spikes/NOTES.md rule 23).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

class LoginsController < Cybertrain::Controller
  rate_limit to: 3, within: 60, only: [:create]

  def new_action
    render plain: "form"
  end

  def create
    render plain: "signed in"
  end
end

class GuardedController < Cybertrain::Controller
  rate_limit to: 2, within: 60, only: [:create], redirect_to: "/guarded", alert: "Try again later."

  def show
    render plain: "alert=#{flash[:alert]}"
  end

  def create
    render plain: "created"
  end
end

class PeerController < Cybertrain::Controller
  rate_limit to: 1, within: 60, by: :remote_addr

  def create
    render plain: "peer ok"
  end
end

# A limit declared in a parent counts each subclass apart.
class LimitedBase < Cybertrain::Controller
  rate_limit to: 1, within: 60
end

class AlphaController < LimitedBase
  def create
    render plain: "alpha"
  end
end

class BetaController < LimitedBase
  def create
    render plain: "beta"
  end
end

def build_app
  router = Cybertrain::Router.new
  router.get("/login") { |ctx| LoginsController.new(ctx).process(:new) { |c| c.new_action } }
  router.post("/login") { |ctx| LoginsController.new(ctx).process(:create) { |c| c.create } }
  router.get("/guarded") { |ctx| GuardedController.new(ctx).process(:show) { |c| c.show } }
  router.post("/guarded") { |ctx| GuardedController.new(ctx).process(:create) { |c| c.create } }
  router.post("/peer") { |ctx| PeerController.new(ctx).process(:create) { |c| c.create } }
  router.post("/alpha") { |ctx| AlphaController.new(ctx).process(:create) { |c| c.create } }
  router.post("/beta") { |ctx| BetaController.new(ctx).process(:create) { |c| c.create } }
  Cybertrain::SessionStore.new(router, secret: "rate-limit-test-secret")
end

APP = build_app

def fresh_client(at)
  Cybertrain::RateLimit.reset_all!
  Cybertrain::RateLimit.current_time = at
  Cybertrain::Request.trusted_proxy = false
  Cybertrain::Test::Client.new(APP)
end

def forwarded(addr)
  { "X-Forwarded-For" => addr }
end

# Distinct keys into one limiter, in a method (a loop with a block-local
# counter inside a test block is NOTES rule 68's shape).
def fill(lim, n, at)
  i = 0
  while i < n
    lim.hit("k#{i}", at)
    i += 1
  end
  nil
end

test "rate_limit declarations are registered in order" do
  assert_equal 4, Cybertrain::RateLimit.all.length
  first = Cybertrain::RateLimit.all[0]
  assert_equal 3, first.limit_count
  assert_equal 60, first.period_seconds
  assert_equal "", first.redirect_path
  refute first.by_remote_addr?
  assert Cybertrain::RateLimit.all[2].by_remote_addr?
  assert_equal "/guarded", Cybertrain::RateLimit.all[1].redirect_path
  assert_equal "Try again later.", Cybertrain::RateLimit.all[1].alert_message
  assert_equal 10_000, first.max_keys
end

test "requests under the limit pass; the next is a 429 with Retry-After" do
  client = fresh_client(1000)
  3.times { assert_equal "signed in", client.post("/login").body }
  res = client.post("/login")
  assert_response res, :too_many_requests
  assert_equal 429, res.status
  assert_equal "Too Many Requests", res.body
  assert_equal "60", res.header("Retry-After")
  assert_equal "text/plain; charset=utf-8", res.header("Content-Type")
  Cybertrain::RateLimit.current_time = 1030
  res = client.post("/login")
  assert_equal 429, res.status
  assert_equal "30", res.header("Retry-After")
end

test "only: leaves the other actions alone" do
  client = fresh_client(2000)
  4.times { client.post("/login") }
  assert_equal 429, client.response.status
  res = client.get("/login")
  assert_response res, :ok
  assert_equal "form", res.body
end

test "the window closing resets the count" do
  client = fresh_client(3000)
  4.times { client.post("/login") }
  assert_equal 429, client.response.status
  Cybertrain::RateLimit.current_time = 3059
  assert_equal 429, client.post("/login").status
  assert_equal "1", client.response.header("Retry-After")
  Cybertrain::RateLimit.current_time = 3060
  assert_equal "signed in", client.post("/login").body
  assert_equal "signed in", client.post("/login").body
  assert_equal "signed in", client.post("/login").body
  assert_equal 429, client.post("/login").status
end

test "behind a trusted proxy each forwarded address has its own count" do
  client = fresh_client(4000)
  Cybertrain::Request.trusted_proxy = true
  4.times { client.post("/login", {}, forwarded("203.0.113.1")) }
  assert_equal 429, client.response.status
  assert_equal "signed in", client.post("/login", {}, forwarded("203.0.113.2")).body
  # The client cannot pick its own address: only the last hop counts.
  assert_equal 429, client.post("/login", {}, forwarded("198.51.100.7, 203.0.113.1")).status
  # The proxy's own requests (no header) are one more address.
  assert_equal "signed in", client.post("/login").body
  Cybertrain::Request.trusted_proxy = false
end

test "without a trusted proxy X-Forwarded-For is ignored" do
  client = fresh_client(5000)
  3.times { |i| client.post("/login", {}, forwarded("203.0.113.#{i + 1}")) }
  assert_equal 429, client.post("/login", {}, forwarded("203.0.113.9")).status
end

test "by: :remote_addr counts the peer even behind a trusted proxy" do
  client = fresh_client(6000)
  Cybertrain::Request.trusted_proxy = true
  assert_equal "peer ok", client.post("/peer", {}, forwarded("203.0.113.1")).body
  assert_equal 429, client.post("/peer", {}, forwarded("203.0.113.2")).status
  Cybertrain::Request.trusted_proxy = false
end

test "redirect_to: answers a 303 with the alert in the flash" do
  client = fresh_client(7000)
  assert_equal "created", client.post("/guarded").body
  assert_equal "created", client.post("/guarded").body
  res = client.post("/guarded")
  assert_response res, :see_other
  assert_equal "/guarded", res.header("Location")
  assert_nil res.header("Retry-After")
  client.follow_redirect!
  assert_equal "alert=Try again later.", client.response.body
end

test "a limit inherited from a parent counts each controller apart" do
  client = fresh_client(8000)
  assert_equal "alpha", client.post("/alpha").body
  assert_equal "beta", client.post("/beta").body
  assert_equal 429, client.post("/alpha").status
  assert_equal 429, client.post("/beta").status
end

test "hit answers 0 while allowed and the seconds left once exhausted" do
  lim = Cybertrain::RateLimit.new(2, 10, false, "", "")
  assert_equal 0, lim.hit("a", 100)
  assert_equal 0, lim.hit("a", 104)
  assert_equal 6, lim.hit("a", 104)
  assert_equal 1, lim.hit("a", 109)
  assert_equal 0, lim.hit("a", 110)
  assert_equal 0, lim.hit("b", 110)
  assert_equal 2, lim.tracked_keys
  lim.reset!
  assert_equal 0, lim.tracked_keys
  refute lim.tracked?("a")
end

test "a full table drops the oldest windows first" do
  lim = Cybertrain::RateLimit.new(5, 10, false, "", "")
  lim.max_keys = 4
  lim.hit("a", 0)
  lim.hit("b", 1)
  lim.hit("c", 2)
  lim.hit("d", 3)
  lim.hit("e", 4)
  assert_equal 4, lim.tracked_keys
  refute lim.tracked?("a")
  assert lim.tracked?("b")
  assert lim.tracked?("e")
end

test "a full table drops every expired window before an open one" do
  lim = Cybertrain::RateLimit.new(5, 10, false, "", "")
  lim.max_keys = 4
  lim.hit("a", 0)
  lim.hit("b", 1)
  lim.hit("c", 20)
  lim.hit("d", 21)
  lim.hit("e", 22)
  assert_equal 3, lim.tracked_keys
  refute lim.tracked?("a")
  refute lim.tracked?("b")
  assert lim.tracked?("c")
  assert lim.tracked?("d")
end

test "a window that reopens moves its key to the back of the table" do
  lim = Cybertrain::RateLimit.new(5, 10, false, "", "")
  lim.max_keys = 4
  lim.hit("a", 0)
  lim.hit("b", 5)
  lim.hit("a", 11)
  lim.hit("c", 12)
  lim.hit("d", 13)
  lim.hit("e", 14)
  assert lim.tracked?("a")
  refute lim.tracked?("b")
  assert_equal 4, lim.tracked_keys
end

test "the table never holds more than max_keys keys" do
  lim = Cybertrain::RateLimit.new(5, 600, false, "", "")
  fill(lim, 10_050, 50)
  assert lim.tracked_keys <= 10_000
  assert lim.tracked_keys > 9_000
  assert lim.tracked?("k10049")
  refute lim.tracked?("k0")
  lim.max_keys = 0
  assert_equal 1, lim.max_keys
end

test "rate_limit refuses a bad to:, within: or by:" do
  assert_raises("ArgumentError") { LoginsController.rate_limit(to: 0, within: 60) }
  assert_raises("ArgumentError") { LoginsController.rate_limit(to: 1, within: 0) }
  assert_raises("ArgumentError") { LoginsController.rate_limit(to: 1, within: 60, by: :session) }
  assert_equal 4, Cybertrain::RateLimit.all.length
end

test "current_time follows the system clock once unfixed" do
  Cybertrain::RateLimit.current_time = -1
  assert Cybertrain::RateLimit.current_time > 1_700_000_000
  Cybertrain::RateLimit.current_time = 42
  assert_equal 42, Cybertrain::RateLimit.current_time
  Cybertrain::RateLimit.current_time = -1
end

Cybertrain::Test.run!
