# Phase 5b spike, item 7 (spec section 16; plan D5): a per-thread log scope
# under Spinel, in a program with the whole framework, the db pool holding
# a Connection under its Thread.current key (a transaction) and
# I18n.locale set per thread (spikes/phase4b/thread_locale.rb's program
# extended, NOTES rule 102). A record, not a test.
#
# What it asks:
# 1. One object in one slot: a Scope (String ivars, an Array<String> ivar,
#    a Hash{String => String} ivar, an Integer ivar, `scope_*` readers, one
#    writer, `with_tags`) stored in Thread.current[:cybertrain_log_scope]
#    by `swap_scope` (nil for NO_SCOPE) and read by `current_scope`
#    (NO_SCOPE for nil). Four threads, each started through a method (rule
#    21), store their own, `sleep 0`, open a transaction, read theirs back.
# 2. The two-key form: a String under one key, an Array<String> under
#    another, the same four threads.
# 3. `tagged`'s shape: an instance method `def tagged(*tags) =
#    LogScope.tagged_during(tags) { yield }` over a module function that
#    saves the slot, sets a copy with the tags appended, yields into a
#    local (rule 90) and restores in `ensure` (rule 103); nested three
#    deep, the innermost block raising and rescued by a rescuing yielder
#    (assert_raises's shape); blocks answering a String, an Integer and
#    nil, and inside the threads too.
# Pass: every thread prints its own values under SPINEL_WORKERS=1 and 4,
# the slot is restored after the raise, each block's value comes back.
#
# A record of the run at framework 19668bc: it no longer runs at later
# revisions as written below. Its CRuby run fails at load, since
# standins/cruby_framework.rb requires cybertrain/websocket, which now
# loads cybertrain/http/gzip_ffi.rb (`ffi_lib`, which CRuby has not); and
# its Spinel build was not tried again beside the framework's own Scope
# (cybertrain/logger.rb, phase 5b), which this program's stand-ins
# predate. To run it again, run it over a checkout of 19668bc
# (`git worktree add <dir> 19668bc`). What it showed is kept by the
# framework's own programs: test/logger_scope.rb and
# test/log_tags_background.rb.
#
# Run (Spinel 2026.11.04.7026, from the repository root; SQLite and zlib
# are linked through FFI, so CRuby runs it over standins/cruby_framework.rb,
# whose transaction holds a stand-in connection under the pool's key):
#   spinel --strict-require -I . -I spikes/phase5 spikes/phase5/thread_scope.rb -o $TMPDIR/thread_scope
#   SPINEL_WORKERS=1 $TMPDIR/thread_scope > $TMPDIR/ts_w1.txt
#   SPINEL_WORKERS=4 $TMPDIR/thread_scope > $TMPDIR/ts_w4.txt
#   ruby -I. -I spikes/phase5 -r standins/cruby_framework spikes/phase5/thread_scope.rb > $TMPDIR/ts_cruby.txt
#   diff $TMPDIR/ts_w1.txt $TMPDIR/ts_cruby.txt; diff $TMPDIR/ts_w4.txt $TMPDIR/ts_cruby.txt
# The threads' lines are sorted before printing, so the files compare
# whatever order the threads ran in; each line says what the thread read
# against what it stored ("own" or "MIXED").
# Output (2026-11-13, framework 19668bc, a shared 4-vCPU cloud machine; 91
# to 93 s to compile, a 3,643,992-byte binary, no warnings). The same 31
# lines under SPINEL_WORKERS=1, SPINEL_WORKERS=4 (three runs each) and
# CRuby 3.3.6:
#   -- one slot
#   main before: NO_SCOPE
#   one slot, thread 1: own id=req-1 GET /n/1 where=W1 tags=req-1|t1 id_tag=0 context=job.id:1 locale=en held=true
#   one slot, thread 2: own id=req-2 GET /n/2 where=W2 tags=req-2|t2 id_tag=0 context=job.id:2 locale=ja held=true
#   one slot, thread 3: own id=req-3 GET /n/3 where=W3 tags=req-3|t3 id_tag=0 context=job.id:3 locale=en held=true
#   one slot, thread 4: own id=req-4 GET /n/4 where=W4 tags=req-4|t4 id_tag=0 context=job.id:4 locale=ja held=true
#   swap back, thread 1: answered req-1, now NO_SCOPE
#   (and threads 2 to 4 alike)
#   tagged, thread 1: req-1|t1|in1; after: req-1|t1
#   (and threads 2 to 4 alike)
#   threads that read after another thread stored: 3 of 4
#   main after: NO_SCOPE raw nil
#   -- two keys
#   two keys, thread 1: own id=req-1 tags=req-1|k1
#   (and threads 2 to 4 alike)
#   main after: id "" tags []
#   -- tagged
#   three deep: req-main|one|two|three
#   innermost: rescued boom
#   after the raise: req-main|one|two
#   an Integer block answered 42; now req-main|one
#   a String block answered "a String"; a nil block answered nil
#   restored: req-main id_tag=0
#   outermost: rescued only statement; restored: req-main
#   with no scope: alone; after: NO_SCOPE
# The first version yielded with `sleep 0` alone: under SPINEL_WORKERS=1 the
# threads then ran one after another (0 of 4 read after another stored),
# which proves nothing; the timed `sleep 0.002` makes them interleave under
# both worker counts (3 of 4, the most possible: the last to store has no
# later store before its read).
# Verdict: PASS, no fallback. One Scope object in one Thread.current slot
# (D5), beside I18n's Symbol and the pool's Connection; `swap_scope` /
# `current_scope` with NO_SCOPE stored as nil; a reader's writer
# (`scope_where=`) on the thread's own Scope; and `tagged` as an instance
# method forwarding `{ yield }` to a save-yield-ensure module function,
# restoring after a raise three deep and answering each block's value. The
# two-key form also works (not needed).
require "cybertrain"

