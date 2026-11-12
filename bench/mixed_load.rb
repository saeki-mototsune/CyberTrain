# The mixed-load measurement of docs/sqlite-shared-load.md (design decision
# D74): business writes and reads, jobs, the cache, rate-limit counters and
# stream broadcasts, all in one process on one SQLite file, each kind alone
# (its baseline) and then all together. What the mixed run loses against
# the baselines is the interference of the services sharing the database.
#
#   bench/mixed [name=value ...]        compiles this file and runs it
#
# The settings (all Integers; `bench/mixed` passes them through):
#
#   duration=5      seconds per phase
#   workers=1       Config#workers (SPINEL_WORKERS as CyberTrain reads it)
#   pool=4          Config#pool_size, the connections every thread shares
#   job_threads=3   Config#job_threads
#   writers=2       threads running a business transaction (BEGIN IMMEDIATE,
#                   two UPDATEs and an INSERT)
#   readers=2       threads reading one business row by primary key
#   enqueuers=1     threads calling Job.enqueue; the job threads run the jobs
#                   (each handler INSERTs one business row)
#   cache=2         threads doing a Cache.write and then a Cache.read
#   rate=2          threads counting a request as `rate_limit` does (the
#                   Cache.increment of Controller#run_rate_limit, same key)
#   broadcasters=1  threads calling Stream.broadcast; the real poller hands
#                   the rows to one subscriber
#   think_ms=2      the pause after each write, read, cache or rate operation
#                   (0: as fast as the thread can)
#   enqueue_ms=20   the pause after each Job.enqueue
#   broadcast_ms=20 the pause after each Stream.broadcast
#   baselines=1     0 runs the mixed phase only
#
# The services are the framework's own, started as Application#serve starts
# them (Stream::Poller, Scheduler, Job), and they stay up through every
# phase: a baseline is one kind of load on a server whose other services
# are idle (an idle job thread reads once per job_poll_interval, the poller
# once per stream_poll_ms, the scheduler renews its lease once a second).
#
# Latency is measured around the public call, in microseconds on the
# monotonic clock, into a histogram whose buckets grow by a tenth, so a
# percentile is the upper bound of its bucket (at most 10% high). "busy"
# counts calls that raised with "database is locked" (a wait given up after
# Connection::BUSY_WAIT_LIMIT); a wait that ended in time is not counted
# anywhere in the framework and shows only as latency. This is a bench, not
# a test: the shape of the output is fixed, the numbers are not.
require "cybertrain"

DB = Cybertrain::DB
Job = Cybertrain::Job
Cache = Cybertrain::Cache
Stream = Cybertrain::Stream

BENCH_DIR = "bench/tmp/mixed"
BENCH_PATH = "#{BENCH_DIR}/mixed.sqlite3"

ACCOUNTS = 1000
RATE_CLIENTS = 200
CACHE_KEYS = 500
RATE_WINDOW = 60
STREAM_NAME = "bench"
JOB_KIND = "bench job"

# The most threads of one kind (a thread's statistics are its own object,
# so nothing is locked on the measured path).
MAX_SLOTS = 16

# The measured kinds, in the order the table prints them.
KIND_WRITE = 0
KIND_READ = 1
KIND_ENQUEUE = 2
KIND_JOB_DELAY = 3
KIND_CACHE_WRITE = 4
KIND_CACHE_READ = 5
KIND_RATE = 6
KIND_BROADCAST = 7
KIND_STREAM_DELAY = 8
KINDS = 9
KIND_NAMES = ["business write (transaction)", "business read", "job enqueue", "job delay (enqueue to start)",
              "cache write", "cache read", "rate limit count", "stream broadcast",
              "stream delay (broadcast to hand-off)"].freeze

