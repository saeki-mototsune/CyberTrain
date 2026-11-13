require "socket"
require "cybertrain/core"
require "cybertrain/error_reporter/sentry"
require "cybertrain/test"
require "cybertrain/test/sentry_receiver"
require_relative "support/log_capture"

# The Sentry sender (spec section 13.4; plan D13, D14) against
# Cybertrain::Test::SentryReceiver: one envelope per event with Sentry's
# auth header, the DSN's path prefix, the sample rate, the frames of a
# backtrace, and a refusing, rate-limiting, silent or blocked Sentry that
# never blocks the caller nor raises. The program is the core plus the
# sender's line alone (the optional-subsystems spec, section 7: the line
# compiles on its own). It links TLS (openssl) and SQLite through FFI, so
# its snapshot comes from the compiled binary (spikes/NOTES.md rule 23).
# Restores go through teardown and plain helpers (pre-flight ruling G4).

NOON = Time.utc(2026, 11, 11, 12)
ORIGINAL_ENV = Cybertrain.config.env

def no_context
  h = { "" => "" }
  h.delete("")
  h
end

# What the Collect subscriber received, in order.
EVENTS = Array.new(0) { "" }

class Collect < Cybertrain::ErrorSubscriber
  def report(event)
    EVENTS << event.error_message
    nil
  end
end

setup do
  Cybertrain.error.reset!
  EVENTS.clear
  Cybertrain.config.env = "test"
end

teardown do
  Cybertrain.config.sentry_dsn = ""
  Cybertrain.config.http_allow_private = false
  Cybertrain.config.release = ""
  Cybertrain.config.error_sample_rate = 1.0
  Cybertrain.config.env = ORIGINAL_ENV
end

# A started receiver, the DSN pointed at it (project `project`, path
# `prefix`), private addresses allowed. The harness stops it after the case.
def sentry_receiver(project, prefix)
  rx = Cybertrain::Test::SentryReceiver.new
  rx.start
  Cybertrain.config.sentry_dsn = rx.dsn(project, prefix)
  Cybertrain.config.http_allow_private = true
  rx
end

def report_runtime(message)
  raise message
rescue RuntimeError => e
  Cybertrain.error.report(e)
end

# Reports "boom" as a request's 500 would: unhandled, inside the request's
# Scope, with a context. Answers the size of the exception's backtrace.
def report_boom
  scope = Cybertrain::Logger::Scope.new("r-1", "GET", "/things/boom", "ThingsController#boom", ["r-1"], 0, no_context)
  context = no_context
  context["order_id"] = "7"
  size = 0
  with_scope(scope) do
    begin
      raise "boom"
    rescue RuntimeError => e
      lines = e.backtrace
      size = lines.nil? ? 0 : lines.size
      Cybertrain.error.report_unhandled(e, "", context)
    end
  end
  size
end

# A free port on 127.0.0.1 that nothing listens on.
def closed_port
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1].to_i
  server.close
  port
end

# The callable that closes `server` after the case (made in a method:
# spikes/NOTES.md rule 82).
def server_closer(server)
  lambda do
    server.close unless server.closed?
    nil
  end
end

# A listener that never answers: the kernel completes the connection, the
# request is written, and nothing ever comes back. Closed after the case
# (pre-flight ruling for Task 10). Answers its port.
def silent_port
  server = TCPServer.new("127.0.0.1", 0)
  Cybertrain::Test.after_this_case(server_closer(server))
  server.addr[1].to_i
end

# Whether `text` is 32 lower-case hex digits, read byte by byte (no
# regexp, pre-flight ruling G5).
def hex32?(text)
  s = text.to_s
  return false unless s.bytesize == 32

  i = 0
  while i < 32
    b = s.getbyte(i).to_i
    return false unless (b >= 48 && b <= 57) || (b >= 97 && b <= 102)

    i += 1
  end
  true
end

def plain_event(message)
  Cybertrain::ErrorEvent.new("RuntimeError", message, "", "", "", "", "test", "", true, no_context,
                             Array.new(0) { "" }, NOON)
end

