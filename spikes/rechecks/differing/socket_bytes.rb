# Evidence for docs/spinel-feedback.md AW (NOTES rule 27). Kept until AW is closed.
# What a socket's bytes are tagged as, over loopback TCP: the String that
# `IO#gets` answers, and an append of what `readpartial` answers to a UTF-8
# String that holds non-ASCII. The reads that match CRuby (`readpartial`,
# `read(n)`, `read_nonblock`) are in ../socket_shapes.rb.
#
#   ruby spikes/rechecks/differing/socket_bytes.rb
#   spinel spikes/rechecks/differing/socket_bytes.rb -O 0 -o "$TMPDIR/sb" && "$TMPDIR/sb"
#
# Linux x86_64, Spinel 2026.11.15.7033 (a2f3bfaa, GCC 13.3.0), CRuby 3.3.6,
# 2026-11-21.
#   CRuby:    gets: ASCII-8BIT 13 13
#             append: Encoding::CompatibilityError
#   compiled: gets: ASCII-8BIT 13 13
#             append: appended 15
# Built with Spinel 2026.11.04.7026 (a2d06115) the same day, the program
# printed `gets: UTF-8 8 13` and `append: appended 15`. The `gets` line
# matches CRuby on 2026.11.15.7033; the file stays here until the `append`
# line does too.
require "socket"

def peer_read(text)
  srv = TCPServer.new("127.0.0.1", 0)
  t = Thread.new do
    c = srv.accept
    c.write(text)
    c.close
  end
  cl = TCPSocket.new("127.0.0.1", srv.addr[1])
  got = yield cl
  t.join
  cl.close
  srv.close
  got
end

line = peer_read("café 日本\n") { |cl| cl.gets }
puts "gets: #{line.encoding} #{line.size} #{line.bytesize}"

buf = peer_read("café 日本\n") { |cl| cl.readpartial(64) }
u = +"é"
begin
  u << buf
  puts "append: appended #{u.bytesize}"
rescue StandardError => e
  puts "append: #{e.class.name}"
end
