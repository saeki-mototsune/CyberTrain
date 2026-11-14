# Phase 5b, found while testing the logger's lock (spikes/NOTES.md rule
# 116, docs/spinel-feedback.md AQ): four threads writing into one StringIO
# with no lock, at SPINEL_WORKERS=4, abort the program.
#
# Run (from the repository root; outputs outside the package, rule 98):
#   spinel spikes/phase5/stringio_threads.rb -o $TMPDIR/stringio_threads && $TMPDIR/stringio_threads; echo "exit $?"
#   ruby spikes/phase5/stringio_threads.rb
# Output (2026-11-14, Spinel 2026.11.04.7026 a2d06115, gcc 13.3.0, Linux
# x86_64 on a shared 4-vCPU machine, no flags; CRuby 3.3.6):
#   compiled, five runs: four aborted with "double free or corruption
#             (!prev)" (exit 134), one died with SIGSEGV (exit 139);
#             nothing printed. Earlier runs of the same binary also
#             showed "double free or corruption (out)" and "malloc():
#             corrupted top size". No run finished.
#   CRuby:    2432000
# The same program with "1" in place of "4" (one worker) printed 2432000
# and exited 0 in three runs out of three.
require "stringio"
ENV["SPINEL_WORKERS"] = "4"
SINK = StringIO.new

def spawn_writer(io, n)
  Thread.new do
    i = 0
    while i < 2000
      io.write("t#{n} #{"x" * 300}\n")
      i += 1
    end
  end
end

threads = [spawn_writer(SINK, 0), spawn_writer(SINK, 1), spawn_writer(SINK, 2), spawn_writer(SINK, 3)]
threads.each { |t| t.join }
puts SINK.string.bytesize
