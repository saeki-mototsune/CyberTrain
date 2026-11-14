require "json"
require "cybertrain"
require "cybertrain/test_help"
require_relative "support/log_capture"

# Cybertrain.error (spec sections 13.1, 13.3 and 13.4's queue, dedupe and
# shutdown; plan D9, D11, D12): report, handle and subscribe, the event of
# Strings built on the caller's thread, and its delivery on the reporter's
# own thread. Compiled only (`spin test test/error_reporter.rb`): its
# `require "cybertrain"` links SQLite and zlib through Spinel's FFI, which
# CRuby cannot load. Restores go through plain helpers' `ensure`
# (pre-flight ruling G4).

NOON = Time.utc(2026, 11, 11, 12)

def no_context
  h = { "" => "" }
  h.delete("")
  h
end

# The events a Collect (or a Blocking, once released) received, in order.
EVENTS = Array.new(0) { Cybertrain::ErrorEvent.new("", "", "", "", "", "", "", "", false, no_context, Array.new(0) { "" }, Time.at(0).utc) }
# What the subscriber added at boot (before the first test) received.
BOOT_SEEN = Array.new(0) { "" }
# Blocking's handshake: it says it started, then waits to be released.
STARTED = Queue.new
RELEASE = Queue.new

class Collect < Cybertrain::ErrorSubscriber
  def report(event)
    EVENTS << event
    nil
  end
end

class Raising < Cybertrain::ErrorSubscriber
  def report(event)
    raise "subscriber bug"
  end
end

class Blocking < Cybertrain::ErrorSubscriber
  def report(event)
    STARTED << "started"
    RELEASE.pop(timeout: 10)
    EVENTS << event
    nil
  end
end

# Subscribers that raise outside StandardError: the delivery thread must
# survive them (a stub not yet written, a recursion too deep).
class NotWritten < Cybertrain::ErrorSubscriber
  def report(event)
    raise NotImplementedError, "todo"
  end
end

class TooDeep < Cybertrain::ErrorSubscriber
  def report(event)
    raise SystemStackError, "stack level too deep"
  end
end

# A sender that sends and raises while sending.
class RaisingSender < Cybertrain::ErrorReporter::Sender
  def sends?
    true
  end

  def deliver_event(event)
    raise "send bug"
  end
end

# A sender whose sends? itself raises.
class UnsureSender < Cybertrain::ErrorReporter::Sender
  def sends?
    raise ArgumentError, "unsure"
  end
end

# A context value whose to_s raises.
class BadText
  def to_s
    raise "to_s bug"
  end
end

class BootSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    BOOT_SEEN << event.error_message
    nil
  end
end

# Added before the first test, as config/app.rb would: kept by every reset
# (pre-flight ruling B8).
Cybertrain.error.subscribe(BootSubscriber.new)

# Reports a RuntimeError with `message`, rescued here.
def report_runtime(message)
  raise message
rescue RuntimeError => e
  Cybertrain.error.report(e)
end

# Runs the block with config.env "test" (pre-flight ruling G8) and the
# release `release`, both restored after it.
def as_test_env(release)
  saved_env = Cybertrain.config.env
  saved_release = Cybertrain.config.release
  Cybertrain.config.env = "test"
  Cybertrain.config.release = release
  _value = yield
  nil
ensure
  Cybertrain.config.env = saved_env
  Cybertrain.config.release = saved_release
end

def raise_argument(message)
  raise ArgumentError, message
end

# Reports `e` with a context that cannot be read, then raises `e` again:
# the caller's exception must come out, not the reporter's.
def report_then_reraise
  raise ArgumentError, "original"
rescue ArgumentError => e
  Cybertrain.error.report(e, context: { "k" => BadText.new })
  raise e
end

# handle called through a forwarding block (ruling S5).
def handle_forwarded
  Cybertrain.error.handle { yield }
end