# The load groups: a baseline phase runs one, the mixed phase all of them.
GROUP_WRITE = 0
GROUP_READ = 1
GROUP_JOBS = 2
GROUP_CACHE = 3
GROUP_RATE = 4
GROUP_STREAM = 5
GROUPS = 6
GROUP_OF_KIND = [GROUP_WRITE, GROUP_READ, GROUP_JOBS, GROUP_JOBS, GROUP_CACHE, GROUP_CACHE, GROUP_RATE,
                 GROUP_STREAM, GROUP_STREAM].freeze
PHASE_MIXED = GROUPS

# The histogram's upper bounds in microseconds: from 10 us in steps of a
# tenth, up to 60 s.
def build_bounds
  out = Array.new(0) { 0 }
  v = 10
  while v < 60_000_000
    out << v
    v += v / 10
  end
  out
end

BOUNDS = build_bounds

# One thread's (or one phase's merged) operations of one kind.
class LoadStats
  attr_reader :load_ops, :load_busy, :load_failed, :load_max_us

  def initialize
    @load_ops = 0
    @load_busy = 0
    @load_failed = 0
    @load_max_us = 0
    @buckets = Array.new(BOUNDS.size + 1) { 0 }
  end

  # The bucket of a duration: the first bound at or above it.
  def load_bucket_of(us)
    low = 0
    high = BOUNDS.size
    while low < high
      mid = (low + high) / 2
      if BOUNDS[mid] < us
        low = mid + 1
      else
        high = mid
      end
    end
    low
  end

  def load_record(us)
    @load_ops += 1
    @load_max_us = us if us > @load_max_us
    i = load_bucket_of(us)
    @buckets[i] = @buckets[i] + 1
    nil
  end

  # code: 0 done, 1 "database is locked", 2 any other error.
  def load_note(code, us)
    if code == 0
      load_record(us)
    else
      if code == 1
        @load_busy += 1
      else
        @load_failed += 1
      end
    end
    nil
  end

  def load_bucket_count(i)
    @buckets[i]
  end

  def load_add(other)
    @load_ops += other.load_ops
    @load_busy += other.load_busy
    @load_failed += other.load_failed
    @load_max_us = other.load_max_us if other.load_max_us > @load_max_us
    i = 0
    while i < @buckets.size
      @buckets[i] = @buckets[i] + other.load_bucket_count(i)
      i += 1
    end
    nil
  end

  def load_clear
    @load_ops = 0
    @load_busy = 0
    @load_failed = 0
    @load_max_us = 0
    i = 0
    while i < @buckets.size
      @buckets[i] = 0
      i += 1
    end
    nil
  end

  # The duration `percent` of the operations stayed at or under: the upper
  # bound of the bucket that holds it (the maximum for the last bucket).
  def load_percentile(percent)
    return 0 if @load_ops == 0

    wanted = (@load_ops * percent + 99) / 100
    seen = 0
    i = 0
    while i < @buckets.size
      seen += @buckets[i]
      if seen >= wanted
        return @load_max_us if i >= BOUNDS.size

        return BOUNDS[i] < @load_max_us ? BOUNDS[i] : @load_max_us
      end
      i += 1
    end
    @load_max_us
  end
end

# [0]: how many errors were printed (the first few are enough to see what
# went wrong; every one is counted in the table).
ERRORS_SHOWN = [0]
ERRORS_TO_SHOW = 5

# Every thread's statistics: STATS[kind * MAX_SLOTS + slot]. A constant, so
# the objects are GC roots (NOTES rule 64).
STATS = Array.new(KINDS * MAX_SLOTS) { LoadStats.new }
# The phases' merged results: RESULTS[phase * KINDS + kind].
RESULTS = Array.new((GROUPS + 1) * KINDS) { LoadStats.new }
# The seconds each phase really ran, in milliseconds.
PHASE_MS = Array.new(GROUPS + 1) { 0 }

# The job threads share one LoadStats (a handler does not know its thread).
JOB_LOCK = Mutex.new
# [0]: whether the subscriber thread should go on.
SUBSCRIBER_ON = [true]

