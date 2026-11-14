require "stringio"
require "cybertrain/logger"
require "cybertrain/test"
require_relative "support/log_capture"

# The per-thread log scope (spec sections 12.2 "thread-local" and 12.4,
# plan D5): one Logger::Scope in the Thread.current[Logger::SCOPE_KEY]
# slot, its request id and tags on every line logged meanwhile, and
# `Cybertrain.logger.tagged`. Meant to be compiled (`spin test
# test/logger_scope.rb`), where the threads are real; it also runs under
# CRuby. Restores go through plain helpers' `ensure` (pre-flight ruling
# G4); threads are started through methods (spikes/NOTES.md rule 21) and
# meet through Queue waits, not timing (ruling S4: `sleep 0` does not
# switch threads).

NOON = Time.utc(2026, 11, 11, 12)

def no_context
  h = { "" => "" }
  h.delete("")
  h
end

# A Scope whose only tag is the request id `id`.
def scope_for(id)
  tags = Array.new(0) { "" }
  tags << id
  context = no_context
  Cybertrain::Logger::Scope.new(id, "GET", "/n", "", tags, 0, context)
end

def no_scope?
  Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

# Turns JSON lines on for the block, off again after it.
def json_during
  Cybertrain::Logger.json_lines = true
  _value = yield
  nil
ensure
  Cybertrain::Logger.json_lines = false
end

# What another thread reads as its current request id and where.
def read_on_thread
  out = Queue.new
  t = Thread.new { out << read_scope_here }
  t.join
  out.pop
end

def read_scope_here
  scope = Cybertrain::Logger.current_scope
  "id=#{scope.scope_request_id.inspect} where=#{scope.scope_where.inspect} no_scope=#{no_scope?}"
end

test "tagged adds tags for the block and restores them, also after a raise" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  travel_to(NOON) do
    logger.tagged("billing") do
      logger.info("a")
      logger.tagged("x", "y") { logger.info("b") }
      assert_raises("RuntimeError") { logger.tagged("inner") { raise "boom" } }
      logger.info("c")
    end
    logger.info("d")
  end
  assert_equal "2026-11-11T12:00:00.000Z INFO [billing] a\n2026-11-11T12:00:00.000Z INFO [billing] [x] [y] b\n" \
               "2026-11-11T12:00:00.000Z INFO [billing] c\n2026-11-11T12:00:00.000Z INFO d\n", sink.string
  assert no_scope?
end

test "tagged answers the block's value" do
  logger = Cybertrain::Logger.new(StringIO.new)
  assert_equal "s", logger.tagged("t") { "s" }
  assert_equal 3, logger.tagged("t") { 3 }
  assert_nil logger.tagged("t") { nil }
end

test "Cybertrain.logger.tagged tags the default logger's lines" do
  log = capture_log { Cybertrain.logger.tagged("billing") { Cybertrain.logger.info("charged 300") } }
  assert log.include?(" INFO [billing] charged 300\n")
end

test "a Scope's request id and tags reach the line; tagged keeps the request id apart in JSON" do
  id = "3f2a9c1e-6c1d-4f0b-9a52-0d1e2f3a4b5c"
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  with_scope(scope_for(id)) do
    travel_to(NOON) do
      logger.tagged("billing") { logger.info("charged 300") }
      json_during { logger.tagged("billing") { logger.info("charged 300") } }
    end
  end
  lines = sink.string.split("\n")
  assert_equal 2, lines.size
  assert_equal "2026-11-11T12:00:00.000Z INFO [#{id}] [billing] charged 300", lines[0]
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","request_id":"#{id}","tags":["billing"],"message":"charged 300"}),
               lines[1]
  assert no_scope?
end

test "a Scope set on one thread is not seen on another" do
  other = ""
  mine = ""
  with_scope(scope_for("r1")) do
    other = read_on_thread
    mine = Cybertrain::Logger.current_scope.scope_request_id
  end
  assert_equal %(id="" where="" no_scope=true), other
  assert_equal "r1", mine
end