test "one envelope per event, with Sentry's auth header" do
  receiver = sentry_receiver("42", "")
  Cybertrain.config.release = "abc123"
  travel_to(NOON)
  trace_size = report_boom
  env = receiver.received_events(1)[0]
  assert_equal "/api/42/envelope/", env.sentry_path
  assert_equal "Sentry sentry_version=7, sentry_key=public, sentry_client=cybertrain/#{Cybertrain::VERSION}", env.sentry_auth
  assert_equal "application/x-sentry-envelope", env.sentry_content_type
  id = env.sentry_field("event_id")
  assert hex32?(id), "event_id #{id.inspect}"
  assert_equal id, env.sentry_header_field("event_id")
  assert_equal receiver.dsn("42", ""), env.sentry_header_field("dsn")
  assert_equal "2026-11-11T12:00:00.000Z", env.sentry_header_field("sent_at")
  {
    "timestamp" => "2026-11-11T12:00:00.000Z", "platform" => "ruby", "level" => "error", "environment" => "test",
    "release" => "abc123", "transaction" => "ThingsController#boom", "exception.values.0.type" => "RuntimeError",
    "exception.values.0.value" => "boom", "exception.values.0.mechanism.handled" => "false",
    "tags.request_id" => "r-1", "request.method" => "GET", "request.url" => "/things/boom", "extra.order_id" => "7"
  }.each { |k, v| assert_equal v, env.sentry_field(k) }
  assert_equal "", env.sentry_field("exception.values.1.type")
  assert_equal "", env.sentry_field("no.such.field")
  # The frames: present exactly when the exception had a backtrace (CRuby,
  # a --debug build); a release build has none (spikes/NOTES.md rule 107).
  frame = env.sentry_field("exception.values.0.stacktrace.frames.0.filename")
  assert_equal trace_size > 0, !frame.empty?
end

test "an event outside a request has no tags, request, transaction or release" do
  receiver = sentry_receiver("5", "")
  report_runtime("plain")
  env = receiver.received_events(1)[0]
  assert_equal "plain", env.sentry_field("exception.values.0.value")
  assert_equal "true", env.sentry_field("exception.values.0.mechanism.handled")
  assert_equal "", env.sentry_field("tags.request_id")
  assert_equal "", env.sentry_field("request.method")
  assert_equal "", env.sentry_field("transaction")
  assert_equal "", env.sentry_field("release")
end

test "a DSN with a path prefix" do
  receiver = sentry_receiver("7", "/sentry")
  report_runtime("x")
  assert_equal "/sentry/api/7/envelope/", receiver.received_events(1)[0].sentry_path
end

test "the sample rate thins what is sent, never what subscribers see" do
  assert Cybertrain::ErrorReporter::SentrySender.sampled?(0.25, 0.24)
  refute Cybertrain::ErrorReporter::SentrySender.sampled?(0.25, 0.25)
  refute Cybertrain::ErrorReporter::SentrySender.sampled?(0.0, 0.0)
  assert Cybertrain::ErrorReporter::SentrySender.sampled?(1.0, 0.999)
  draw = Cybertrain::ErrorReporter::SentrySender.sample_draw
  assert draw >= 0.0 && draw < 1.0
  receiver = sentry_receiver("8", "")
  Cybertrain.error.subscribe(Collect.new)
  Cybertrain.config.error_sample_rate = 0.0
  report_runtime("unsent")
  assert Cybertrain.error.drain_reports(2.0)
  assert_equal 0, receiver.received_count
  assert_equal ["unsent"], EVENTS
end

test "frames, oldest first, when the build has a backtrace" do
  assert_equal %([{"filename":"x.rb","lineno":1,"function":"<main>"},{"filename":"app/models/a.rb","lineno":3,"function":"A#b"}]),
               Cybertrain::ErrorReporter::SentrySender.frames_json(["app/models/a.rb:3:in 'A#b'", "x.rb:1:in `<main>'"])
  assert_equal %([{"filename":"weird"}]), Cybertrain::ErrorReporter::SentrySender.frames_json(["weird"])
  assert_equal %([{"filename":"a.rb:x:in 'm'"},{"filename":"a.rb:3:in m"}]),
               Cybertrain::ErrorReporter::SentrySender.frames_json(["a.rb:3:in m", "a.rb:x:in 'm'"])
  assert_equal "[]", Cybertrain::ErrorReporter::SentrySender.frames_json(Array.new(0) { "" })