def monotonic
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def now_us
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000_000.0).to_i
end

# `name=value` among the arguments, or the default.
def setting(name, default)
  prefix = "#{name}="
  value = default
  i = 0
  while i < ARGV.size
    arg = ARGV[i].to_s
    if arg.start_with?(prefix)
      value = Cybertrain::Params.parse_int(arg.byteslice(prefix.bytesize, arg.bytesize - prefix.bytesize), default)
    end
    i += 1
  end
  value
end

def slots(name, default)
  n = setting(name, default)
  n = 0 if n < 0
  n > MAX_SLOTS ? MAX_SLOTS : n
end

# The code LoadStats#load_note takes for an operation that raised.
def error_code(message)
  text = message.to_s
  if ERRORS_SHOWN[0] < ERRORS_TO_SHOW
    ERRORS_SHOWN[0] = ERRORS_SHOWN[0] + 1
    STDERR.puts "error: #{text}"
  end
  text.include?("database is locked") ? 1 : 2
end

# --- the operations: each a plain method, with its rescue in a second plain
# --- method around it (NOTES rules 32/45)

def transfer(slot, seq)
  from = (slot * 7919 + seq * 31) % ACCOUNTS + 1
  to = (slot * 104_729 + seq * 17 + 1) % ACCOUNTS + 1
  now = Time.now.to_i
  DB.transaction(immediate: true) do |c|
    c.execute("UPDATE accounts SET balance = balance - 1, updated_at = ? WHERE id = ?", [now, from])
    c.execute("UPDATE accounts SET balance = balance + 1, updated_at = ? WHERE id = ?", [now, to])
    c.execute("INSERT INTO entries (account_id, amount, created_at) VALUES (?, ?, ?)", [from, 1, now])
  end
  nil
end

def safe_transfer(slot, seq)
  transfer(slot, seq)
  0
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  error_code(e.message)
end

def read_account(slot, seq)
  id = (slot * 7919 + seq * 31) % ACCOUNTS + 1
  rows = DB.with { |c| c.execute("SELECT id, balance, updated_at FROM accounts WHERE id = ?", [id]) }
  rows.size
end

def safe_read(slot, seq)
  read_account(slot, seq)
  0
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  error_code(e.message)
end

def safe_enqueue
  Job.enqueue(JOB_KIND, now_us.to_s)
  0
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  error_code(e.message)
end

def safe_cache_write(slot, seq)
  Cache.write("bench/#{slot}/#{seq % CACHE_KEYS}", "value #{seq}", expires_in: 300)
  0
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  error_code(e.message)
end

def safe_cache_read(slot, seq)
  Cache.read("bench/#{slot}/#{seq % CACHE_KEYS}")
  0
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  error_code(e.message)
end

# What Controller#run_rate_limit does for `store: :cache`: one
# Cache.increment on the client's row of the current window.
def safe_rate(slot, seq)
  now = Cache.now
  client = (slot * 7919 + seq) % RATE_CLIENTS
  Cache.increment("rate-limit:bench::10.0.#{client / 250}.#{client % 250}:#{now / RATE_WINDOW}", expires_in: RATE_WINDOW)
  0
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  error_code(e.message)
end

def safe_broadcast
  Stream.broadcast(STREAM_NAME, now_us.to_s)
  0
rescue JSON::NestingError, JSON::ParserError, StandardError => e
  error_code(e.message)
end

# The job: how long the row waited, then one business INSERT.
def run_bench_job(payload)
  waited = now_us - Cybertrain::Params.parse_int(payload, 0)
  JOB_LOCK.synchronize { STATS[KIND_JOB_DELAY * MAX_SLOTS].load_record(waited) }
  DB.with { |c| c.execute("INSERT INTO entries (account_id, amount, created_at) VALUES (?, ?, ?)", [1, 0, Time.now.to_i]) }
  nil
end

Job.handle(JOB_KIND) { |payload| run_bench_job(payload) }

