# Evidence for docs/spinel-feedback.md BA. Kept until BA is closed.
#
# Thread.new passes the program's file name to sp_Thread_spawn_fiber_at as
# a bare C literal, and that function roots it with SP_GC_ROOT_STR. A
# collection inside the thread record's allocation then reads the byte in
# front of the literal (sp_mark_string's tag test, s[-1]).
#
# Prints "ok" under CRuby and compiled. The read shows only in a matched
# AddressSanitizer build (docs/performance-next.md, "Memory errors") run
# with SPINEL_GC_THRESHOLD_KB=1. TCPServer.new puts a marker-prefixed
# literal ("\xfftcpserver") in front of the file name in the same
# function, so the byte read is in that literal's redzone; the eight
# captured Arrays make the capture struct large enough that the collection
# threshold is crossed by its allocation, so the next one, the thread
# record's, collects. The outer Thread.new runs spawn on a worker.
require "socket"

def spawn(i)
  server = TCPServer.new("127.0.0.1", 0)
  a = [i]; b = [i]; c = [i]; d = [i]; e = [i]; f = [i]; g = [i]; h = [i]
  Thread.new { server.close; a + b + c + d + e + f + g + h }.join
end

Thread.new { 3000.times { |i| spawn(i) } }.join
puts "ok"