test "swap_scope answers the previous Scope and stores nil for NO_SCOPE; reset_scope empties the slot" do
  first = scope_for("r1")
  assert Cybertrain::Logger.swap_scope(first).equal?(Cybertrain::Logger::NO_SCOPE)
  assert Thread.current[Cybertrain::Logger::SCOPE_KEY].equal?(first)
  assert Cybertrain::Logger.swap_scope(Cybertrain::Logger::NO_SCOPE).equal?(first)
  assert_nil Thread.current[Cybertrain::Logger::SCOPE_KEY]
  Cybertrain::Logger.swap_scope(scope_for("r2"))
  assert_nil Cybertrain::Logger.reset_scope
  assert_nil Thread.current[Cybertrain::Logger::SCOPE_KEY]
  assert no_scope?
end

test "scope_where= writes the thread's own Scope" do
  where = ""
  with_scope(scope_for("r1")) do
    Cybertrain::Logger.current_scope.scope_where = "ArticlesController#show"
    where = Cybertrain::Logger.current_scope.scope_where
  end
  assert_equal "ArticlesController#show", where
end

test "NO_SCOPE, shared by every thread, is never written: scope_where= on it does nothing" do
  assert no_scope?
  Cybertrain::Logger.current_scope.scope_where = "x"
  assert_equal "", Cybertrain::Logger.current_scope.scope_where
  assert_equal "", Cybertrain::Logger::NO_SCOPE.scope_where
  assert_equal %(id="" where="" no_scope=true), read_on_thread
end

# NO_SCOPE's containers are frozen (review I1, ruling S1): a write through
# `scope_tags` or `scope_context`, or through the context a `with_tags` copy
# shares with it, raises FrozenError (compiled too) instead of changing the
# Scope every thread without one of its own shares.
test "NO_SCOPE's tags and context cannot be written, nor the context a with_tags copy shares" do
  assert no_scope?
  assert_raises("FrozenError") { Cybertrain::Logger.current_scope.scope_tags << "x" }
  assert_raises("FrozenError") { Cybertrain::Logger.current_scope.scope_context["job.id"] = "1" }
  copy = Cybertrain::Logger::NO_SCOPE.with_tags(["a"])
  assert_raises("FrozenError") { copy.scope_context["job.id"] = "1" }
  copy.scope_tags << "b"
  assert_equal "a|b", copy.scope_tags.join("|")
  assert_equal 0, Cybertrain::Logger::NO_SCOPE.scope_tags.size
  assert_equal 0, Cybertrain::Logger::NO_SCOPE.scope_context.size
  assert_equal %(id="" where="" no_scope=true), read_on_thread
end

test "with_tags is a copy with the tags appended and the request id's place kept" do
  base = scope_for("r1")
  more = base.with_tags(["a", "b"])
  assert_equal "r1|a|b", more.scope_tags.join("|")
  assert_equal 0, more.scope_id_tag
  assert_equal "r1", more.scope_request_id
  assert_equal "r1", base.scope_tags.join("|")
  assert_equal "a", Cybertrain::Logger::NO_SCOPE.with_tags(["a"]).scope_tags.join("|")
  assert_equal -1, Cybertrain::Logger::NO_SCOPE.with_tags(["a"]).scope_id_tag
  assert_equal 0, Cybertrain::Logger::NO_SCOPE.scope_tags.size
end

# Concurrent `tagged` (ruling S3): each thread swaps in its own Scope and
# tags it; inside its block it posts its number to the other thread's
# inbox and waits (up to 5 s) on its own for the other's, so both are
# inside their blocks at once whatever the timing (no sleep needed: a
# Queue wait parks the thread, spikes/NOTES.md rule 85). Each then reads
# the scope and logs; thread 2's block raises. The two Queues are passed
# as Queues: `mail[i].pop(timeout: 5)` on an Array element is compiled as
# Array#pop ("no implicit conversion of Hash into Integer").
def tagging_thread(logger, n, out, inbox, outbox)
  Thread.new { tag_work(logger, n, out, inbox, outbox) }
end

def tag_work(logger, n, out, inbox, outbox)
  previous = Cybertrain::Logger.swap_scope(scope_for("r#{n}"))
  msg = rescued_message { tagged_block(logger, n, out, inbox, outbox) }
  after = Cybertrain::Logger.current_scope.scope_tags.join("|")
  Cybertrain::Logger.swap_scope(previous)
  out << "thread #{n}: #{msg}; after: #{after}; swapped back: #{no_scope?}"
  nil
end