# --- the load threads

def pause(seconds)
  sleep seconds if seconds > 0.0
  nil
end

def run_writer(slot, ends_at, think)
  stats = STATS[KIND_WRITE * MAX_SLOTS + slot]
  seq = 0
  while monotonic < ends_at
    started = now_us
    result = safe_transfer(slot, seq)
    stats.load_note(result, now_us - started)
    seq += 1
    pause(think)
  end
  nil
end

def run_reader(slot, ends_at, think)
  stats = STATS[KIND_READ * MAX_SLOTS + slot]
  seq = 0
  while monotonic < ends_at
    started = now_us
    result = safe_read(slot, seq)
    stats.load_note(result, now_us - started)
    seq += 1
    pause(think)
  end
  nil
end

def run_enqueuer(slot, ends_at, think)
  stats = STATS[KIND_ENQUEUE * MAX_SLOTS + slot]
  while monotonic < ends_at
    started = now_us
    result = safe_enqueue
    stats.load_note(result, now_us - started)
    pause(think)
  end
  nil
end

def run_cache(slot, ends_at, think)
  writes = STATS[KIND_CACHE_WRITE * MAX_SLOTS + slot]
  reads = STATS[KIND_CACHE_READ * MAX_SLOTS + slot]
  seq = 0
  while monotonic < ends_at
    started = now_us
    result = safe_cache_write(slot, seq)
    writes.load_note(result, now_us - started)
    started = now_us
    result = safe_cache_read(slot, seq)
    reads.load_note(result, now_us - started)
    seq += 1
    pause(think)
  end
  nil
end

def run_rate(slot, ends_at, think)
  stats = STATS[KIND_RATE * MAX_SLOTS + slot]
  seq = 0
  while monotonic < ends_at
    started = now_us
    result = safe_rate(slot, seq)
    stats.load_note(result, now_us - started)
    seq += 1
    pause(think)
  end
  nil
end

def run_broadcaster(slot, ends_at, think)
  stats = STATS[KIND_BROADCAST * MAX_SLOTS + slot]
  while monotonic < ends_at
    started = now_us
    result = safe_broadcast
    stats.load_note(result, now_us - started)
    pause(think)
  end
  nil
end

# The one subscriber: what an SSE or WebSocket connection thread does with
# Subscriber#stream_pop, less the socket write.
def run_subscriber
  sub = Stream.hub.subscribe([STREAM_NAME])
  stats = STATS[KIND_STREAM_DELAY * MAX_SLOTS]
  while SUBSCRIBER_ON[0]
    msg = sub.stream_pop(0.1)
    unless msg.nil?
      sent = Cybertrain::Params.parse_int(msg.message_payload, 0)
      stats.load_record(now_us - sent)
    end
  end
  Stream.hub.unsubscribe(sub)
  nil
end

# Through methods, so each closure captures its parameters (NOTES rule 21).
def spawn_writer(slot, ends_at, think)
  Thread.new { run_writer(slot, ends_at, think) }
end

def spawn_reader(slot, ends_at, think)
  Thread.new { run_reader(slot, ends_at, think) }
end

def spawn_enqueuer(slot, ends_at, think)
  Thread.new { run_enqueuer(slot, ends_at, think) }
end

def spawn_cache(slot, ends_at, think)
  Thread.new { run_cache(slot, ends_at, think) }
end

def spawn_rate(slot, ends_at, think)
  Thread.new { run_rate(slot, ends_at, think) }
end

def spawn_broadcaster(slot, ends_at, think)
  Thread.new { run_broadcaster(slot, ends_at, think) }
end

def spawn_subscriber
  Thread.new { run_subscriber }
end

# --- the phases

def count_of(sql)
  rows = DB.with { |c| c.execute(sql) }
  Cybertrain::Cast.int(rows[0]["n"])
end

def pragma_text(name)
  rows = DB.with { |c| c.execute("PRAGMA #{name}") }
  return "" if rows.empty?

  Cybertrain::Cast.str(rows[0][name])
