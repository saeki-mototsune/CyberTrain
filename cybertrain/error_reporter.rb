# Cybertrain.error -- error reporting shaped like Rails.error (spec section
# 13): `report` records an exception the application rescued, `handle`
# runs a block and reports what it raised, `subscribe` adds a
# Cybertrain::ErrorSubscriber. The framework reports what ends a request,
# a job's attempt, a scheduled task or a feed through the same reporter.
#
# The event (Cybertrain::ErrorEvent) is a value of Strings built on the
# caller's thread, from the exception (its class name, message and
# backtrace), the thread's log Scope (the request id, method, path,
# `where` and context) and the configuration (env, release), so that it
# can cross threads (spec section 13.1). It is put on a bounded queue
# ({ErrorReporter::QUEUE_LIMIT}); one delivery thread, started on the
# first queued event, hands each event to every subscriber and then to
# the sender (the Sentry sender, cybertrain/error_reporter/sentry.rb).
# Nothing is queued, and no thread starts, while there is no subscriber
# and the sender does not send.
#
# Dedupe: an event with the class, message and `where` of one queued in
# the last {ErrorReporter::DEDUPE_SECONDS} seconds (by the Clock, so a
# test travels past it) is not queued again. A full queue drops the event
# and counts it; the delivery thread logs `error reports dropped: <n>` at
# warn at most once every {ErrorReporter::DROP_LOG_SECONDS} seconds.
#
# One Mutex covers the dedupe table, the drop count, the queue's size
# check, the in-flight count and the subscriber list; it is taken on the
# error path only, and nothing logs or calls a subscriber inside it.
require "json"
require "cybertrain/logger"
require "cybertrain/clock"
require "cybertrain/config"

