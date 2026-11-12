require "stringio"
require "cybertrain/test"
require "cybertrain/controller"
require "cybertrain/router"
require "cybertrain/middleware/session_store"
require "cybertrain/test/client"

# Controller.rate_limit and Cybertrain::RateLimit (issue #70), through
# Cybertrain::Test::Client: the per-process counter of `store: :memory`
# (the first controllers), then the default store, counts kept in
# Cybertrain::Cache in fixed windows aligned to the epoch (plan decision
# 17), with by:, with:, if:/unless: and name:. The controllers write by
# hand the rate_limit_key / rate_limit_condition? / run_callback tables
# `spin run gen` writes for an application. cybertrain/controller pulls in
# the SQLite FFI bindings, so the snapshot comes from the compiled binary
# (script/regen-snapshot, spikes/NOTES.md rule 23).

Cybertrain.logger = Cybertrain::Logger.new(StringIO.new)

# Each test sets the clock with travel_to (both stores read
# Cybertrain::Clock); the harness travels back after each test.
Cybertrain::DB.connect(":memory:")

class LoginsController < Cybertrain::Controller
  rate_limit to: 3, within: 60, only: [:create], store: :memory

  def new_action
    render plain: "form"
  end

  def create
    render plain: "signed in"
  end
end

class GuardedController < Cybertrain::Controller
  rate_limit to: 2, within: 60, only: [:create], redirect_to: "/guarded", alert: "Try again later.", store: :memory

  def show
    render plain: "alert=#{flash[:alert]}"
  end

  def create
    render plain: "created"
  end
end

class PeerController < Cybertrain::Controller
  rate_limit to: 1, within: 60, by: :remote_addr, store: :memory

  def create
    render plain: "peer ok"
  end
end

# A limit declared in a parent counts each subclass apart.
class LimitedBase < Cybertrain::Controller
  rate_limit to: 1, within: 60, store: :memory
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

# The default store: counts in Cybertrain::Cache.
class CountedController < Cybertrain::Controller
  rate_limit to: 3, within: 60, only: [:create]

  def create
    render plain: "counted"
  end
end

# Counted by a method's value: one bucket per user, whatever the address.
class AccountsController < Cybertrain::Controller
  rate_limit to: 2, within: 60, by: :user_key

  def create
    render plain: "ok #{user_key}"
  end

  def user_key
    params[:user].to_s
  end

  def rate_limit_key(name)
    case name
    when :user_key then user_key.to_s
    else super
    end
  end
end

# with: answers for the exhausted client instead of the 429.
class SlowController < Cybertrain::Controller
  rate_limit to: 1, within: 60, with: :slow_down

  def create
    render plain: "made"
  end

  def slow_down
    render plain: "slow down", status: :too_many_requests
  end

  def run_callback(name)
    case name
    when :slow_down then slow_down
    else super
    end
  end
end

# A with: method that renders nothing: the 429 follows, the action never runs.
class QuietController < Cybertrain::Controller
  rate_limit to: 1, within: 60, with: :note_refusal

  def create
    render plain: "quiet"
  end

  def note_refusal
    response.set_header("X-Refused", "1")
  end

  def run_callback(name)
    case name
    when :note_refusal then note_refusal
    else super
    end
  end
end

# if: / unless: decide whether the limit applies to a request at all.
class ConditionalController < Cybertrain::Controller
  rate_limit to: 1, within: 60, if: :limited?, unless: :trusted?

  def create
    render plain: "gated"
  end

  def limited?
    params[:limited].to_s == "1"
  end

  def trusted?
    params[:trusted].to_s == "1"
  end

  def rate_limit_condition?(name)
    case name
    when :limited? then !!limited?
    when :trusted? then !!trusted?
    else super
    end
  end
end

# Two limits on one action, told apart by name:.
class BurstController < Cybertrain::Controller
  rate_limit to: 2, within: 10, name: "short"
  rate_limit to: 3, within: 60, name: "long"

  def create
    render plain: "burst"
  end
end

# A cache-store limit declared in a parent counts each subclass apart.
class CountedBase < Cybertrain::Controller
  rate_limit to: 1, within: 60
end

class GammaController < CountedBase
  def create
    render plain: "gamma"
  end
end