end

def pending_jobs
  count_of("SELECT COUNT(*) AS n FROM cybertrain_jobs WHERE state IN ('queued', 'running')")
end

# Waits for the jobs enqueued and the messages broadcast in the phase to be
# handled, so their delays belong to it; gives up after `seconds`. True
# when everything was handled, false when work of this phase is still
# pending: the next phase would then count it as its own.
def drain(seconds)
  ends_at = monotonic + seconds
  idle = false
  while monotonic < ends_at
    idle = pending_jobs == 0 && Stream::Poller.last_id >= Stream.max_id
    break if idle

    sleep 0.05
  end
  # The subscriber's pop of the last hand-off.
  sleep 0.3
  idle
end

def phase_runs?(phase, group)
  phase == PHASE_MIXED || phase == group
end

def run_phase(phase, seconds)
  i = 0
  while i < STATS.size
    STATS[i].load_clear
    i += 1
  end
  think = setting("think_ms", 2) / 1000.0
  enqueue_pause = setting("enqueue_ms", 20) / 1000.0
  broadcast_pause = setting("broadcast_ms", 20) / 1000.0
  started = monotonic
  ends_at = started + seconds
  threads = []
  if phase_runs?(phase, GROUP_WRITE)
    slots("writers", 2).times { |s| threads << spawn_writer(s, ends_at, think) }
  end
  if phase_runs?(phase, GROUP_READ)
    slots("readers", 2).times { |s| threads << spawn_reader(s, ends_at, think) }
  end
  if phase_runs?(phase, GROUP_JOBS)
    slots("enqueuers", 1).times { |s| threads << spawn_enqueuer(s, ends_at, enqueue_pause) }
  end
  if phase_runs?(phase, GROUP_CACHE)
    slots("cache", 2).times { |s| threads << spawn_cache(s, ends_at, think) }
  end
  if phase_runs?(phase, GROUP_RATE)
    slots("rate", 2).times { |s| threads << spawn_rate(s, ends_at, think) }
  end
  if phase_runs?(phase, GROUP_STREAM)
    slots("broadcasters", 1).times { |s| threads << spawn_broadcaster(s, ends_at, broadcast_pause) }
  end
  threads.each(&:join)
  PHASE_MS[phase] = ((monotonic - started) * 1000.0).to_i
  unless drain(30.0)
    # A phase that leaves jobs or messages behind would hand them to the
    # next one, whose "alone" numbers would then include them: no table is
    # better than a wrong comparison.
    puts "error: phase #{phase} did not drain in 30 s (#{pending_jobs} jobs pending); lower the load or raise job_threads"
    STDOUT.flush
    exit(1)
  end
  kind = 0
  while kind < KINDS
    merged = RESULTS[phase * KINDS + kind]
    slot = 0
    while slot < MAX_SLOTS
      merged.load_add(STATS[kind * MAX_SLOTS + slot])
      slot += 1
    end
    kind += 1
  end
  nil
end

# --- the report

# Microseconds as milliseconds with two decimals.
def ms_text(us)
  hundredths = (us + 5) / 10
  whole = hundredths / 100
  part = hundredths % 100
  "#{whole}.#{part < 10 ? "0" : ""}#{part}"
end

def rate_text(ops, phase_ms)
  return "0" if phase_ms <= 0

  tenths = ops * 10_000 / phase_ms
  "#{tenths / 10}.#{tenths % 10}"
end

