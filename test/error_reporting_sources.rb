require "json"
require "stringio"
require "cybertrain"
require "cybertrain/websocket"
require "cybertrain/test_help"
require "cybertrain/test/websocket_receiver"
require_relative "support/log_capture"

# What is reported automatically outside the request path (spec section
# 13.2, plan D10): every failed job attempt (the default policy, a
# `retry_on`, a `discard_on`), with the job's context and the id of the
# request that enqueued it; a failed `deliver_later` as the `cybertrain
# mail` job; a job thread's own failure; scheduled tasks (a block that
# raises, a cron with no next run); feeds (on_open, on_message and on_tick
# raising, a feed thread's death) and the supervisor giving up. The
# request path's reports are proved on the core alone in
# test/request_id.rb, test/error_pages.rb and test/dev_error_page.rb.
#
# Compiled only: `require "cybertrain"` links SQLite through FFI
# (spikes/NOTES.md rule 23). cybertrain/test_help's reset empties the
# reporter's dedupe before each test; the subscriber added below, before
# the first test, is kept. Feed threads are real and waited for with
# bounded polls; their reports are told apart by `where`.

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)
Cybertrain::DB.connect(":memory:")
Cybertrain.config.mail_delivery_method = :test

DB = Cybertrain::DB
Job = Cybertrain::Job
S = Cybertrain::Scheduler
WS = Cybertrain::WebSocket
B = Cybertrain::Background
WS.random_source = -> { 0.5 }

def no_context
  h = { "" => "" }
  h.delete("")
  h
end

# What the subscriber received, in order (a constant: NOTES rule 64).
def blank_event
  Cybertrain::ErrorEvent.new("", "", "", "", "", "", "", "", false, no_context, Array.new(0) { "" }, Time.at(0).utc)
end

EVENTS = Array.new(0) { blank_event }

class Collect < Cybertrain::ErrorSubscriber
  def report(event)
    EVENTS << event
    nil
  end
end

Cybertrain.error.subscribe(Collect.new)

module EventsReset
  def self.hook
    -> {
      EVENTS.clear
      nil
    }
  end
end
Cybertrain::Test.on_reset(EventsReset.hook)

def events_after_drain
  Cybertrain.error.drain_reports(2.0)
  EVENTS
end

def only_event
  events = events_after_drain
  assert_equal 1, events.size
  events[0]
end

def mono_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

# The events reported with `where`, after waiting (at most `wait` seconds)
# for `count` of them.
def await_events(where, count, wait)
  ends_at = mono_now + wait
  found = Array.new(0) { blank_event }
  while true
    Cybertrain.error.drain_reports(0.2)
    found = Array.new(0) { blank_event }
    EVENTS.each { |ev| found << ev if ev.error_where == where }
    return found if found.size >= count || mono_now >= ends_at

    sleep(0.05)
  end
  found
end

# ---- jobs --------------------------------------------------------------------

# A job class as `spin run gen` writes one (gen/jobs.rb), by hand: the
# default policy, a retry_on RuntimeError (attempts: 3, wait 60 s) and a
# discard_on ArgumentError.
class BoomJob
  def self.perform_later
    Cybertrain::Job.enqueue("BoomJob", "{}")
  end

  def self.run_job(run)
    raise RuntimeError, "boom"
  end
end

class RetryJob
  def self.perform_later
    Cybertrain::Job.enqueue("RetryJob", "{}")
  end

  def self.run_job(run)
    begin
      raise RuntimeError, "try again"
    rescue ::RuntimeError => e
      Cybertrain::Job.retry_later(run, e, 60, false, 3)
    end
    nil
  end
end

class DiscardJob
  def self.perform_later
    Cybertrain::Job.enqueue("DiscardJob", "{}")
  end

  def self.run_job(run)
    begin
      raise ArgumentError, "no such thing"
    rescue ::ArgumentError => e
      Cybertrain::Job.discard(run, e)
    end
    nil
  end
end

# Not a StandardError, nor one of run_handler's other arms: it escapes the
# job to the job thread's loop.
class JobCrash < Exception
end

Job.register("BoomJob") { |run| BoomJob.run_job(run) }
Job.register("RetryJob", max_attempts: 3) { |run| RetryJob.run_job(run) }
Job.register("DiscardJob") { |run| DiscardJob.run_job(run) }
Job.register("CrashJob") { |run| raise JobCrash, "the job thread caught it" }