# `break` in handle's block ends handle with the break's value; `return`
# returns from the method around it (as under CRuby; ruling S5).
def handle_break
  v = Cybertrain.error.handle { break "broke" }
  "after break: #{v}"
end

def handle_return
  Cybertrain.error.handle { return "returned from the method" }
  "fell through"
end

setup do
  EVENTS.clear
  BOOT_SEEN.clear
  STARTED.clear
  RELEASE.clear
end

test "report records an exception the application rescued, with the request's fields" do
  Cybertrain.error.subscribe(Collect.new)
  scope = Cybertrain::Logger::Scope.new("r-1", "POST", "/orders", "OrdersController#create", ["r-1"], 0, no_context)
  answered = "unset"
  as_test_env("abc123") do
    with_scope(scope) do
      travel_to(NOON) do
        begin
          raise ArgumentError, "bad"
        rescue ArgumentError => e
          answered = Cybertrain.error.report(e, context: { "order_id" => 7 }).inspect
        end
      end
    end
  end
  assert_equal "nil", answered
  assert Cybertrain.error.drain_reports(2.0)
  assert_equal 1, EVENTS.size
  ev = EVENTS.last
  assert_equal ["ArgumentError", "bad", "OrdersController#create", "r-1", "POST", "/orders", "test", "abc123"],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id, ev.error_request_method,
                ev.error_request_path, ev.error_environment, ev.error_release]
  assert_equal true, ev.error_handled
  assert_equal({ "order_id" => "7" }, ev.error_context)
  assert_equal NOON, ev.error_occurred_at
end

test "outside a request the request fields and where are empty" do
  Cybertrain.error.subscribe(Collect.new)
  report_runtime("outside")
  Cybertrain.error.drain_reports(2.0)
  ev = EVENTS.last
  assert_equal ["RuntimeError", "outside", "", "", "", "", "development", ""],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id, ev.error_request_method,
                ev.error_request_path, ev.error_environment, ev.error_release]
  assert_equal({}, ev.error_context)
end

test "context keys and values become Strings, merged over the Scope's context" do
  Cybertrain.error.subscribe(Collect.new)
  scoped = { "job.id" => "5", "order_id" => "from the scope" }
  scope = Cybertrain::Logger::Scope.new("", "", "", "WelcomeJob", Array.new(0) { "" }, -1, scoped)
  with_scope(scope) do
    begin
      raise_argument("symbols")
    rescue ArgumentError => e
      Cybertrain.error.report(e, handled: false, context: { order_id: 7 })
    end
  end
  Cybertrain.error.drain_reports(2.0)
  ev = EVENTS.last
  assert_equal false, ev.error_handled
  assert_equal "WelcomeJob", ev.error_where
  assert_equal({ "job.id" => "5", "order_id" => "7" }, ev.error_context)
  assert_equal({ "job.id" => "5", "order_id" => "from the scope" }, scope.scope_context)
end

test "an event keeps the context it was reported with, whatever the caller changes after" do
  Cybertrain.error.subscribe(Collect.new)
  key = +"note"
  value = +"before"
  unhandled_value = +"unhandled before"
  scoped_value = +"scope before"
  scoped = { "from" => scoped_value }
  scope = Cybertrain::Logger::Scope.new("", "", "", "WelcomeJob", Array.new(0) { "" }, -1, scoped)
  unhandled = { "u" => unhandled_value }
  with_scope(scope) do
    begin
      raise_argument("copied")
    rescue ArgumentError => e
      Cybertrain.error.report(e, context: { key => value })
      Cybertrain.error.report_unhandled(e, "copied:unhandled", unhandled)
    end
  end
  key << "d"
  value << " after"
  unhandled_value << " after"
  scoped_value << " after"
  Cybertrain.error.drain_reports(2.0)
  assert_equal 2, EVENTS.size
  assert_equal({ "from" => "scope before", "note" => "before" }, EVENTS[0].error_context)
  assert_equal({ "from" => "scope before", "u" => "unhandled before" }, EVENTS[1].error_context)