def print_row(kind, label, phase)
  stats = RESULTS[phase * KINDS + kind]
  line = +"| "
  line << KIND_NAMES[kind].ljust(36)
  line << " | "
  line << label.ljust(5)
  line << " | "
  line << stats.load_ops.to_s.rjust(7)
  line << " | "
  line << rate_text(stats.load_ops, PHASE_MS[phase]).rjust(8)
  line << " | "
  line << ms_text(stats.load_percentile(50)).rjust(8)
  line << " | "
  line << ms_text(stats.load_percentile(95)).rjust(8)
  line << " | "
  line << ms_text(stats.load_percentile(99)).rjust(8)
  line << " | "
  line << ms_text(stats.load_max_us).rjust(8)
  line << " | "
  line << stats.load_busy.to_s.rjust(4)
  line << " | "
  line << stats.load_failed.to_s.rjust(6)
  line << " |"
  puts line
  nil
end

def print_table(baselines)
  puts "| kind                                 | phase |     ops |    ops/s |   p50 ms |   p95 ms |   p99 ms |   max ms | busy | errors |"
  puts "|--------------------------------------|-------|--------:|---------:|---------:|---------:|---------:|---------:|-----:|-------:|"
  kind = 0
  while kind < KINDS
    print_row(kind, "alone", GROUP_OF_KIND[kind]) if baselines
    print_row(kind, "mixed", PHASE_MIXED)
    kind += 1
  end
  nil
end

def file_kb(path)
  File.exist?(path) ? File.size(path) / 1024 : 0
end

def print_sizes
  puts "rows: accounts #{count_of("SELECT COUNT(*) AS n FROM accounts")}, " \
       "entries #{count_of("SELECT COUNT(*) AS n FROM entries")}, " \
       "cybertrain_jobs #{count_of("SELECT COUNT(*) AS n FROM cybertrain_jobs")}, " \
       "cybertrain_cache #{count_of("SELECT COUNT(*) AS n FROM cybertrain_cache")}, " \
       "cybertrain_messages #{count_of("SELECT COUNT(*) AS n FROM cybertrain_messages")}"
  puts "files: database #{file_kb(BENCH_PATH)} KiB, WAL #{file_kb("#{BENCH_PATH}-wal")} KiB"
  nil
end

# --- the transaction guarantees D74's table states, checked on this binary

def coupled_writes_then_raise
  DB.transaction(immediate: true) do |c|
    c.execute("INSERT INTO entries (account_id, amount, created_at) VALUES (1, 99, 0)")
    Job.enqueue(JOB_KIND, "0", run_at: Time.at(Time.now.to_i + 86_400))
    Stream.broadcast(STREAM_NAME, "rolled back")
    Cache.write("bench/coupled", "1")
    Cache.increment("bench/coupled-count")
    raise "roll it back"
  end
  nil
end

def coupled_rollback_raised?
  coupled_writes_then_raise
  false
rescue JSON::NestingError, JSON::ParserError, StandardError
  true
end

def coupled_writes_commit
  DB.transaction(immediate: true) do |c|
    c.execute("INSERT INTO entries (account_id, amount, created_at) VALUES (1, 99, 0)")
    Job.enqueue(JOB_KIND, "0", run_at: Time.at(Time.now.to_i + 86_400))
    Stream.broadcast(STREAM_NAME, "committed")
    Cache.write("bench/coupled", "1")
    Cache.increment("bench/coupled-count")
  end
  nil
end

def coupled_rows
  count_of("SELECT COUNT(*) AS n FROM entries WHERE amount = 99") +
    count_of("SELECT COUNT(*) AS n FROM cybertrain_jobs") +
    count_of("SELECT COUNT(*) AS n FROM cybertrain_messages") +
    count_of("SELECT COUNT(*) AS n FROM cybertrain_cache WHERE key LIKE 'bench/coupled%'")
end

# One transaction writing a business row, a job, a message and two cache
# rows: none of the five rows after a rollback, all five after a commit.
def check_coupling
  raised = coupled_rollback_raised?
  after_rollback = coupled_rows
  coupled_writes_commit
  after_commit = coupled_rows
  ok = raised && after_rollback == 0 && after_commit == 5
  puts "transaction coupling: #{ok ? "ok" : "BROKEN"} " \
       "(rows after a rollback: #{after_rollback}, after a commit: #{after_commit} of 5)"
  DB.with do |c|
    c.execute("DELETE FROM entries WHERE amount = 99")
    c.execute("DELETE FROM cybertrain_jobs")
    c.execute("DELETE FROM cybertrain_messages")
    c.execute("DELETE FROM cybertrain_cache")
  end
  ok