def tagged_block(logger, n, out, inbox, outbox)
  logger.tagged("t#{n}") do
    outbox << n
    met = inbox.pop(timeout: 5)
    seen = Cybertrain::Logger.current_scope.scope_tags.join("|")
    logger.info("in #{n}")
    out << "thread #{n} inside: #{seen}, met #{met.nil? ? "nobody" : "thread #{met}"}"
    raise "boom #{n}" if n == 2

    seen
  end
end

# assert_raises's shape: a rescuing yielder answering what happened.
def rescued_message
  value = yield
  "answered #{value}"
rescue StandardError => e
  "rescued #{e.message}"
end

def drained(queue)
  list = Array.new(0) { "" }
  list << queue.pop until queue.empty?
  list
end

test "tagged on concurrent threads: each sees its own tags, and a raising block restores its thread's" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  out = Queue.new
  first = Queue.new
  second = Queue.new
  threads = [tagging_thread(logger, 1, out, first, second)]
  threads << tagging_thread(logger, 2, out, second, first)
  threads.each(&:join)
  assert_equal ["thread 1 inside: r1|t1, met thread 2", "thread 1: answered r1|t1; after: r1; swapped back: true",
                "thread 2 inside: r2|t2, met thread 1", "thread 2: rescued boom 2; after: r2; swapped back: true"],
               drained(out).sort
  assert_equal ["INFO [r1] [t1] in 1", "INFO [r2] [t2] in 2"], sink.string.split("\n").map { |l| l.byteslice(25, l.bytesize - 25).to_s }.sort
  assert no_scope?
end

# Tags and messages of other encodings (Task 2's review, I2): a text line
# is built from the bytes, so a UTF-8 tag beside a binary or ISO-8859-1
# message never raises into the caller (Encoding::CompatibilityError under
# CRuby); the bytes are written as they are.
def latin1(text)
  text.dup.force_encoding("ISO-8859-1")
end

test "a non-ASCII tag beside a binary or ISO-8859-1 message is written byte for byte" do
  line = Cybertrain::Logger.format_line("INFO", ["é"], -1, "\xFF".b)
  assert_equal "INFO [é] \xFF\n".b, line.b.byteslice(25, line.bytesize - 25)
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  with_scope(scope_for("日本")) do
    logger.tagged("é") do
      logger.info("\xFF\xFE".b)
      logger.info(latin1("caf\xE9"))
      logger.info("plain")
    end
  end
  lines = sink.string.b.split("\n".b)
  assert_equal 3, lines.size
  assert_equal "INFO [日本] [é] \xFF\xFE".b, lines[0].byteslice(25, lines[0].bytesize - 25)
  assert_equal "INFO [日本] [é] caf\xE9".b, lines[1].byteslice(25, lines[1].bytesize - 25)
  assert_equal "INFO [日本] [é] plain".b, lines[2].byteslice(25, lines[2].bytesize - 25)
end

test "JSON lines with a non-ASCII tag and a binary or ISO-8859-1 message stay valid" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  json_during do
    travel_to(NOON) do
      logger.tagged("é") do
        logger.info("\xFF".b)
        logger.info(latin1("caf\xE9"))
      end
    end
  end
  assert_equal %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","tags":["é"],"message":"\\ufffd"}\n) +
               %({"time":"2026-11-11T12:00:00.000Z","level":"INFO","tags":["é"],"message":"caf\\ufffd"}\n),
               sink.string
end

# A write that fails (Task 2's review, M3: a closed io, a dead pipe) is
# dropped: logging never raises into its caller, and the lock is free.
test "a logger whose io is closed drops the line and does not raise; the next logger still writes" do
  closed = StringIO.new
  closed.close
  assert_nil Cybertrain::Logger.new(closed).info("lost")
  sink = StringIO.new
  Cybertrain::Logger.new(sink).info("kept")
  assert sink.string.end_with?(" INFO kept\n")
end

# LogCapture.entries reads a line's time by its shape (Task 2's review, M8),
# so a continuation line whose first word ends in "Z" stays as it is.
test "LogCapture.entries drops only a real time and the tags" do
  text = "fooZ ERROR x\n2026-11-11T12:00:00.000Z ERROR [r1] [billing] y\n2026-11-11T12:00:00.000 ERROR z"
  assert_equal ["fooZ ERROR x", "ERROR y", "2026-11-11T12:00:00.000 ERROR z"], LogCapture.entries(text)
end

Cybertrain::Test.run!
