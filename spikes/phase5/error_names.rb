# Phase 5b spike, item 8 (spec section 16): Rails.error's names beside
# their namesakes, in one program with the whole framework. A record, not a
# test.
#
# What it asks: does `Cybertrain.error` (a module function answering an
# ErrorReporter) compile beside `Logger#error(msg)` and
# `Template::Parser#error`; `ErrorReporter#report(e, handled:, context:)`
# and `ErrorSubscriber#report(event)` (overridden by one subclass answering
# nil and one answering an Array) beside `CLI::Toolchain.report`;
# `ErrorReporter#handle(context:) { }`, a rescuing yielder answering the
# block's value (D12), beside `Job.handle(kind) { }`, with blocks answering
# a String, an Integer and nil and one whose only statement is `raise`,
# called from a method body and from a block nested in a block (rules 32,
# 45, 79); `ErrorReporter#subscribe(obj)` beside `WebSocket.subscribe` (a
# Subscription) and `Stream::Hub#subscribe` (a Subscriber); `Config#release`
# (a String) beside `Lease.release` (nil); and `context:` given a Hash with
# String keys and one with Symbol keys in one program, each key read back
# as a String; and `ErrorEvent#error_message` (a reader) beside the private
# `DB::Connection#error_message(sql)` and `I18n.error_message`. Pass: it
# compiles and answers as CRuby does.
#
# Run (Spinel 2026.11.04.7026, from the repository root; SQLite and zlib
# are linked through FFI, so CRuby runs it over standins/cruby_framework.rb,
# which loads the framework files CRuby can load and stands in for DB, Job
# and Lease):
#   spinel --strict-require -I . -I spikes/phase5 spikes/phase5/error_names.rb -o $TMPDIR/error_names && $TMPDIR/error_names > $TMPDIR/en_spinel.txt
#   ruby -I. -I spikes/phase5 -r standins/cruby_framework spikes/phase5/error_names.rb > $TMPDIR/en_cruby.txt
#   diff $TMPDIR/en_spinel.txt $TMPDIR/en_cruby.txt && echo same
# Output (2026-11-13, framework 19668bc, a shared 4-vCPU cloud machine;
# 99 to 109 s to compile, a 3,778,376-byte binary, no warnings; CRuby
# 3.3.6 prints the same, so `same`):
#   -- the namesakes
#   [ERROR] Logger#error still logs
#   Template::Parser#error raised: spike.html:3: unexpected end of expression in '1 +'
#   spike     ok        Toolchain.report prints
#   Job.handle registered: true
#   WebSocket.subscribe: Cybertrain::WebSocket::Subscription spike feed
#   Hub#subscribe: Cybertrain::Stream::Subscriber
#   Config#release: "v1.2.3"
#   Lease.release: nil
#   DB::Connection#error_message (private, in the raised message): true
#   I18n.error_message: "can't be blank"
#   -- the reporter
#   Cybertrain.error: Cybertrain::ErrorReporter
#   subscribe answered nil nil
#   quiet: ArgumentError "string keys" handled=true
#   quiet: ArgumentError "symbol keys" handled=false
#   quiet: RuntimeError "no context" handled=true
#   report answered nil
#   quiet: RuntimeError "only statement" handled=true
#   quiet: ArgumentError "from a method" handled=true
#   body: "a String" 42 nil nil nil
#   -- handle from a block nested in a block
#   quiet: RuntimeError "nested only statement" handled=true
#   nested: "nested 1 2" 3 nil nil
#   quiet: ArgumentError "in a method, nested" handled=true
#   method, nested: "in a method 3 4" 12 nil
#   -- recorded events
#   ArgumentError: string keys handled=true where=spike context=order_id=7(String)
#   ArgumentError: symbol keys handled=false where=spike context=order_id=x(String)
#   RuntimeError: no context handled=true where=spike context=
#   RuntimeError: only statement handled=true where=spike context=where=body(String)
#   ArgumentError: from a method handled=true where=spike context=
#   RuntimeError: nested only statement handled=true where=spike context=where=nested(String)
#   ArgumentError: in a method, nested handled=true where=spike context=
#   events: 7
# Verdict: PASS, no fallback. Rails' names (`Cybertrain.error`, `report`,
# `handle`, `subscribe`), `Config#release`, `handle` answering the block's
# value (a String, an Integer, nil; nil after a raise, also for a block
# whose only statement is `raise`), and `context:` with Symbol or String
# keys all compile beside their namesakes. `handle`, a yielding method with
# one `rescue A, B, C => e` clause around `value = yield`, compiled when
# called from a block nested in a block, at the top level and inside a
# method: rules 32 and 45's failure did not appear in this shape. Rule 79
# was not retried: its shape (`out << handle { raise "x" }`) is left out,
# the value is assigned to a local first.
require "cybertrain"
require "cybertrain/websocket"
require "cybertrain/lease"
require "cybertrain/cli/toolchain"