module LogScope
  KEY = :cybertrain_log_scope
  ID_KEY = :cybertrain_log_request_id
  TAGS_KEY = :cybertrain_log_tags

  # D5's Scope.
  class Scope
    attr_reader :scope_request_id, :scope_request_method, :scope_request_path, :scope_where,
                :scope_tags, :scope_id_tag, :scope_context
    attr_writer :scope_where

    def initialize(request_id, request_method, request_path, where, tags, id_tag, context)
      @scope_request_id = request_id
      @scope_request_method = request_method
      @scope_request_path = request_path
      @scope_where = where
      @scope_tags = tags
      @scope_id_tag = id_tag
      @scope_context = context
    end

    # A copy with `more` appended to the tags; id_tag kept.
    def with_tags(more)
      list = Array.new(0) { "" }
      @scope_tags.each { |t| list << t }
      more.each { |t| list << t.to_s }
      Scope.new(@scope_request_id, @scope_request_method, @scope_request_path, @scope_where, list,
                @scope_id_tag, @scope_context)
    end
  end

  def self.empty_context
    h = { "" => "" }
    h.delete("")
    h
  end

  NO_SCOPE = Scope.new("", "", "", "", Array.new(0) { "" }, -1, LogScope.empty_context)

  def self.current_scope
    value = Thread.current[KEY]
    value.nil? ? NO_SCOPE : value
  end

  # Stores nil for NO_SCOPE; answers the previous Scope.
  def self.swap_scope(scope)
    previous = current_scope
    Thread.current[KEY] = scope.equal?(NO_SCOPE) ? nil : scope
    previous
  end

  # Rule 103's save-yield-ensure in a module function.
  def self.tagged_during(tags)
    saved = current_scope
    Thread.current[KEY] = saved.with_tags(tags)
    value = yield
    value
  ensure
    Thread.current[KEY] = saved.equal?(NO_SCOPE) ? nil : saved
  end

  # The two-key form's reads.
  def self.two_key_id
    value = Thread.current[ID_KEY]
    value.nil? ? "" : value
  end

  def self.two_key_tags
    value = Thread.current[TAGS_KEY]
    value.nil? ? Array.new(0) { "" } : value
  end

  def self.describe(scope)
    "id=#{scope.scope_request_id} #{scope.scope_request_method} #{scope.scope_request_path} " \
      "where=#{scope.scope_where} tags=#{scope.scope_tags.join("|")} id_tag=#{scope.scope_id_tag} " \
      "context=#{scope.scope_context.map { |k, v| "#{k}:#{v}" }.join(",")}"
  end

  # One request's worth, in the one-slot form.
  def self.work(n, out, order)
    id = "req-#{n}"
    tags = Array.new(0) { "" }
    tags << id
    tags << "t#{n}"
    context = { "" => "" }
    context.delete("")
    context["job.id"] = n.to_s
    locale = n.even? ? :ja : :en
    I18n.locale = locale
    previous = LogScope.swap_scope(Scope.new(id, "GET", "/n/#{n}", "", tags, 0, context))
    order << "s#{n}"
    sleep 0
    # A timed sleep too: with SPINEL_WORKERS=1, `sleep 0` alone let each
    # thread run to its end before the next started (0 of 4 interleaved).
    sleep 0.002
    Cybertrain::DB.transaction do |conn|
      conn.execute("SELECT 1", [])
      sleep 0
      held = !Thread.current[Cybertrain::DB::Pool::TRANSACTION_KEY].nil?
      LogScope.current_scope.scope_where = "W#{n}"
      sleep 0
      scope = LogScope.current_scope
      order << "r#{n}"
      own = scope.scope_request_id == id && scope.scope_tags[1] == "t#{n}" && scope.scope_where == "W#{n}" &&
            scope.scope_context["job.id"] == n.to_s && I18n.locale == locale
      out << "one slot, thread #{n}: #{own ? "own" : "MIXED"} #{LogScope.describe(scope)} locale=#{I18n.locale} held=#{held}"
    end
    inner = LogScope.tagged_during(["in#{n}"]) do
      sleep 0
      LogScope.current_scope.scope_tags.join("|")
    end
    out << "tagged, thread #{n}: #{inner}; after: #{LogScope.current_scope.scope_tags.join("|")}"
    back = LogScope.swap_scope(previous)
    out << "swap back, thread #{n}: answered #{back.scope_request_id}, now #{LogScope.current_scope.equal?(NO_SCOPE) ? "NO_SCOPE" : "a Scope"}"
    nil
  end

  def self.start(n, out, order)
    Thread.new { LogScope.work(n, out, order) }
  end

  # One request's worth, in the two-key form.
  def self.work_two_keys(n, out)
    id = "req-#{n}"
    tags = Array.new(0) { "" }
    tags << id
    tags << "k#{n}"
    Thread.current[ID_KEY] = id
    Thread.current[TAGS_KEY] = tags
    sleep 0
    sleep 0.002
    Cybertrain::DB.transaction do |conn|
      conn.execute("SELECT 1", [])
      sleep 0
      own = LogScope.two_key_id == id && LogScope.two_key_tags[1] == "k#{n}"
      out << "two keys, thread #{n}: #{own ? "own" : "MIXED"} id=#{LogScope.two_key_id} tags=#{LogScope.two_key_tags.join("|")}"
    end
    Thread.current[ID_KEY] = nil
    Thread.current[TAGS_KEY] = nil
    nil
  end

  def self.start_two_keys(n, out)
    Thread.new { LogScope.work_two_keys(n, out) }
  end

  # How many threads read their scope after another thread stored its own
  # (the reads that a shared slot would have got wrong).
  def self.interleaved(order)
    seq = Array.new(0) { "" }
    seq << order.pop until order.empty?
    count = 0
    [1, 2, 3, 4].each do |n|
      from = seq.index("s#{n}")
      to = seq.index("r#{n}")
      next if from.nil? || to.nil?

      other = false
      i = from + 1
      while i < to
        other = true if seq[i].start_with?("s")
        i += 1
      end
      count += 1 if other
    end
    count
  end

  def self.drain(out)
    lines = Array.new(0) { "" }
    lines << out.pop until out.empty?
    lines.sort.each { |l| puts l }
  end
