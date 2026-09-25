# SPIKE (throwaway, CRuby client): open N connections at once, time first response on each (accept-burst latency)
require "socket"
port, n = ARGV[0].to_i, (ARGV[1] || 100).to_i
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
socks = (1..n).map { TCPSocket.new("127.0.0.1", port) }
socks.each { |s| s.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n") }
lat = socks.map { |s| s.readpartial(4096); ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1) }
# second request on the same (now accepted) connections
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
socks.each { |s| s.write("GET / HTTP/1.1\r\nHost: x\r\n\r\n") }
lat2 = socks.map { |s| s.readpartial(4096); ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round(1) }
s = lat.sort; s2 = lat2.sort
puts "first-req  n=#{n} p50=#{s[n/2]}ms p99=#{s[(n*0.99).to_i-1]}ms max=#{s[-1]}ms  >500ms=#{s.count { |x| x > 500 }}"
puts "second-req n=#{n} p50=#{s2[n/2]}ms max=#{s2[-1]}ms"
socks.each(&:close)
