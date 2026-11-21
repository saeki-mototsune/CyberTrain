# spinel-http phase 1, Task 1, step 3: the log sink and the opaque log
# context as base classes the HTTP layer defines, with subclasses the
# framework installs at load. A record, not a test.
#
# Run (2026-11-21, Linux x86_64, gcc 13.3.0, 4 vCPU, from spikes/spinel-http/;
# binaries kept outside the package, rule 98). The fork is the pinned
# 2026.11.15.7033 (a2f3bfaa) on PATH; upstream is matz/spinel's release
# 2026.10.25 (2814693f), built with toolchain.rb's four steps into
# ~/.spinel-upstream/2026.10.25. spin builds only bin/*.rb, so `spin run`
# does not reach a top-level record; `spin flags` gives the package's flags
# (the fork's says --strict-require, upstream's --require-gate, the same
# flag under another name):
#   spinel $(spin flags) subclass_log.rb -o $TMPDIR/subclass_log && $TMPDIR/subclass_log
#   PATH=$U:$PATH spinel $(PATH=$U:$PATH spin flags) subclass_log.rb -o $TMPDIR/s-up && $TMPDIR/s-up
# Output, the same under the fork, upstream and CRuby 3.3.6 (`ruby
# subclass_log.rb`), each compile 2 s:
#   MyLog#swap_context got request_id req-1
#   first swap answered NONE: true
#   second swap answered the stored context: true
#   error [req-1]: handler raised
#   other thread: switch mine, inside req-1, after -
#   main thread after: -
#   info [-]: main
#   current answers the stored object: true
#   swap answered it back: true
# Verdict: PASS under both. A MyScope stored in SpikeRequest's
# HttpLogContext-typed ivar and handed to MyLog#swap_context answers its
# request_id there: a subclass-only method called on a value the layer
# typed as the base, with no is_a? and no case/when (rule 47). The same
# object goes through MySwitch#swap into the thread slot (Logger.swap_scope's
# shape) and comes back `equal?`. HttpLogSwitch.installed, replaced at load
# by a MySwitch in the Params.max_page shape, is the one a second thread
# calls (label "mine"), and rule 103's save-yield-ensure puts the thread
# back to NO_SCOPE. The one thing the switch must do by hand is map the
# layer's NONE to its own NO_SCOPE both ways (a base HttpLogContext has no
# request_id; CRuby raised NoMethodError on the first draft that stored it).

# --- What the HTTP layer would define (no cybertrain concept) -------------

# An opaque per-request log context: no behaviour of its own.
class HttpLogContext
end

class HttpLogContextNone
  NONE = HttpLogContext.new
end

# The sink the server writes to; the base writes to stdout here (stderr in
# Task 2) so the record shows it.
class HttpLog
  def initialize
    @context = HttpLogContextNone::NONE
  end

  def info(msg) = line("info", msg)
  def warn(msg) = line("warn", msg)
  def error(msg) = line("error", msg)

  def line(level, msg)
    puts "#{level}: #{msg}"
    nil
  end

  # Makes ctx the sink's context and answers the previous one.
  def swap_context(ctx)
    previous = @context
    @context = ctx
    previous
  end
end

# The thread's context, as the server reads it: the base keeps none.
class HttpLogSwitch
  def label = "base"
  def current = HttpLogContextNone::NONE
  def swap(ctx) = HttpLogContextNone::NONE

  # Module-level ivar in the Params.max_page shape (rules 18, 64).
  @installed = HttpLogSwitch.new

  def self.installed
    @installed
  end

  def self.installed=(switch)
    @installed = switch
  end
end

# A request as the HTTP layer holds it: the context in an ivar the layer
# types as HttpLogContext (Request#log_context in Task 2).
class SpikeRequest
  attr_reader :log_context

  def initialize
    @log_context = HttpLogContextNone::NONE
  end

  def log_context=(ctx)
    @log_context = ctx
  end
end

# What the server does around a streamed body's writer thread and a
# handler's exception: swap the request's context in, run, swap back
# (rule 103's save-yield-ensure).
def run_under(ctx)
  saved = HttpLogSwitch.installed.swap(ctx)
  value = yield
  value
ensure
  HttpLogSwitch.installed.swap(saved)
end

# --- What cybertrain would install (Logger::Scope, Logger, ScopeSwitch) ---

class MyScope < HttpLogContext
  attr_reader :request_id

  def initialize(request_id)
    @request_id = request_id
  end
end

# Logger's class side: the thread slot holds a MyScope (Logger.swap_scope).
class MyLogger
  KEY = :spike_log_scope
  NO_SCOPE = MyScope.new("-")

  def self.current_scope
    value = Thread.current[KEY]
    value.nil? ? NO_SCOPE : value
  end

  def self.swap_scope(scope)
    previous = MyLogger.current_scope
    Thread.current[KEY] = scope.equal?(NO_SCOPE) ? nil : scope
    previous
  end
end

class MyLog < HttpLog
  def line(level, msg)
    puts "#{level} [#{MyLogger.current_scope.request_id}]: #{msg}"
    nil
  end

  # Reads a subclass-only method on a value the HTTP layer typed as the base.
  def swap_context(ctx)
    previous = super(ctx)
    unless ctx.equal?(HttpLogContextNone::NONE)
      puts "MyLog#swap_context got request_id #{ctx.request_id}"
    end
    previous
  end
end

# The switch cybertrain installs: base-typed contexts in, MyLogger's slot.
class MySwitch < HttpLogSwitch
  def label = "mine"
  def current = MyLogger.current_scope
  def swap(ctx)
    scope = ctx.equal?(HttpLogContextNone::NONE) ? MyLogger::NO_SCOPE : ctx
    previous = MyLogger.swap_scope(scope)
    if previous.equal?(MyLogger::NO_SCOPE)
      HttpLogContextNone::NONE
    else
      previous
    end
  end
end

# Installed at load, before any thread starts (logger.rb in Task 2).
HttpLogSwitch.installed = MySwitch.new

# --- The checks ------------------------------------------------------------

req = SpikeRequest.new
req.log_context = MyScope.new("req-1")
log = MyLog.new
first = log.swap_context(req.log_context)
puts "first swap answered NONE: #{first.equal?(HttpLogContextNone::NONE)}"
back = log.swap_context(HttpLogContextNone::NONE)
puts "second swap answered the stored context: #{back.equal?(req.log_context)}"

# The class-level slot, read and swapped from another thread.
seen = []
t = Thread.new do
  seen << HttpLogSwitch.installed.label
  run_under(req.log_context) do
    seen << MyLogger.current_scope.request_id
    log.error("handler raised")
  end
  seen << MyLogger.current_scope.request_id
end
t.join
puts "other thread: switch #{seen[0]}, inside #{seen[1]}, after #{seen[2]}"
puts "main thread after: #{MyLogger.current_scope.request_id}"
log.info("main")

# A context round-tripped through the switch keeps its subclass.
ctx2 = MyScope.new("req-2")
HttpLogSwitch.installed.swap(ctx2)
cur = HttpLogSwitch.installed.current
puts "current answers the stored object: #{cur.equal?(ctx2)}"
prev = HttpLogSwitch.installed.swap(HttpLogContextNone::NONE)
puts "swap answered it back: #{prev.equal?(ctx2)}"