end

# What Logger#tagged would be: an instance method forwarding its block.
class TaggingLogger
  def tagged(*tags) = LogScope.tagged_during(tags) { yield }
end

# assert_raises's shape: a rescuing yielder answering the message.
def rescuing(label)
  yield
  "#{label}: nothing raised"
rescue StandardError => e
  "#{label}: rescued #{e.message}"
end

Cybertrain::DB.connect(":memory:", size: 4)
I18n.available_locales = [:en, :ja]
I18n.locale = :en

puts "-- one slot"
puts "main before: #{LogScope.current_scope.equal?(LogScope::NO_SCOPE) ? "NO_SCOPE" : "a Scope"}"
out = Queue.new
order = Queue.new
threads = Array.new(0) { Thread.new {} }
[1, 2, 3, 4].each { |n| threads << LogScope.start(n, out, order) }
threads.each { |t| t.join }
LogScope.drain(out)
puts "threads that read after another thread stored: #{LogScope.interleaved(order)} of 4"
puts "main after: #{LogScope.current_scope.equal?(LogScope::NO_SCOPE) ? "NO_SCOPE" : "a Scope"} raw #{Thread.current[LogScope::KEY].inspect}"

puts "-- two keys"
threads = Array.new(0) { Thread.new {} }
[1, 2, 3, 4].each { |n| threads << LogScope.start_two_keys(n, out) }
threads.each { |t| t.join }
LogScope.drain(out)
puts "main after: id #{LogScope.two_key_id.inspect} tags #{LogScope.two_key_tags.inspect}"

puts "-- tagged"
logger = TaggingLogger.new
base = LogScope::Scope.new("req-main", "POST", "/m", "", ["req-main"], 0, { "a" => "b" })
LogScope.swap_scope(base)
s = logger.tagged("one") do
  t = logger.tagged("two") do
    msg = rescuing("innermost") do
      logger.tagged("three") do
        puts "three deep: #{LogScope.current_scope.scope_tags.join("|")}"
        raise "boom"
      end
    end
    puts msg
    puts "after the raise: #{LogScope.current_scope.scope_tags.join("|")}"
    42
  end
  puts "an Integer block answered #{t.inspect}; now #{LogScope.current_scope.scope_tags.join("|")}"
  "a String"
end
n = logger.tagged("nil") { nil }
puts "a String block answered #{s.inspect}; a nil block answered #{n.inspect}"
puts "restored: #{LogScope.current_scope.scope_tags.join("|")} id_tag=#{LogScope.current_scope.scope_id_tag}"
msg = rescuing("outermost") { logger.tagged("x") { raise ArgumentError, "only statement" } }
puts "#{msg}; restored: #{LogScope.current_scope.scope_tags.join("|")}"
LogScope.swap_scope(LogScope::NO_SCOPE)
e = logger.tagged("alone") { LogScope.current_scope.scope_tags.join("|") }
puts "with no scope: #{e}; after: #{LogScope.current_scope.equal?(LogScope::NO_SCOPE) ? "NO_SCOPE" : "a Scope"}"