module Cybertrain
  # One error report as a subscriber receives it: Strings (and a Boolean,
  # a Hash of Strings, an Array of Strings and a Time), so that it is a
  # value that crosses threads (spec section 13.3). Every reader carries
  # the `error_` prefix (plan D9).
  # @api public
  class ErrorEvent
    # The exception's class name, namespaced (`"ActiveRecord::RecordInvalid"`
    # style: `"JSON::ParserError"`).
    # @return [String]
    attr_reader :error_class
    # The exception's message.
    # @return [String]
    attr_reader :error_message
    # Where it happened: `"ArticlesController#create"`, a job's kind,
    # `"schedule:<name>"`, `"feed:<name>"`, `"cybertrain mail"`, or `""`.
    # @return [String]
    attr_reader :error_where
    # The request's id (or the job's recorded one), `""` outside a request.
    # @return [String]
    attr_reader :error_request_id
    # The request's method, `""` outside a request.
    # @return [String]
    attr_reader :error_request_method
    # The request's path without its query string, `""` outside a request.
    # @return [String]
    attr_reader :error_request_path
    # `Cybertrain.config.env`.
    # @return [String]
    attr_reader :error_environment
    # `Cybertrain.config.release`.
    # @return [String]
    attr_reader :error_release
    # Whether the application rescued it (`report`, `handle`) rather than
    # it ending the work (a 500, a failed job).
    # @return [Boolean]
    attr_reader :error_handled
    # The Scope's context with the caller's `context:` over it, keys and
    # values as Strings.
    # @return [Hash{String => String}]
    attr_reader :error_context
    # The exception's backtrace; empty when there is none (a release build
    # under Spinel, spikes/NOTES.md rule 107).
    # @return [Array<String>]
    attr_reader :error_backtrace
    # When it was reported, from the Clock.
    # @return [Time]
    attr_reader :error_occurred_at

    # @param error_class [String]
    # @param error_message [String]
    # @param where [String]
    # @param request_id [String]
    # @param request_method [String]
    # @param request_path [String]
    # @param environment [String]
    # @param release [String]
    # @param handled [Boolean]
    # @param context [Hash{String => String}]
    # @param backtrace [Array<String>]
    # @param occurred_at [Time]
    # @api public
    def initialize(error_class, error_message, where, request_id, request_method, request_path, environment, release,
                   handled, context, backtrace, occurred_at)
      @error_class = error_class
      @error_message = error_message
      @error_where = where
      @error_request_id = request_id
      @error_request_method = request_method
      @error_request_path = request_path
      @error_environment = environment
      @error_release = release
      @error_handled = handled
      @error_context = context
      @error_backtrace = backtrace
      @error_occurred_at = occurred_at
    end
  end

  # The base of an error subscriber: override {#report}. Subscribers run
  # on the reporter's delivery thread, not in the caller; one that raises
  # is logged at error (`error subscriber <Class> failed: <Class>:
  # <message>`), never reported, and the others still receive the event.
  # @example config/app.rb
  #   class AuditSubscriber < Cybertrain::ErrorSubscriber
  #     def report(event)
  #       Cybertrain.logger.warn("reported #{event.error_class}: #{event.error_message}")
  #     end
  #   end
  #   Cybertrain.error.subscribe(AuditSubscriber.new)
  # @api public
  class ErrorSubscriber
    # Receives one event. The base does nothing.
    # @param event [ErrorEvent]
    # @return [nil]
    # @api public
    def report(event)
      nil
    end
  end

  # The process's error reporter, {Cybertrain.error}: see the file's
  # header comment.
  # @api public
  class ErrorReporter
    # The events waiting for the delivery thread, at most.
    QUEUE_LIMIT = 100
    # An event like one queued this many seconds ago or less is not queued.
    DEDUPE_SECONDS = 60
    # The drop count is logged at most once in this many seconds.
    DROP_LOG_SECONDS = 60
    # The recent-keys table drops its expired keys once it passes this size.
    RECENT_LIMIT = 1000

    # The empty context, `context:`'s default (seeded, spikes/NOTES.md rule
    # 9). Never written to.
    # @api private
    def self.empty_context
      h = { "" => "" }
      h.delete("")
      h
    end

    # `<Class>: <message>` of a rescued exception, or the class name alone
    # when its message cannot be read; never raises.
    # @param error [Exception]
    # @return [String]
    # @api private
    def self.failure_text(error)
      name = error.class.name.to_s
      text = error.message.to_s
      "#{name}: #{text}"
    rescue JSON::NestingError, JSON::ParserError, StandardError
      error.class.name.to_s
    rescue NotImplementedError, SystemStackError, ScriptError
      error.class.name.to_s
    end

    # The empty `Hash{String => String}`: what a caller with no context
    # passes to {#report_unhandled} and {#report_message}.
    NO_CONTEXT = ErrorReporter.empty_context

    # Where the delivery thread sends each event after the subscribers.
    # The base sends nothing; the Sentry sender overrides its methods.
    # @api public
    class Sender
      # Whether this sender sends at all (a DSN is configured).
      # @return [Boolean]
      # @api public
      def sends?
        false
      end

      # Sends one event; true when it was sent.
      # @param event [ErrorEvent]
      # @return [Boolean]
      # @api public
      def deliver_event(event)
        false
      end

      # The require line's name of the sender this is ("" for the base,
      # which sends nothing; `"sentry"` for the Sentry sender): the boot
      # check of a DSN set with no sender linked asks it
      # (Application#validate_boot), without naming a sender's class.
      # @return [String]
      # @api public
      def sender_name
        ""
      end
    end

    # @api public
    def initialize
      @lock = Mutex.new
      # Seeded with the element type, then emptied (rule 9).
      @subscribers = Array.new(0) { ErrorSubscriber.new }
      # How many subscribers were there when the first test began (-1:
      # none has): {reset!} keeps those, the ones config/app.rb added.
      @boot_subscribers = -1
      @sender = Sender.new
      # The sender in place when the first test began: {reset!} puts it
      # back.
      @boot_sender = @sender
      @queue = Queue.new
      # Events queued and not yet handed to every subscriber and the sender.
      @pending = 0
      @started = false
      # The dedupe table: a key's last queueing, as Clock seconds.
      @recent = { "" => 0.0 }
      @recent.delete("")
      @dropped = 0
      # When the last drop line was logged, as Clock seconds; -1.0: never
      # (a Float, not a nullable Time: rule 7).
      @last_drop_log = -1.0
    end

    # Records an exception the application rescued (or, with `handled:
    # false`, one it did not). `context:` keys and values become Strings,
    # merged over the thread's Scope context. Answers nil at once: the
    # event is delivered on the reporter's thread.
    # @example
    #   begin
    #     charge(order)
    #   rescue PaymentError => e
    #     Cybertrain.error.report(e, context: { "order_id" => order.id })
    #   end
    # @param error [Exception]
    # @param handled [Boolean]
    # Never raises into its caller: a failure while building or queueing
    # the event (a context value whose `to_s` raises) is logged at error,
    # `error report failed: <Class>: <message>`, and it answers nil.
    # @param context [Hash] keys and values of any type, read with `to_s`
    # @return [nil]
    # @api public
    def report(error, handled: true, context: NO_CONTEXT)
      return nil unless listened?

      given = ErrorReporter.empty_context
      context.each { |k, v| given[k.to_s] = v.to_s }
      scope = Logger.current_scope
      where = scope.scope_where
      enqueue_error(error, where, handled, given)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      report_failed(e)
    rescue NotImplementedError, SystemStackError, ScriptError => e
      report_failed(e)
    end

    # Runs the block and answers its value; an exception it raises
    # (`StandardError`, `JSON::ParserError`, `JSON::NestingError`) is
    # reported with `handled: true` and the block answers nil.
    # @example
    #   price = Cybertrain.error.handle(context: { "feed" => "prices" }) do
    #     parse_price(text)
    #   end
    # @param context [Hash] as {#report}'s
    # @yield the work
    # @return [Object, nil] the block's value, nil after an exception
    # @api public
    def handle(context: NO_CONTEXT)
      value = nil
      begin
        value = yield
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        report(e, handled: true, context: context)
        value = nil
      end
      value
    end

    # Adds a subscriber; it receives every event from now on.
    # @param subscriber [ErrorSubscriber]
    # @return [nil]
    # @api public
    def subscribe(subscriber)
      @lock.synchronize { @subscribers << subscriber }
      nil
    end

    # The framework's report of an exception that ended its work (a 500, a
    # failed job attempt, a task, a feed): `handled` false; `where` `""`
    # means the Scope's.
    # @param error [Exception]
    # @param where [String]
    # @param context [Hash{String => String}] {NO_CONTEXT} for none
    # @return [nil]
    # Never raises into its caller ({#report}'s rule).
    # @api private
    def report_unhandled(error, where, context)
      return nil unless listened?

      given = ErrorReporter.empty_context
      context.each { |k, v| given[k] = v }
      scope = Logger.current_scope
      at = where == "" ? scope.scope_where : where
      enqueue_error(error, at, false, given)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      report_failed(e)
    rescue NotImplementedError, SystemStackError, ScriptError => e
      report_failed(e)
    end

    # The framework's report of a failure with no exception object (the
    # feed supervisor giving up): `error_class` names it, `handled` false,
    # no backtrace; `where` `""` means the Scope's.
    # @param error_class [String]
    # @param message [String]
    # @param where [String]
    # @param context [Hash{String => String}] {NO_CONTEXT} for none
    # @return [nil]
    # Never raises into its caller ({#report}'s rule).
    # @api private
    def report_message(error_class, message, where, context)
      return nil unless listened?

      given = ErrorReporter.empty_context
      context.each { |k, v| given[k] = v }
      scope = Logger.current_scope
      at = where == "" ? scope.scope_where : where
      name = error_class.to_s
      text = message.to_s
      queue_event(name, text, Array.new(0) { "" }, at, false, given)
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      report_failed(e)
    rescue NotImplementedError, SystemStackError, ScriptError => e
      report_failed(e)
    end

    # Waits up to `seconds` for every queued event to be delivered; true
    # once the queue is empty and nothing is in flight, false at the
    # deadline (what is left stays queued). Each role's stop calls it.
    # @param seconds [Float]
    # @return [Boolean]
    # @api public
    def drain_reports(seconds = 2.0)
      deadline = Clock.monotonic + seconds.to_f
      while true
        return true if idle?
        return false if Clock.monotonic >= deadline

        sleep 0.002
      end
      false
    end

    # Where events go after the subscribers.
    # @return [Sender]
    # @api public
    def sender
      @sender
    end

    # Installs the sender (the Sentry sender, at boot).
    # @param sender [Sender]
    # @return [nil]
    # @api public
    def sender=(sender)
      @lock.synchronize { @sender = sender }
      nil
    end

    # The test harness's reset before every test: waits for the queue (up
    # to `seconds`), then empties the dedupe table and the drop count,
    # drops the subscribers added since the first test began (those added
    # at boot, by config/app.rb, stay) and puts back the sender that was in
    # place then. The first call fixes that baseline: a subscriber added
    # later (an application booted inside the first test) counts as a
    # test's. It also runs for a case driven by hand inside a running case
    # (Test.case_begin), which then loses the outer case's subscribers.
    #
    # When the wait runs out (a subscriber or a send still blocked), it
    # logs `error reports undelivered at reset: <n> (<m> discarded)` at
    # warn and discards the events still queued, so that they cannot reach
    # the next test's subscribers; the event already in flight cannot be
    # recalled, and reaches whoever its delivery is handing it to.
    # @param seconds [Float] how long to wait for the queue
    # @return [nil]
    # @api private
    def reset!(seconds = 2.0)
      drained = drain_reports(seconds)
      discard_undelivered unless drained
      @lock.synchronize { reset_locked }
      nil
    end

    # Events dropped (a full queue) and not yet logged.
    # @return [Integer]
    # @api private
    def dropped_count
      @lock.synchronize { @dropped }
    end

    # Whether the delivery thread has started.
    # @return [Boolean]
    # @api private
    def delivery_started?
      @lock.synchronize { @started }
    end

    private

    # Whether an event would go anywhere: a subscriber, or a sender that
    # sends.
    def listened?
      sender = @sender
      count = 0
      @lock.synchronize do
        count = @subscribers.size
        sender = @sender
      end
      return true if count > 0

      sender.sends?
    end

    # {#report}'s failure line, at error; never raises.
    def report_failed(error)
      text = ErrorReporter.failure_text(error)
      line = "error report failed: #{text}"
      Cybertrain.logger.error(line)
      nil
    end

    # {reset!} after a drain that ran out: the queued events are taken off
    # and counted out of the in-flight count; the warn line says how many
    # were left.
    def discard_undelivered
      left = 0
      discarded = 0
      @lock.synchronize do
        left = @pending
        while @queue.size > 0
          event = @queue.pop(timeout: 0)
          break if event.nil?

          discarded += 1
        end
        @pending -= discarded
      end
      line = "error reports undelivered at reset: #{left} (#{discarded} discarded)"
      Cybertrain.logger.warn(line)
      nil
    end

    def idle?
      @lock.synchronize { @pending == 0 }
    end

    # The event of an exception: its class name, message and backtrace.
    def enqueue_error(error, where, handled, context)
      name = error.class.name.to_s
      text = error.message.to_s
      trace = Array.new(0) { "" }
      lines = error.backtrace
      lines.each { |line| trace << line.to_s } unless lines.nil?
      queue_event(name, text, trace, where, handled, context)
    end

    # Builds the event on the caller's thread (the Scope's request fields,
    # its context under the caller's, env, release, the Clock) and queues
    # it unless a like one was queued within DEDUPE_SECONDS or the queue
    # is full. Not named `enqueue` (Job.enqueue answers an Integer): one
    # return type per method name across the program (spikes/NOTES.md
    # rules 10 and 34).
    def queue_event(name, text, trace, where, handled, given)
      scope = Logger.current_scope
      context = ErrorReporter.empty_context
      scope.scope_context.each { |k, v| context[k] = v }
      given.each { |k, v| context[k] = v }
      request_id = scope.scope_request_id
      request_method = scope.scope_request_method
      request_path = scope.scope_request_path
      environment = Cybertrain.config.env.to_s
      release = Cybertrain.config.release.to_s
      now = Clock.now
      event = ErrorEvent.new(name, text, where, request_id, request_method, request_path, environment, release,
                             handled, context, trace, now)
      key = "#{name}\n#{text}\n#{where}"
      seconds = now.to_f
      @lock.synchronize { queue_locked(event, key, seconds) }
      nil
    end

    # Under the lock: dedupe, the size check, the queueing, the thread's
    # start.
    def queue_locked(event, key, seconds)
      last = @recent[key]
      return nil if !last.nil? && seconds - last < DEDUPE_SECONDS

      if @queue.size >= QUEUE_LIMIT
        @dropped += 1
        return nil
      end
      prune_recent(seconds) if @recent.size > RECENT_LIMIT
      @recent[key] = seconds
      @pending += 1
      @queue << event
      # Started only once Thread.new returned: if it raises, the next
      # report tries again, and the queued event waits for that thread.
      unless @started
        spawn_delivery
        @started = true
      end
      nil
    end

    # Drops the keys older than the dedupe window.
    def prune_recent(seconds)
      old = Array.new(0) { "" }
      @recent.each { |k, t| old << k if seconds - t >= DEDUPE_SECONDS }
      old.each { |k| @recent.delete(k) }
      nil
    end

    def reset_locked
      if @boot_subscribers < 0
        @boot_subscribers = @subscribers.size
        @boot_sender = @sender
      else
        @subscribers.pop while @subscribers.size > @boot_subscribers
        @sender = @boot_sender
      end
      @recent.clear
      @dropped = 0
      @last_drop_log = -1.0
      nil
    end

    # Through a method, as Scheduler.spawn_loop does (spikes/NOTES.md rule
    # 21).
    def spawn_delivery
      Thread.new { delivery_loop }
    end

    # The delivery thread: takes each event off the queue and hands it on;
    # between events, logs the drop count when it is due. Each step rescues
    # everything a thread must survive; should the thread end all the same,
    # the flag goes down, so the next report starts another.
    def delivery_loop
      while true
        delivery_step
      end
      nil
    ensure
      @lock.synchronize { @started = false }
    end

    # One step of the loop, in a plain rescuing method.
    def delivery_step
      event = @queue.pop(timeout: 1.0)
      log_drops
      deliver_counted(event) unless event.nil?
      nil
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      delivery_failed(e)
    rescue NotImplementedError, SystemStackError, ScriptError => e
      delivery_failed(e)
    end

    # Hands the event on; the in-flight count comes down whatever happens
    # (save-work-ensure in a plain method).
    def deliver_counted(event)
      deliver_one(event)
      nil
    ensure
      @lock.synchronize { @pending -= 1 }
    end

    def delivery_failed(error)
      text = ErrorReporter.failure_text(error)
      line = "error delivery failed: #{text}"
      Cybertrain.logger.error(line)
      nil
    end

    # Hands the event to every subscriber, then to the sender. Not named
    # `deliver` (Mailer#deliver and Stream::Hub#deliver answer other
    # types; spikes/NOTES.md rules 10 and 34).
    def deliver_one(event)
      list = Array.new(0) { ErrorSubscriber.new }
      sender = @sender
      @lock.synchronize do
        @subscribers.each { |s| list << s }
        sender = @sender
      end
      list.each { |s| deliver_to(s, event) }
      send_to(sender, event)
      nil
    end

    # One subscriber, in a plain rescuing method: its failure is logged.
    def deliver_to(subscriber, event)
      subscriber.report(event)
      nil
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      subscriber_failed(subscriber, e)
    rescue NotImplementedError, SystemStackError, ScriptError => e
      subscriber_failed(subscriber, e)
    end

    def subscriber_failed(subscriber, error)
      text = ErrorReporter.failure_text(error)
      line = "error subscriber #{subscriber.class.name} failed: #{text}"
      Cybertrain.logger.error(line)
      nil
    end

    # The sender (`sends?` and the send), in a plain rescuing method: a
    # raise is logged at warn, as a failed send is (spec section 13.4).
    def send_to(sender, event)
      sender.deliver_event(event) if sender.sends?
      nil
    rescue JSON::NestingError, JSON::ParserError, StandardError => e
      sender_failed(sender, e)
    rescue NotImplementedError, SystemStackError, ScriptError => e
      sender_failed(sender, e)
    end

    def sender_failed(sender, error)
      text = ErrorReporter.failure_text(error)
      line = "error sender #{sender.class.name} failed: #{text}"
      Cybertrain.logger.warn(line)
      nil
    end

    # `error reports dropped: <n>` at warn when events were dropped and the
    # last such line is DROP_LOG_SECONDS old or more; the count starts
    # again from zero.
    def log_drops
      now = Clock.now.to_f
      count = 0
      @lock.synchronize do
        if @dropped > 0 && (@last_drop_log < 0.0 || now - @last_drop_log >= DROP_LOG_SECONDS)
          count = @dropped
          @dropped = 0
          @last_drop_log = now
        end
      end
      Cybertrain.logger.warn("error reports dropped: #{count}") if count > 0
      nil
    end
  end

  @error_reporter = ErrorReporter.new

  # The process's error reporter.
  # @example
  #   Cybertrain.error.report(e, context: { "order_id" => order.id })
  # @return [ErrorReporter]
  # @api public
  def self.error
    @error_reporter
  end
end