end

# --- setup

def fresh_database(pool)
  Dir.mkdir("bench/tmp") unless File.directory?("bench/tmp")
  Dir.mkdir(BENCH_DIR) unless File.directory?(BENCH_DIR)
  ["", "-wal", "-shm"].each { |suffix| File.delete("#{BENCH_PATH}#{suffix}") if File.exist?("#{BENCH_PATH}#{suffix}") }
  DB.connect(BENCH_PATH, size: pool)
  DB.with do |c|
    c.exec_script("CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER NOT NULL, updated_at INTEGER NOT NULL); " \
                  "CREATE TABLE entries (id INTEGER PRIMARY KEY AUTOINCREMENT, account_id INTEGER NOT NULL, " \
                  "amount INTEGER NOT NULL, created_at INTEGER NOT NULL);")
  end
  DB.transaction(immediate: true) do |c|
    i = 0
    while i < ACCOUNTS
      c.execute("INSERT INTO accounts (balance, updated_at) VALUES (?, ?)", [1000, 0])
      i += 1
    end
  end
  Job.install!
  Cache.install!
  Stream.install!
  nil
end

def run_bench
  seconds = setting("duration", 5)
  seconds = 1 if seconds < 1
  workers = setting("workers", 1)
  workers = 1 if workers < 1
  pool = setting("pool", 4)
  pool = 1 if pool < 1
  baselines = setting("baselines", 1) != 0
  # Before the first Thread.new (NOTES rule 22), as Application#serve sets it.
  ENV["SPINEL_WORKERS"] = Cybertrain::Application.spinel_workers(workers).to_s

  config = Cybertrain::Config.new
  config.pool_size = pool
  config.job_threads = setting("job_threads", 3)
  Cybertrain.config = config
  # Errors only: a job's "done" line per job is not what is measured.
  Cybertrain.logger.level = :error

  fresh_database(pool)
  puts "settings: duration #{seconds} s, workers #{workers}, pool #{pool}, job_threads #{config.job_threads}, " \
       "writers #{slots("writers", 2)}, readers #{slots("readers", 2)}, enqueuers #{slots("enqueuers", 1)}, " \
       "cache #{slots("cache", 2)}, rate #{slots("rate", 2)}, broadcasters #{slots("broadcasters", 1)}, " \
       "think #{setting("think_ms", 2)} ms, enqueue every #{setting("enqueue_ms", 20)} ms, " \
       "broadcast every #{setting("broadcast_ms", 20)} ms"
  puts "sqlite: journal_mode #{pragma_text("journal_mode")}, synchronous #{pragma_text("synchronous")}, " \
       "wal_autocheckpoint #{pragma_text("wal_autocheckpoint")}; " \
       "job_poll_interval #{config.job_poll_interval} s, stream_poll_ms #{config.stream_poll_ms}"
  coupled = check_coupling

  # As Application#serve: the poller, the scheduler, the job threads.
  Stream::Poller.start!(config)
  Cybertrain::Scheduler.start!(config)
  Job.start!(config)
  subscriber = spawn_subscriber
  sleep 0.3

  if baselines
    phase = 0
    while phase < GROUPS
      run_phase(phase, seconds)
      phase += 1
    end
  end
  run_phase(PHASE_MIXED, seconds)

  SUBSCRIBER_ON[0] = false
  subscriber.join
  Job.stop!
  Cybertrain::Scheduler.stop!
  Stream::Poller.stop!
  puts ""
  print_table(baselines)
  puts ""
  print_sizes
  DB.disconnect
  coupled ? 0 : 1
end

exit run_bench