end

test "handle answers the block's value, or nil after reporting what it raised" do
  Cybertrain.error.subscribe(Collect.new)
  assert_equal "ok", Cybertrain.error.handle { "ok" }
  assert_equal 3, Cybertrain.error.handle { 3 }
  assert_nil Cybertrain.error.handle { nil }
  assert_nil Cybertrain.error.handle(context: { "feed" => "prices" }) { raise "parse" }
  assert_nil Cybertrain.error.handle { JSON.parse("{") }
  Cybertrain.error.drain_reports(2.0)
  assert_equal [["RuntimeError", "true", "feed=prices"], ["JSON::ParserError", "true", ""]],
               EVENTS.last(2).map { |e| [e.error_class, e.error_handled.to_s, e.error_context.map { |k, v| "#{k}=#{v}" }.join(",")] }
end

test "handle through a forwarding block, with next, and nested in blocks" do
  Cybertrain.error.subscribe(Collect.new)
  assert_equal "forwarded", handle_forwarded { "forwarded" }
  assert_nil handle_forwarded { raise_argument("forwarded raise") }
  assert_equal 5, Cybertrain.error.handle { next 5 }
  assert_equal "after break: broke", handle_break
  assert_equal "returned from the method", handle_return
  out = Array.new(0) { "" }
  [1].each do |i|
    [2].each do |j|
      a = Cybertrain.error.handle { "nested #{i} #{j}" }
      b = Cybertrain.error.handle { raise_argument("nested raise") }
      out << "#{a} #{b.inspect}"
    end
  end
  assert_equal ["nested 1 2 nil"], out
  Cybertrain.error.drain_reports(2.0)
  assert_equal ["forwarded raise", "nested raise"], EVENTS.map(&:error_message)
end

test "report_unhandled and report_message" do
  Cybertrain.error.subscribe(Collect.new)
  scope = Cybertrain::Logger::Scope.new("r-2", "GET", "/x", "PagesController#show", Array.new(0) { "" }, -1, no_context)
  ctx = { "job.attempt" => "2" }
  with_scope(scope) do
    begin
      raise_argument("unhandled")
    rescue ArgumentError => e
      assert_nil Cybertrain.error.report_unhandled(e, "", ctx)
      assert_nil Cybertrain.error.report_unhandled(e, "schedule:nightly", Cybertrain::ErrorReporter::NO_CONTEXT)
    end
    assert_nil Cybertrain.error.report_message("Cybertrain::Background::FeedFailed", "feed prices gave up", "feed:prices",
                                               Cybertrain::ErrorReporter::NO_CONTEXT)
  end
  Cybertrain.error.drain_reports(2.0)
  assert_equal ["PagesController#show", "schedule:nightly", "feed:prices"], EVENTS.map(&:error_where)
  assert_equal [false, false, false], EVENTS.map(&:error_handled)
  assert_equal({ "job.attempt" => "2" }, EVENTS[0].error_context)
  ev = EVENTS.last
  assert_equal ["Cybertrain::Background::FeedFailed", "feed prices gave up", "r-2"],
               [ev.error_class, ev.error_message, ev.error_request_id]
  assert_equal [], ev.error_backtrace
  assert_equal({}, Cybertrain::ErrorReporter::NO_CONTEXT)
end

test "a raising subscriber is logged, the others still receive, nothing is reported for it" do
  Cybertrain.error.subscribe(Raising.new)
  Cybertrain.error.subscribe(Collect.new)
  log = capture_log do
    report_runtime("x")
    Cybertrain.error.drain_reports(2.0)
  end
  assert_logged log, "ERROR", "error subscriber Raising failed: RuntimeError: subscriber bug\n"
  assert_equal 1, EVENTS.size
  assert_equal ["x"], BOOT_SEEN
end

