# Phase 5a spike, item 4 (spec section 16): assert_raises given a class,
# beside today's String form, matched by class name (rules 46, 47); and a
# top-level method called both with a block and without one (the shape of
# perform_enqueued_jobs and assert_broadcasts). A record, not a test.
#
# Run (Spinel 2026.11.04.7026, from the repository root):
#   spinel --strict-require -I . spikes/phase5/assert_raises.rb -o $TMPDIR/ar && $TMPDIR/ar > $TMPDIR/ar_spinel.txt
#   ruby -I. spikes/phase5/assert_raises.rb > $TMPDIR/ar_cruby.txt
#   diff $TMPDIR/ar_spinel.txt $TMPDIR/ar_cruby.txt && echo same
# Output (6 s to compile; CRuby 3.3.6 prints the same, so `same`):
#   Class ArgumentError: bad arg
#   Class DB::Error: no such table: x
#   Class DB::Error, a subclass raised: deeper
#   Class StandardError, a RuntimeError raised: plain
#   String form: FAIL [RecordNotFound] exception expected, not | Class: <KeyError> | Message: <"not it">
#   String form matching: db
#   no argument: anything
#   Class mismatch: FAIL [ArgumentError] exception expected, not | Class: <Cybertrain::DB::Error> | Message: <"db said no">
#   nothing raised: FAIL ArgumentError expected but nothing was raised.
#   is_a?(DB::Error) on a rescued subclass: true
#   Class IndexError, a KeyError raised: key not found: "k"
#   perform_enqueued_jobs with a block: 2
#   perform_enqueued_jobs without one: 3
#   10 assertions
# The first version walked `superclass` to the top and the compiled program
# stopped with "undefined method 'superclass' for module RuntimeError
# (NoMethodError)": Ruby's own exception classes answer no superclass under
# Spinel (a user class does, up to its first builtin ancestor). Hence
# BUILTIN_PARENTS. One parameter takes a Class or a String (boxed), and
# `case expected when String` / `is_a?(String)` tell them apart.
# Verdict: PASS with the parents table (Minitest's subclass match);
# a top-level method with and without a block (block_given?): PASS.
require "cybertrain/db/error"

module Spike
  class AssertionFailed < StandardError
  end

  class Deep < Cybertrain::DB::Error
  end

  @assertions = 0
  @performed = 0

  def self.count = @assertions += 1
  def self.assertions = @assertions
  def self.performed = @performed
  def self.perform_one = @performed += 1

  # The name of a class or the text given: what the raised class (or one of
  # its superclasses) must be named. A Class is matched exactly by name
  # along the superclass chain, as Minitest's is_a? would; a String keeps
  # today's substring match.
  def self.expected_text(expected)
    case expected
    when String then expected
    else expected.name.to_s
    end
  end

  # Ruby's own exception classes answer no `superclass` under Spinel
  # ("undefined method 'superclass' for module RuntimeError"), so above the
  # first builtin the chain is read from this table of their parents.
  BUILTIN_PARENTS = {
    "Exception" => "", "StandardError" => "Exception", "ScriptError" => "Exception",
    "NoMemoryError" => "Exception", "SecurityError" => "Exception", "SignalException" => "Exception",
    "SystemExit" => "Exception", "SystemStackError" => "Exception", "Interrupt" => "SignalException",
    "LoadError" => "ScriptError", "NotImplementedError" => "ScriptError", "SyntaxError" => "ScriptError",
    "ArgumentError" => "StandardError", "EncodingError" => "StandardError", "FiberError" => "StandardError",
    "IOError" => "StandardError", "IndexError" => "StandardError", "LocalJumpError" => "StandardError",
    "NameError" => "StandardError", "RangeError" => "StandardError", "RegexpError" => "StandardError",
    "RuntimeError" => "StandardError", "SystemCallError" => "StandardError", "ThreadError" => "StandardError",
    "TypeError" => "StandardError", "ZeroDivisionError" => "StandardError", "EOFError" => "IOError",
    "KeyError" => "IndexError", "StopIteration" => "IndexError", "ClosedQueueError" => "StopIteration",
    "NoMethodError" => "NameError", "FloatDomainError" => "RangeError", "FrozenError" => "RuntimeError",
    "UncaughtThrowError" => "ArgumentError"
  }.freeze

  def self.matches?(expected, raised)
    if expected.is_a?(String)
      return true if expected == ""

      return raised.name.to_s.include?(expected)
    end
    want = expected.name.to_s
    k = raised
    name = k.name.to_s
    builtin = false
    loop do
      return true if name == want

      parent = BUILTIN_PARENTS[name]
      if parent.nil? && !builtin
        k = k.superclass
        name = k.name.to_s
      else
        builtin = true
        return false if parent.nil? || parent == ""

        name = parent
      end
    end
    false
  end

  # Rule 47's report: is_a? with the class given as a value.
  def self.is_a_says(e, expected) = e.is_a?(expected)
end

def assert_raises(expected = "")
  Spike.count
  message = ""
  raised = false
  begin
    yield
  rescue StandardError => e
    raised = true
    message = e.message
    unless Spike.matches?(expected, e.class)
      want = Spike.expected_text(expected)
      text = "[#{want}] exception expected, not\nClass: <#{e.class.name}>\nMessage: <#{e.message.inspect}>"
      raise Spike::AssertionFailed, text
    end
  end
  unless raised
    want = Spike.expected_text(expected)
    text = "#{want == "" ? "StandardError" : want} expected but nothing was raised."
    raise Spike::AssertionFailed, text
  end
  message
end

# Called with a block (perform what the block enqueues; answers how many)
# and without one (perform everything queued; answers how many).
def perform_enqueued_jobs
  before = Spike.performed
  if block_given?
    queued = yield
    queued.times { Spike.perform_one }
  else
    3.times { Spike.perform_one }
  end
  Spike.performed - before
end

def check(label)
  value = yield
  puts "#{label}: #{value}"
rescue Spike::AssertionFailed => e
  puts "#{label}: FAIL #{e.message.gsub("\n", " | ")}"
end

check("Class ArgumentError") { assert_raises(ArgumentError) { raise ArgumentError, "bad arg" } }
check("Class DB::Error") { assert_raises(Cybertrain::DB::Error) { raise Cybertrain::DB::Error, "no such table: x" } }
check("Class DB::Error, a subclass raised") { assert_raises(Cybertrain::DB::Error) { raise Spike::Deep, "deeper" } }
check("Class StandardError, a RuntimeError raised") { assert_raises(StandardError) { raise "plain" } }
check("String form") { assert_raises("RecordNotFound") { raise KeyError, "not it" } }
check("String form matching") { assert_raises("Error") { raise Cybertrain::DB::Error, "db" } }
check("no argument") { assert_raises { raise "anything" } }
check("Class mismatch") { assert_raises(ArgumentError) { raise Cybertrain::DB::Error, "db said no" } }
check("nothing raised") { assert_raises(ArgumentError) { 1 } }
begin
  raise Spike::Deep, "d"
rescue StandardError => e
  puts "is_a?(DB::Error) on a rescued subclass: #{Spike.is_a_says(e, Cybertrain::DB::Error)}"
end
check("Class IndexError, a KeyError raised") { assert_raises(IndexError) { {}.fetch("k") } }
check("perform_enqueued_jobs with a block") { perform_enqueued_jobs { 2 } }
check("perform_enqueued_jobs without one") { perform_enqueued_jobs }
puts "#{Spike.assertions} assertions"