module Cybertrain
  # The event a subscriber receives: the readers carry the error_ prefix (D9).
  class ErrorEvent
    attr_reader :error_class, :error_message, :error_where, :error_handled, :error_context

    def initialize(error_class, error_message, error_where, error_handled, error_context)
      @error_class = error_class
      @error_message = error_message
      @error_where = error_where
      @error_handled = error_handled
      @error_context = error_context
    end
  end

  # The base class carries the stub (rule 3); subclasses override it.
  class ErrorSubscriber
    def report(event)
      nil
    end
  end

  class ErrorReporter
    def initialize
      # Seeded with the element type, then emptied (rule 9).
      @subscribers = Array.new(0) { ErrorSubscriber.new }
    end

    def subscribe(subscriber)
      @subscribers << subscriber
      nil
    end

    # Every key and value read back as a String, whichever the caller gave.
    def report(error, handled: true, context: {})
      ctx = { "" => "" }
      ctx.delete("")
      context.each { |k, v| ctx[k.to_s] = v.to_s }
      event = ErrorEvent.new(error.class.name.to_s, error.message, "spike", handled, ctx)
      @subscribers.each { |s| s.report(event) }
      nil
    end

    # Rails' handle: the block's value, or nil after reporting what it
    # raised. The yield goes into a local (rule 90).
    def handle(context: {})
      value = nil
      begin
        value = yield
      rescue JSON::NestingError, JSON::ParserError, StandardError => e
        report(e, handled: true, context: context)
        value = nil
      end
      value
    end
  end

  class Config
    def release
      @spike_release.nil? ? "" : @spike_release
    end

    def release=(value)
      @spike_release = value
    end
  end

  @reporter = ErrorReporter.new

  def self.error = @reporter
end

# Answers nil, as the base's.
class QuietSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    puts "quiet: #{event.error_class} #{event.error_message.inspect} handled=#{event.error_handled}"
    nil
  end
end

EVENTS = Array.new(0) { Cybertrain::ErrorEvent.new("", "", "", false, { "" => "" }) }

# Answers an Array (EVENTS << event), unlike its base.
class RecordingSubscriber < Cybertrain::ErrorSubscriber
  def report(event)
    EVENTS << event
  end
end