test "the same class, message and where is queued once a minute" do
  Cybertrain.error.subscribe(Collect.new)
  freeze_time
  2.times { report_runtime("same") }
  report_runtime("other")
  travel 61
  report_runtime("same")
  Cybertrain.error.drain_reports(2.0)
  assert_equal ["same", "other", "same"], EVENTS.map(&:error_message)
end

test "reports in one test are not deduplicated against the previous test's" do
  Cybertrain.error.subscribe(Collect.new)
  report_runtime("same")
  Cybertrain.error.drain_reports(2.0)
  assert_equal ["same"], EVENTS.map(&:error_message)
end

test "a subscriber added in a test is gone in the next; the one added at boot stays" do
  report_runtime("after")
  Cybertrain.error.drain_reports(2.0)
  assert_equal 0, EVENTS.size
  assert_equal ["after"], BOOT_SEEN
end

test "a full queue drops and counts, logged at most once a minute" do
  Cybertrain.error.subscribe(Blocking.new)
  freeze_time
  report_runtime("e0")
  STARTED.pop(timeout: 5)
  (1..104).each { |i| report_runtime("e#{i}") }
  assert_equal 4, Cybertrain.error.dropped_count
  log = capture_log do
    101.times { RELEASE << "go" }
    Cybertrain.error.drain_reports(5.0)
  end
  assert_equal 1, LogCapture.count(log, "WARN", "error reports dropped: 4\n")
  assert_equal 0, Cybertrain.error.dropped_count
  assert_equal 101, EVENTS.size
  # A second burst within the minute is counted, not logged yet ...
  STARTED.clear
  RELEASE.clear
  report_runtime("f0")
  STARTED.pop(timeout: 5)
  (1..102).each { |i| report_runtime("f#{i}") }
  log = capture_log do
    101.times { RELEASE << "go" }
    Cybertrain.error.drain_reports(5.0)
  end
  assert_equal 0, LogCapture.count(log, "WARN", "error reports dropped:")
  assert_equal 2, Cybertrain.error.dropped_count
  # ... and logged once the minute has passed: the travel inside the
  # capture, so that a delivery step the travel lets log the count logs it
  # into this capture.
  log = capture_log do
    travel 61
    RELEASE << "go"
    report_runtime("g")
    Cybertrain.error.drain_reports(5.0)
  end
  assert_equal 1, LogCapture.count(log, "WARN", "error reports dropped: 2\n")
  assert_equal 203, EVENTS.size
end

test "drain_reports answers false while an event is still in flight" do
  Cybertrain.error.subscribe(Blocking.new)
  report_runtime("slow")
  STARTED.pop(timeout: 5)
  assert_equal false, Cybertrain.error.drain_reports(0.05)
  RELEASE << "go"
  assert_equal true, Cybertrain.error.drain_reports(2.0)
  assert_equal ["slow"], EVENTS.map(&:error_message)
end

test "a reset whose drain runs out logs what was left and discards the queued events" do
  Cybertrain.error.subscribe(Blocking.new)
  report_runtime("stuck")
  STARTED.pop(timeout: 5)
  report_runtime("queued 1")
  report_runtime("queued 2")
  log = capture_log { Cybertrain.error.reset!(0.05) }
  assert_logged log, "WARN", "error reports undelivered at reset: 3 (2 discarded)\n"
  RELEASE << "go"
  assert_equal true, Cybertrain.error.drain_reports(2.0)
  Cybertrain.error.subscribe(Collect.new)
  report_runtime("after the reset")
  assert_equal true, Cybertrain.error.drain_reports(2.0)
  assert_equal ["stuck", "after the reset"], EVENTS.map(&:error_message)
  log = capture_log { Cybertrain.error.reset!(0.05) }
  assert_equal 0, LogCapture.count(log, "WARN", "error reports undelivered")
end

