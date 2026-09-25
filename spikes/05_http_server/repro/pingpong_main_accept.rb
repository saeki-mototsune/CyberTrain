# SPIKE (throwaway): variant of pingpong_stall.rb with accept on the main thread (no accept-loop thread)
require "socket"
def now_us; (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000_000).to_i; end
def echo(s)
  loop { s.write(s.readpartial(64)) }
rescue EOFError, Errno::ECONNRESET
  s.close
end
def spawn_echo(s); Thread.new { echo(s) }; end
def pinger(port, n)
  c = TCPSocket.new("127.0.0.1", port)
  slow = 0; mx = 0; i = 0
  while i < n
    t = now_us
    c.write("x"); c.readpartial(64)
    d = now_us - t
    slow += 1 if d > 40_000
    mx = d if d > mx
    i += 1
  end
  c.close
  [slow, mx]
end
def spawn_pinger(port, n); Thread.new { pinger(port, n) }; end
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
pairs = (ARGV[0] || "10").to_i

t0 = now_us
ths = []
per = (ARGV[1] || "3000").to_i
pairs.times { ths << spawn_pinger(port, per) }
pairs.times { spawn_echo(srv.accept) }
slow = 0; mx = 0
ths.each { |t| r = t.value; slow += r[0]; mx = r[1] if r[1] > mx }
puts "pairs=#{pairs} roundtrips=#{pairs * per} wall=#{(now_us - t0) / 1000}ms slow(>40ms)=#{slow} max=#{mx}us"