class DeltaController < CountedBase
  def create
    render plain: "delta"
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
  router.post("/counted") { |ctx| CountedController.new(ctx).process(:create) { |c| c.create } }
  router.post("/accounts") { |ctx| AccountsController.new(ctx).process(:create) { |c| c.create } }
  router.post("/slow") { |ctx| SlowController.new(ctx).process(:create) { |c| c.create } }
  router.post("/quiet") { |ctx| QuietController.new(ctx).process(:create) { |c| c.create } }
  router.post("/gated") { |ctx| ConditionalController.new(ctx).process(:create) { |c| c.create } }
  router.post("/burst") { |ctx| BurstController.new(ctx).process(:create) { |c| c.create } }
  router.post("/gamma") { |ctx| GammaController.new(ctx).process(:create) { |c| c.create } }
  router.post("/delta") { |ctx| DeltaController.new(ctx).process(:create) { |c| c.create } }
  Cybertrain::SessionStore.new(router, secret: "rate-limit-test-secret")
end

APP = build_app

def fresh_client(at)
  Cybertrain::RateLimit.reset_all!
  travel_to(Time.at(at))
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
  assert_equal 12, Cybertrain::RateLimit.all.length
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

test "a declaration keeps its by:, with:, if:, unless:, name: and store:" do
  all = Cybertrain::RateLimit.all
  assert all[0].memory_store?
  assert_nil all[0].by_method
  assert_nil all[0].with_method
  assert_nil all[0].if_method
  assert_nil all[0].unless_method
  assert_equal "", all[0].limit_name
  refute all[4].memory_store?
  assert_equal :user_key, all[5].by_method
  refute all[5].by_remote_addr?
  assert_equal :slow_down, all[6].with_method
  assert_equal :limited?, all[8].if_method
  assert_equal :trusted?, all[8].unless_method
  assert_equal "short", all[9].limit_name
  assert_equal "long", all[10].limit_name
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
  travel_to(Time.at(1030))
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
  travel_to(Time.at(3059))
  assert_equal 429, client.post("/login").status
  assert_equal "1", client.response.header("Retry-After")
  travel_to(Time.at(3060))
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

test "rate_limit refuses a bad to:, within:, store: or name:" do
  assert_raises("ArgumentError") { LoginsController.rate_limit(to: 0, within: 60) }
  assert_raises("ArgumentError") { LoginsController.rate_limit(to: 1, within: 0) }
  assert_equal "rate_limit store: must be :cache or :memory (got :redis)",
               assert_raises("ArgumentError") { LoginsController.rate_limit(to: 1, within: 60, store: :redis) }
  # A name with a colon could end where another limit's name begins.
  assert_equal "rate_limit name: may not contain \":\" (got \"a:b\")",
               assert_raises("ArgumentError") { CountedController.rate_limit(to: 1, within: 60, name: "a:b") }
  # Two limits of one controller under one name would share a count.
  assert_equal "rate_limit name: \"\" is already taken in CountedController; give each limit of a controller its own name:",
               assert_raises("ArgumentError") { CountedController.rate_limit(to: 1, within: 60) }
  assert_equal "rate_limit name: \"long\" is already taken in BurstController; give each limit of a controller its own name:",
               assert_raises("ArgumentError") { BurstController.rate_limit(to: 1, within: 60, name: "long") }
  # The parent's unnamed limit counts in each subclass too.
  assert_raises("ArgumentError") { GammaController.rate_limit(to: 1, within: 60) }
  assert_equal 12, Cybertrain::RateLimit.all.length
end

test "current_time follows the clock: real time, then a travel" do
  assert Cybertrain::RateLimit.current_time > 1_700_000_000
  travel_to(Time.at(42))
  assert_equal 42, Cybertrain::RateLimit.current_time
  travel_back
  assert Cybertrain::RateLimit.current_time > 1_700_000_000
end

# --- the default store: counts in Cybertrain::Cache -------------------------

# The rate-limit rows the cache holds, by key.
def counted_rows
  rows = Cybertrain::DB.with { |c| c.execute("SELECT key FROM cybertrain_cache WHERE key LIKE 'rate-limit:%' ORDER BY key") }
  keys = Array.new(0) { "" }
  rows.each { |r| keys << r["key"].to_s }
  keys
end