def job_attempts(id)
  rows = DB.with { |c| c.execute("SELECT attempts AS v FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.int(rows[0]["v"])
end

def job_state(id)
  rows = DB.with { |c| c.execute("SELECT state AS v FROM cybertrain_jobs WHERE id = ?", [id]) }
  Cybertrain::Cast.str(rows[0]["v"])
end

# A request's Scope, as RequestId installs one: a job enqueued under it
# records its id.
def request_scope
  id = "req-77"
  verb = "POST"
  path = "/orders"
  where = "OrdersController#create"
  tags = Array.new(0) { "" }
  tags << id
  Cybertrain::Logger::Scope.new(id, verb, path, where, tags, 0, no_context)
end

# Enqueues a BoomJob as a request would (the Scope put back after it).
def boom_in_request
  saved = Cybertrain::Logger.swap_scope(request_scope)
  BoomJob.perform_later
ensure
  Cybertrain::Logger.swap_scope(saved)
end

test "every failed job attempt is reported, with the job's context and its request id" do
  clear_enqueued_jobs
  id = boom_in_request
  perform_enqueued_jobs
  ev = only_event
  assert_equal ["RuntimeError", "boom", "BoomJob", "req-77", "", ""],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id, ev.error_request_method,
                ev.error_request_path]
  assert_equal false, ev.error_handled
  assert_equal({ "job.id" => id.to_s, "job.attempt" => "1", "job.max_attempts" => "5" }, ev.error_context)
  assert_equal "queued", job_state(id)
  # The existing line stays.
  assert_logged LOG.string, "ERROR", "job #{id} (BoomJob) attempt 1 of 5 failed: RuntimeError: boom; retrying in "
end

# Plan D11: the reporter keeps one event per class, message and `where`
# for 60 seconds by the Clock, so a test of every attempt travels past
# the window between attempts. The worked time (`perform_enqueued_jobs`'s
# argument) only makes the row due; the Clock is what dedupe reads.
JOB_AT = Time.utc(2026, 11, 11, 12)
# One step past the reporter's dedupe window.
PAST_DEDUPE = Cybertrain::ErrorReporter::DEDUPE_SECONDS + 1

test "a job's second attempt past the dedupe window is reported; one inside it is not" do
  clear_enqueued_jobs
  travel_to JOB_AT
  id = boom_in_request
  perform_enqueued_jobs
  assert_equal 1, events_after_drain.size
  # Past the dedupe window by the Clock; worked a day on, so the row (due
  # 60 s after attempt 1) runs once.
  travel PAST_DEDUPE
  perform_enqueued_jobs(Time.current + 86_400)
  assert_equal 2, job_attempts(id)
  events = events_after_drain
  assert_equal 2, events.size
  ev = events[1]
  assert_equal ["RuntimeError", "boom", "BoomJob", "req-77"],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id]
  assert_equal({ "job.id" => id.to_s, "job.attempt" => "2", "job.max_attempts" => "5" }, ev.error_context)
  assert_equal JOB_AT.to_i + PAST_DEDUPE, ev.error_occurred_at.to_i
  # Attempt 3 inside the window (the Clock has not moved): logged, not
  # reported again.
  perform_enqueued_jobs(Time.current + 2 * 86_400)
  assert_equal 3, job_attempts(id)
  assert_logged LOG.string, "ERROR", "job #{id} (BoomJob) attempt 3 of 5 failed: RuntimeError: boom; retrying in "
  assert_equal 2, events_after_drain.size
end

test "a retry_on attempt carries the policy's attempts, the second one past the window too" do
  clear_enqueued_jobs
  travel_to JOB_AT
  retried = RetryJob.perform_later
  perform_enqueued_jobs
  ev = only_event
  assert_equal ["RuntimeError", "try again", "RetryJob", ""],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id]
  assert_equal({ "job.id" => retried.to_s, "job.attempt" => "1", "job.max_attempts" => "3" }, ev.error_context)
  assert_equal "queued", job_state(retried)
  # Due 60 s on; the Clock past the window.
  travel PAST_DEDUPE
  perform_enqueued_jobs
  assert_equal 2, job_attempts(retried)
  events = events_after_drain
  assert_equal 2, events.size
  assert_equal({ "job.id" => retried.to_s, "job.attempt" => "2", "job.max_attempts" => "3" }, events[1].error_context)
  # Attempt 3, the policy's last, inside the window: the row fails, and
  # the report is collapsed into attempt 2's.
  perform_enqueued_jobs(Time.current + 3600)
  assert_equal "failed", job_state(retried)
  assert_equal 2, events_after_drain.size
