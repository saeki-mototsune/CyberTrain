require "stringio"
require "cybertrain/logger"
require "cybertrain/test"

# Lines from several threads never interleave (spec section 12.1, plan
# D3): each line is built whole, then written once under Logger::LOCK.
# Meant to be compiled (`spin test test/logger_threads.rb`), where the
# threads are real; it also runs under CRuby. Byte checks, no regexp
# (pre-flight ruling G5).
#
# Compiled, Spinel runs threads on SPINEL_WORKERS worker threads, read
# when the first thread starts; with the default one worker a StringIO
# write is never pre-empted and the test could not fail. Four workers
# write at once. Without the lock the failure shows as interleaved or
# torn lines, or as a crash of the program (a double free inside
# StringIO), not only as a failed assertion.
ENV["SPINEL_WORKERS"] = "4"

LINES_PER_THREAD = 200
PAYLOAD = "x" * 3000

# A thread writing LINES_PER_THREAD lines "t<n> xxx...", started through a
# method (spikes/NOTES.md rule 21). Every 20th line it sleeps 2 ms, so
# green threads switch too (a `sleep 0` does not under SPINEL_WORKERS=1).
def spawn_writer(logger, n)
  Thread.new do
    i = 0
    while i < LINES_PER_THREAD
      logger.info("t#{n} #{PAYLOAD}")
      sleep 0.002 if i % 20 == 0
      i += 1
    end
  end
end

# Whether `line` is `<24-byte time> INFO t<0-3> <3000 x>`.
def whole_line?(line)
  s = line.to_s
  return false unless s.bytesize == 24 + 7 + 2 + 3000
  return false unless s.getbyte(23) == 90 && s.byteslice(24, 7) == " INFO t"

  t = s.getbyte(31)
  return false unless t >= 48 && t <= 51 && s.getbyte(32) == 32

  s.byteslice(33, 3000) == PAYLOAD
end

test "lines from several threads never interleave" do
  sink = StringIO.new
  logger = Cybertrain::Logger.new(sink)
  threads = [spawn_writer(logger, 0)]
  t = 1
  while t < 4
    threads << spawn_writer(logger, t)
    t += 1
  end
  threads.each(&:join)
  lines = sink.string.split("\n")
  assert_equal 800, lines.size
  bad = 0
  per_thread = [0, 0, 0, 0]
  lines.each do |l|
    if whole_line?(l)
      per_thread[l.getbyte(31) - 48] += 1
    else
      bad += 1
    end
  end
  assert_equal 0, bad
  assert_equal [200, 200, 200, 200], per_thread
end

Cybertrain::Test.run!