test "Retry-After is the rest of the aligned window" do
  client = fresh_client(1000)
  3.times { assert_equal "counted", client.post("/counted").body }
  res = client.post("/counted")
  assert_response res, :too_many_requests
  assert_equal "Too Many Requests", res.body
  # 1000 is 40 seconds into the window [960, 1020).
  assert_equal "20", res.header("Retry-After")
  travel_to(Time.at(1019))
  assert_equal "1", client.post("/counted").header("Retry-After")
  travel_to(Time.at(1020))
  assert_equal "counted", client.post("/counted").body
end

test "the cache key is rate-limit:<controller_path>:<name>:<key>:<window>" do
  client = fresh_client(1000)
  client.post("/counted")
  client.post("/burst")
  assert_equal ["rate-limit:burst:long:127.0.0.1:16", "rate-limit:burst:short:127.0.0.1:100", "rate-limit:counted::127.0.0.1:16"],
               counted_rows
end

test "store: :memory keeps the per-process counter" do
  client = fresh_client(1000)
  4.times { client.post("/login") }
  assert_equal 429, client.response.status
  assert_equal [], counted_rows
  assert Cybertrain::RateLimit.all[0].tracked?("logins::127.0.0.1")
end

test "reset_all! forgets the counts in the cache too" do
  client = fresh_client(1000)
  client.post("/counted")
  assert_equal 1, counted_rows.length
  Cybertrain::RateLimit.reset_all!
  assert_equal [], counted_rows
end

test "by: a method keys the count by its value" do
  client = fresh_client(1000)
  assert_equal "ok ann", client.post("/accounts", { "user" => "ann" }).body
  assert_equal "ok ann", client.post("/accounts", { "user" => "ann" }).body
  assert_equal 429, client.post("/accounts", { "user" => "ann" }).status
  assert_equal "ok bob", client.post("/accounts", { "user" => "bob" }).body
  assert_equal "ok bob", client.post("/accounts", { "user" => "bob" }).body
  assert_equal 429, client.post("/accounts", { "user" => "bob" }).status
end

test "by: a method that answers an empty key is an error, not one bucket for everyone" do
  client = fresh_client(1000)
  msg = assert_raises("ArgumentError") { client.post("/accounts") }
  assert_equal "rate_limit by: :user_key answered an empty key in AccountsController, which would count every client together", msg
  assert_equal [], counted_rows
end

test "with: answers instead of 429" do
  client = fresh_client(1000)
  assert_equal "made", client.post("/slow").body
  res = client.post("/slow")
  assert_equal 429, res.status
  assert_equal "slow down", res.body
  assert_nil res.header("Retry-After")
end

test "a with: method that renders nothing is followed by the 429" do
  client = fresh_client(1000)
  assert_equal "quiet", client.post("/quiet").body
  res = client.post("/quiet")
  assert_equal 429, res.status
  assert_equal "Too Many Requests", res.body
  assert_equal "1", res.header("X-Refused")
end

test "if: false skips the limit; unless: true skips it" do
  client = fresh_client(1000)
  3.times { assert_equal "gated", client.post("/gated", { "limited" => "0" }).body }
  3.times { assert_equal "gated", client.post("/gated", { "limited" => "1", "trusted" => "1" }).body }
  assert_equal [], counted_rows
  assert_equal "gated", client.post("/gated", { "limited" => "1" }).body
  assert_equal 429, client.post("/gated", { "limited" => "1" }).status
end

test "two limits with name: on one action count apart" do
  client = fresh_client(1000)
  assert_equal "burst", client.post("/burst").body
  assert_equal "burst", client.post("/burst").body
  res = client.post("/burst")
  assert_equal 429, res.status
  assert_equal "10", res.header("Retry-After")
  # A new short window; the long one has counted two of its three.
  travel_to(Time.at(1012))
  assert_equal "burst", client.post("/burst").body
  res = client.post("/burst")
  assert_equal 429, res.status
  assert_equal "8", res.header("Retry-After")
end

test "a cache-store limit inherited from a parent counts each controller apart" do
  client = fresh_client(1000)
  assert_equal "gamma", client.post("/gamma").body
  assert_equal "delta", client.post("/delta").body
  assert_equal 429, client.post("/gamma").status
  assert_equal 429, client.post("/delta").status
end

Cybertrain::Test.run!