end

test "a discard_on is reported once" do
  clear_enqueued_jobs
  discarded = DiscardJob.perform_later
  perform_enqueued_jobs
  ev = only_event
  assert_equal ["ArgumentError", "no such thing", "DiscardJob"], [ev.error_class, ev.error_message, ev.error_where]
  assert_equal({ "job.id" => discarded.to_s, "job.attempt" => "1", "job.max_attempts" => "1" }, ev.error_context)
  assert_equal "discarded", job_state(discarded)
end

test "a deliver_later that fails is reported as cybertrain mail" do
  clear_enqueued_jobs
  # deliver_later checks the fields before enqueueing, so the failing row
  # is enqueued as an older process would have.
  payload = JSON.generate({ "to" => "a b@example.com", "subject" => "S", "body" => "b" })
  id = Job.enqueue("cybertrain mail", payload)
  perform_enqueued_jobs
  ev = only_event
  assert_equal ["ArgumentError", "cybertrain mail"], [ev.error_class, ev.error_where]
  assert_equal "discarded", job_state(id)
  refute ev.error_message.empty?
end

test "an exception that escapes a job is reported by the job thread, where job thread" do
  clear_enqueued_jobs
  Job.enqueue("CrashJob", "{}")
  refute Cybertrain::Job::Worker.claim_safely(Time.now.to_i + 1, 3, -1)
  assert_logged LOG.string, "ERROR", "Job thread 3: JobCrash: the job thread caught it"
  ev = only_event
  assert_equal ["JobCrash", "the job thread caught it", "job thread", ""],
               [ev.error_class, ev.error_message, ev.error_where, ev.error_request_id]
  clear_enqueued_jobs
end

# ---- scheduled tasks -----------------------------------------------------------

S.every(3600, "nightly") { raise RuntimeError, "nightly broke" }
# After 2096-02-29 the next 29 February falls on a Thursday in 2104,
# beyond Cron.next_after's five years (test/scheduler_cron.rb's case).
S.cron("0 0 29 2 *", "never") { nil }
LEAP_2096 = Time.utc(2096, 2, 29, 0, 0).to_i

test "a scheduled task that raises is reported, where schedule:<name>" do
  refute S.run_task(S::TASKS[S.task_index("nightly")])
  ev = only_event
  assert_equal ["RuntimeError", "nightly broke", "schedule:nightly"], [ev.error_class, ev.error_message, ev.error_where]
  assert ev.error_context.empty?
  assert_logged LOG.string, "ERROR", "Scheduled task \"nightly\" failed: RuntimeError: nightly broke"
end

test "a cron task with no next run is reported, where schedule:<name>" do
  assert_equal(-1, S.schedule_next(S::TASKS[S.task_index("never")], LEAP_2096))
  ev = only_event
  assert_equal ["ArgumentError", "schedule:never"], [ev.error_class, ev.error_where]
  assert_equal "cron \"0 0 29 2 *\": no run in the 5 years after 2096-02-29 00:00 UTC", ev.error_message
end

# ---- feeds ---------------------------------------------------------------------

# How often each raising callback has run (constants: NOTES rule 64); each
# raises the first time only.
OPENED = Array.new(0) { "" }
TICKED = Array.new(0) { "" }

# Not a StandardError: it ends the feed's thread.
class FeedCrash < Exception
end

def step(kind, data = "")
  Cybertrain::Test::WsStep.new(kind, data)
end

# A port nothing listens on any more.
def dead_url(path)
  rx = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 1.0, read_timeout: 1.0)
  rx.start
  rx.stop
  rx.url(path)
end

def subscribe_prices(url)
  WS.subscribe("prices", url, allow_private: true)
    .on_message { |conn, data| raise RuntimeError, "cannot parse #{data}" }
end

def subscribe_opener(url)
  WS.subscribe("opener", url, allow_private: true)
    .on_open do |conn|
      OPENED << "open"
      raise RuntimeError, "subscribe refused" if OPENED.size == 1
    end
    .on_message { |conn, data| conn.send_text(data) }
end

