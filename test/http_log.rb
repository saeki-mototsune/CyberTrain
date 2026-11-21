# The HTTP layer's log sink, log context and context switch
# (cybertrain/http/log.rb), compiled without the rest of the framework:
# no cybertrain/logger, no test harness (which loads the Logger through the
# Clock). Each check prints `ok   <name>` or `FAIL <name>`; a failure exits 1.
require "stringio"
require "cybertrain/http/log"

$failures = 0

def check(name, passed)
  if passed
    puts "ok   #{name}"
  else
    puts "FAIL #{name}"
    $failures += 1
  end
  nil
end

# A context carrying an id, as a framework's subclass would.
class IdContext < Cybertrain::HttpLogContext
  attr_reader :context_id

  def initialize(id)
    @context_id = id
  end
end

# A switch that keeps the context per thread, as Logger::ScopeSwitch does.
class ThreadSwitch < Cybertrain::HttpLogSwitch
  KEY = :http_log_test_context

  def current
    value = Thread.current[KEY]
    value.nil? ? Cybertrain::HttpLogContext::NONE : value
  end

  def swap(ctx)
    previous = current
    Thread.current[KEY] = ctx.equal?(Cybertrain::HttpLogContext::NONE) ? nil : ctx
    previous
  end
end

base = Cybertrain::HttpLogSwitch.installed
check "the installed switch is the base, and its current context is NONE",
      base.current.equal?(Cybertrain::HttpLogContext::NONE)
check "the base switch's swap stores nothing and answers NONE",
      base.swap(IdContext.new("req-0")).equal?(Cybertrain::HttpLogContext::NONE) &&
        base.current.equal?(Cybertrain::HttpLogContext::NONE)

Cybertrain::HttpLogSwitch.installed = ThreadSwitch.new
ctx = IdContext.new("req-1")
first = IdContext.new("req-first")
seen = Array.new(0) { Cybertrain::HttpLogContext::NONE }
t = Thread.new do
  seen << Cybertrain::HttpLogSwitch.installed.swap(first)
  seen << Cybertrain::HttpLogSwitch.installed.swap(ctx)
  seen << Cybertrain::HttpLogSwitch.installed.current
  seen << Cybertrain::HttpLogSwitch.installed.swap(Cybertrain::HttpLogContext::NONE)
  seen << Cybertrain::HttpLogSwitch.installed.current
end
t.join
check "an installed subclass switch, from a second thread: swap answers the previous context",
      seen[0].equal?(Cybertrain::HttpLogContext::NONE) && seen[1].equal?(first)
check "an installed subclass switch, from a second thread: current there is the swapped-in context",
      seen[2].equal?(ctx) && ctx.context_id == "req-1"
check "an installed subclass switch, from a second thread: swapping NONE back empties it",
      seen[3].equal?(ctx) && seen[4].equal?(Cybertrain::HttpLogContext::NONE)
check "the main thread's context was never touched",
      Cybertrain::HttpLogSwitch.installed.current.equal?(Cybertrain::HttpLogContext::NONE)
Cybertrain::HttpLogSwitch.installed = base

saved = $stderr
captured = StringIO.new
$stderr = captured
log = Cybertrain::HttpLog.new
answered_nil = log.debug("d").nil?
answered_nil = log.info("i").nil? && answered_nil
answered_nil = log.warn("w").nil? && answered_nil
answered_nil = log.error("x").nil? && answered_nil
$stderr = saved
check "HttpLog writes `level: msg` lines on stderr and drops debug",
      captured.string == "info: i\nwarn: w\nerror: x\n"
check "each HttpLog call answers nil", answered_nil

puts "#{$failures} failures"
exit(1) if $failures > 0