test "with no subscriber and no sender nothing is queued and no thread starts" do
  reporter = Cybertrain::ErrorReporter.new
  assert_equal false, reporter.sender.sends?
  begin
    raise "nobody listens"
  rescue RuntimeError => e
    assert_nil reporter.report(e)
  end
  assert_equal false, reporter.delivery_started?
  assert reporter.drain_reports(0.1)
  listened = Cybertrain::ErrorReporter.new
  listened.subscribe(Collect.new)
  begin
    raise "somebody listens"
  rescue RuntimeError => e
    listened.report(e)
  end
  assert_equal true, listened.delivery_started?
  assert listened.drain_reports(2.0)
  assert_equal ["somebody listens"], EVENTS.map(&:error_message)
end

test "a subscriber raising outside StandardError is logged and the thread goes on" do
  Cybertrain.error.subscribe(NotWritten.new)
  Cybertrain.error.subscribe(TooDeep.new)
  Cybertrain.error.subscribe(Collect.new)
  log = capture_log do
    report_runtime("first")
    assert_equal true, Cybertrain.error.drain_reports(2.0)
    report_runtime("second")
    assert_equal true, Cybertrain.error.drain_reports(2.0)
  end
  assert_equal ["first", "second"], EVENTS.map(&:error_message)
  assert_equal 2, LogCapture.count(log, "ERROR", "error subscriber NotWritten failed: NotImplementedError: todo\n")
  assert_equal 2, LogCapture.count(log, "ERROR", "error subscriber TooDeep failed: SystemStackError: stack level too deep\n")
end

test "a raising sender is logged at warn, the thread goes on, and reset! puts the boot sender back" do
  Cybertrain.error.subscribe(Collect.new)
  Cybertrain.error.sender = RaisingSender.new
  log = capture_log do
    report_runtime("sent")
    assert_equal true, Cybertrain.error.drain_reports(2.0)
  end
  assert_logged log, "WARN", "error sender RaisingSender failed: RuntimeError: send bug\n"
  Cybertrain.error.sender = UnsureSender.new
  log = capture_log do
    report_runtime("unsure")
    assert_equal true, Cybertrain.error.drain_reports(2.0)
  end
  assert_logged log, "WARN", "error sender UnsureSender failed: ArgumentError: unsure\n"
  assert_equal ["sent", "unsure"], EVENTS.map(&:error_message)
  Cybertrain.error.reset!
  assert_equal "Cybertrain::ErrorReporter::SentrySender", Cybertrain.error.sender.class.name
end

# The boot sender is the Sentry sender: `require "cybertrain"` loads its
# line, which installs it.
test "the sender a test installed is gone in the next" do
  assert_equal "Cybertrain::ErrorReporter::SentrySender", Cybertrain.error.sender.class.name
end

test "report never raises into its caller: a failure is logged and it answers nil" do
  Cybertrain.error.subscribe(Collect.new)
  answered = "unset"
  log = capture_log do
    begin
      raise "unreadable context"
    rescue RuntimeError => e
      answered = Cybertrain.error.report(e, context: { "k" => BadText.new }).inspect
    end
  end
  assert_equal "nil", answered
  assert_logged log, "ERROR", "error report failed: RuntimeError: to_s bug\n"
  handled = "unset"
  bad = ""
  log = capture_log do
    handled = Cybertrain.error.handle(context: { "k" => BadText.new }) { raise "in handle" }.inspect
    bad = assert_raises("ArgumentError") { report_then_reraise }
  end
  assert_equal "nil", handled
  assert_equal "original", bad
  assert_equal 2, LogCapture.count(log, "ERROR", "error report failed: RuntimeError: to_s bug\n")
  report_runtime("still works")
  Cybertrain.error.drain_reports(2.0)
  assert_equal ["still works"], EVENTS.map(&:error_message)
end

test "Cybertrain.error is one ErrorReporter" do
  assert_equal "Cybertrain::ErrorReporter", Cybertrain.error.class.name
  assert Cybertrain.error.equal?(Cybertrain.error)
end

Cybertrain::Test.run!