def subscribe_ticker(url)
  WS.subscribe("ticker", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
    .on_tick(1) do |conn|
      TICKED << "tick"
      raise RuntimeError, "tick failed" if TICKED.size == 1
    end
end

def subscribe_crashy(url)
  WS.subscribe("crashy", url, allow_private: true)
    .on_message { |conn, data| conn.send_text(data) }
    .on_tick(1) { |conn| raise FeedCrash, "crashy died" }
end

def await_alive(name, alive, wait)
  ends_at = mono_now + wait
  while mono_now < ends_at
    return true if WS.thread_alive?(name) == alive

    sleep(0.05)
  end
  WS.thread_alive?(name) == alive
end

# The callable that stops the feeds (made in a method: spikes/NOTES.md
# rule 82), registered with Test.after_this_case before they start, so a
# failed assertion leaves no feed thread running into the next case.
# WS.stop! does nothing once they are stopped.
def feeds_stopper
  lambda do
    WS.stop!
    nil
  end
end

test "a feed's on_open, on_message and on_tick failures are reported, where feed:<name>" do
  Cybertrain::Test.after_this_case(feeds_stopper)
  prices = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 10.0, read_timeout: 5.0)
  prices.ws_script([step("accept"), step("send_text", "1"), step("echo_until_close")])
  prices.start
  opener = Cybertrain::Test::WebSocketReceiver.new(max: 1, accept_window: 10.0, read_timeout: 5.0)
  opener.ws_script([step("accept"), step("echo_until_close")])
  opener.start
  subscribe_prices(prices.url("/prices"))
  subscribe_opener(opener.url("/opener"))
  subscribe_ticker(dead_url("/ticker"))
  assert WS.start!(Cybertrain::Config.new)
  message = await_events("feed:prices", 1, 8.0)
  opened = await_events("feed:opener", 1, 8.0)
  ticked = await_events("feed:ticker", 1, 8.0)
  WS.stop!
  prices.stop
  opener.stop
  assert_equal 1, message.size
  assert_equal ["RuntimeError", "cannot parse 1", ""], [message[0].error_class, message[0].error_message, message[0].error_request_id]
  assert_equal 1, opened.size
  assert_equal ["RuntimeError", "subscribe refused"], [opened[0].error_class, opened[0].error_message]
  assert_equal 1, ticked.size
  assert_equal ["RuntimeError", "tick failed"], [ticked[0].error_class, ticked[0].error_message]
  assert_logged LOG.string, "ERROR", "WebSocket \"prices\" on_message failed: RuntimeError: cannot parse 1"
end

# Runs the give-up case with exit_on_feed_death on, and off again (with
# the supervisor's state reset and the feeds stopped) after it, also when
# it raises (pre-flight ruling G4).
module FeedsProcess
  def self.during
    B.exit_on_feed_death = true
    _value = yield
    nil
  ensure
    B.exit_on_feed_death = false
    B.reset_supervisor!
    WS.stop!
  end
end

test "a feed thread's death and the supervisor giving up are reported, where feed:<name>" do
  B.stop_all
  B.reset_supervisor!
  subscribe_crashy(dead_url("/crashy"))
  config = Cybertrain::Config.new
  config.feed_restart_limit = 1
  FeedsProcess.during do
    assert WS.start!(config)
    assert await_alive("crashy", false, 4.0)
    died = await_events("feed:crashy", 1, 4.0)
    assert_equal 1, died.size
    assert_equal ["FeedCrash", "crashy died"], [died[0].error_class, died[0].error_message]
    # The first pass schedules the restart, the second makes it; the
    # feed dies again, and the next pass gives up (one restart, limit 1).
    B.supervise_pass(config, 4000, 4000)
    B.supervise_pass(config, 4100, 4100)
    assert await_alive("crashy", false, 4.0)
    B.supervise_pass(config, 4200, 4200)
    assert B.feeds_failed?
  end
  assert_logged LOG.string, "FATAL", "feed crashy restarted 1 times in 600 s; exiting"
  gave_up = Array.new(0) { blank_event }
  events_after_drain.each { |ev| gave_up << ev if ev.error_class == "Cybertrain::Background::FeedFailed" }
  assert_equal 1, gave_up.size
  assert_equal ["feed crashy restarted 1 times in 600 s; exiting", "feed:crashy"],
               [gave_up[0].error_message, gave_up[0].error_where]
  assert gave_up[0].error_backtrace.empty?
  assert_equal false, gave_up[0].error_handled
end

Cybertrain::Test.run!