end

test "the sender answers whether Sentry took the event; a refusing Sentry is a warn line" do
  receiver = sentry_receiver("9", "")
  sender = Cybertrain::ErrorReporter::SentrySender.new
  assert_equal "sentry", sender.sender_name
  assert sender.sends?
  assert_equal true, sender.deliver_event(plain_event("taken"))
  assert_equal "taken", receiver.received_events(1)[0].sentry_field("exception.values.0.value")
  limited = Cybertrain::Test::SentryReceiver.new(status: 429)
  limited.start
  Cybertrain.config.sentry_dsn = limited.dsn("9", "")
  answered = true
  log = capture_log { answered = sender.deliver_event(plain_event("limited")) }
  assert_equal false, answered
  assert_logged log, "WARN", "error report not sent: Sentry answered 429\n"
  Cybertrain.config.sentry_dsn = ""
  refute sender.sends?
  assert_equal false, sender.deliver_event(plain_event("no dsn"))
end

test "a refusing, a blocked and a malformed DSN never block or raise" do
  Cybertrain.config.http_allow_private = true
  Cybertrain.config.sentry_dsn = "http://public@127.0.0.1:#{closed_port}/1"
  log = capture_log do
    started = Cybertrain::Clock.monotonic
    report_runtime("refused")
    assert Cybertrain::Clock.monotonic - started < 0.5
    assert Cybertrain.error.drain_reports(5.0)
  end
  assert_logged log, "WARN", "error report not sent: Cybertrain::HttpClient::RefusedError"
  receiver = sentry_receiver("2", "")
  Cybertrain.config.http_allow_private = false
  log = capture_log do
    report_runtime("blocked")
    assert Cybertrain.error.drain_reports(5.0)
  end
  assert_logged log, "WARN", "error report not sent: Cybertrain::HttpClient::BlockedAddressError"
  assert_equal 0, receiver.received_count
  Cybertrain.config.sentry_dsn = "https://h/1"
  log = capture_log do
    report_runtime("malformed")
    assert Cybertrain.error.drain_reports(5.0)
  end
  assert_logged log, "WARN", "error report not sent: ArgumentError: no public key before the @\n"
end

test "a silent Sentry ends the delivery within the deadline, and the next event goes" do
  Cybertrain.config.http_allow_private = true
  Cybertrain.config.sentry_dsn = "http://public@127.0.0.1:#{silent_port}/3"
  waited = 0.0
  log = capture_log do
    started = Cybertrain::Clock.monotonic
    report_runtime("silent")
    assert Cybertrain::Clock.monotonic - started < 0.5
    assert Cybertrain.error.drain_reports(8.0)
    waited = Cybertrain::Clock.monotonic - started
  end
  assert waited < 5.5, "the delivery took #{waited} s"
  assert_logged log, "WARN", "error report not sent: Cybertrain::HttpClient::TimeoutError"
  receiver = sentry_receiver("4", "")
  report_runtime("after the silent one")
  assert_equal "after the silent one", receiver.received_events(1)[0].sentry_field("exception.values.0.value")
end

test "drain_reports gives up after its seconds" do
  Cybertrain.config.http_allow_private = true
  Cybertrain.config.sentry_dsn = "http://public@127.0.0.1:#{silent_port}/6"
  report_runtime("held")
  started = Cybertrain::Clock.monotonic
  drained = Cybertrain.error.drain_reports(2.0)
  waited = Cybertrain::Clock.monotonic - started
  assert_equal false, drained
  assert waited >= 2.0 && waited < 3.0, "drain_reports(2.0) took #{waited} s"
  # The send ends at its own deadline; the warn line is not this case's.
  capture_log { assert Cybertrain.error.drain_reports(8.0) }
end

Cybertrain::Test.run!