module Spike
  def self.ctx_text(event)
    event.error_context.map { |k, v| "#{k}=#{v}(#{k.class})" }.join(",")
  end

  def self.boom(message)
    raise ArgumentError, message
  end

  # handle from a method body.
  def self.from_body
    a = Cybertrain.error.handle { "a String" }
    b = Cybertrain.error.handle { 42 }
    c = Cybertrain.error.handle { nil }
    d = Cybertrain.error.handle(context: { "where" => "body" }) { raise "only statement" }
    e = Cybertrain.error.handle { Spike.boom("from a method") }
    "body: #{a.inspect} #{b.inspect} #{c.inspect} #{d.inspect} #{e.inspect}"
  end

  # handle from a block nested in a block inside a method (rules 32, 45).
  def self.from_nested_blocks
    out = Array.new(0) { "" }
    [3].each do |i|
      [4].each do |j|
        a = Cybertrain.error.handle { "in a method #{i} #{j}" }
        b = Cybertrain.error.handle { i * j }
        d = Cybertrain.error.handle { Spike.boom("in a method, nested") }
        out << "#{a.inspect} #{b.inspect} #{d.inspect}"
      end
    end
    "method, nested: #{out.join}"
  end
end

Cybertrain::DB.connect(":memory:", size: 1)

puts "-- the namesakes"
Cybertrain.logger.error("Logger#error still logs")
begin
  Cybertrain::Template::Parser.parse_statement("1 +", "spike.html", 3)
  puts "Template::Parser: no error"
rescue Cybertrain::Template::SyntaxError => e
  puts "Template::Parser#error raised: #{e.message}"
end
Cybertrain::CLI::Toolchain.report("spike", true, "Toolchain.report prints")
Cybertrain::Job.handle("spike kind") { |payload| puts "job #{payload}" }
puts "Job.handle registered: #{Cybertrain::Job.handler_index("spike kind") >= 0}"
sub = Cybertrain::WebSocket.subscribe("spike feed", "ws://127.0.0.1:1/x")
puts "WebSocket.subscribe: #{sub.class.name} #{sub.sub_name}"
hub = Cybertrain::Stream::Hub.new(10)
subscriber = hub.subscribe(["a", "b"])
puts "Hub#subscribe: #{subscriber.class.name}"
Cybertrain.config.release = "v1.2.3"
puts "Config#release: #{Cybertrain.config.release.inspect}"
puts "Lease.release: #{Cybertrain::Lease.release("spike lease", "me").inspect}"
begin
  Cybertrain::DB.with { |c| c.execute("SELEC 1", []) }
  puts "DB::Connection#error_message: no error"
rescue Cybertrain::DB::Error => e
  puts "DB::Connection#error_message (private, in the raised message): #{e.message.include?("(sql: SELEC 1)")}"
end
puts "I18n.error_message: #{I18n.error_message("", :title, :blank).inspect}"

puts "-- the reporter"
puts "Cybertrain.error: #{Cybertrain.error.class.name}"
r1 = Cybertrain.error.subscribe(QuietSubscriber.new)
r2 = Cybertrain.error.subscribe(RecordingSubscriber.new)
puts "subscribe answered #{r1.inspect} #{r2.inspect}"
begin
  Spike.boom("string keys")
rescue StandardError => e
  Cybertrain.error.report(e, context: { "order_id" => 7 })
end
begin
  Spike.boom("symbol keys")
rescue StandardError => e
  Cybertrain.error.report(e, handled: false, context: { order_id: "x" })
end
begin
  raise "no context"
rescue StandardError => e
  r3 = Cybertrain.error.report(e)
  puts "report answered #{r3.inspect}"
end
puts Spike.from_body
puts "-- handle from a block nested in a block"
[1].each do |i|
  [2].each do |j|
    a = Cybertrain.error.handle { "nested #{i} #{j}" }
    b = Cybertrain.error.handle { i + j }
    c = Cybertrain.error.handle { nil }
    d = Cybertrain.error.handle(context: { where: "nested" }) { raise "nested only statement" }
    puts "nested: #{a.inspect} #{b.inspect} #{c.inspect} #{d.inspect}"
  end
end
puts Spike.from_nested_blocks
puts "-- recorded events"
EVENTS.each do |ev|
  puts "#{ev.error_class}: #{ev.error_message} handled=#{ev.error_handled} where=#{ev.error_where} context=#{Spike.ctx_text(ev)}"
end
puts "events: #{EVENTS.size}"
