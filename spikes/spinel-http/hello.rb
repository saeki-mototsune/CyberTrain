# spinel-http phase 1, Task 1, step 2: does cybertrain's HTTP layer, as it is
# today (cybertrain/http/server and what it loads), build and serve under
# upstream Spinel? A record, not a test.
#
# Run (2026-11-21, Linux x86_64, gcc 13.3.0, 4 vCPU, from spikes/spinel-http/;
# binaries kept outside the package, rule 98). The fork is the pinned
# 2026.11.15.7033 (a2f3bfaa) on PATH; upstream is matz/spinel's release
# 2026.10.25 (2814693f), built with toolchain.rb's four steps into
# ~/.spinel-upstream/2026.10.25. spin builds only bin/*.rb, so `spin run`
# does not reach a top-level record; `spin flags` gives the package's flags
# (the fork's says --strict-require, upstream's --require-gate, the same
# flag under another name):
#   spinel $(spin flags) hello.rb -o $TMPDIR/hello && $TMPDIR/hello
#   U=~/.spinel-upstream/2026.10.25/bin
#   PATH=$U:$PATH spinel $(PATH=$U:$PATH spin flags) hello.rb -o $TMPDIR/hello-up && $TMPDIR/hello-up
#   ruby -I ../.. hello.rb    (CRuby 3.3.6, for reference)
# Output, the same under the fork, upstream (three runs) and CRuby; the
# compile prints only its `src -> bin` line on both, 16 s (fork) and 15 s
# (upstream):
#   HTTP/1.1 200 OK
#   hello
# Verdict: PASS under both. The whole HTTP layer as it is today
# (cybertrain/http/server and what it loads, Params and Logger included)
# compiles under upstream 2026.10.25 with no error or warning and serves.
# The moving tests (test/server.rb and the ten parser/request/response
# tests of spec section 6) under upstream `spin test`: see README.md.
require "socket"
require "cybertrain/http/server"

class Hello < Cybertrain::HttpHandler
  def call(request)
    response = Cybertrain::Response.new
    response.content_type = "text/plain"
    response.body = "hello"
    response
  end
end

server = Cybertrain::Server.new(Hello.new, port: 0)
server.start
sock = TCPSocket.new("127.0.0.1", server.port)
sock.write("GET / HTTP/1.1\r\nHost: spike\r\nConnection: close\r\n\r\n")
buf = +""
loop do
  break if sock.wait_readable(5).nil?

  begin
    buf << sock.readpartial(16384)
  rescue EOFError, Errno::ECONNRESET
    break
  end
end
sock.close
idx = buf.index("\r\n\r\n")
if idx.nil?
  puts "no response head: #{buf.inspect}"
else
  puts buf[0, buf.index("\r\n")]
  puts buf[idx + 4, buf.length - idx - 4]
end
server.stop
