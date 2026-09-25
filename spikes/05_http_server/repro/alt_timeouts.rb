# SPIKE (throwaway): do SO_RCVTIMEO / IO.select / gets work as idle-timeout or parking primitives on a socket?
require "socket"
srv = TCPServer.new("127.0.0.1", 0)
c = TCPSocket.new("127.0.0.1", srv.addr[1])
s = srv.accept
begin
  s.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [0, 200_000].pack("l_l_"))
  puts "SO_RCVTIMEO packed timeval: accepted"
rescue => e
  puts "SO_RCVTIMEO packed: #{e.class} #{e.message}"
end
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
p IO.select([s], nil, nil, 0.2).nil?
puts "IO.select timeout took #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round}ms"
# does a thread blocked in gets let another thread run with 1 worker?
def reader(s); s.gets; end
def spawn_reader(s); Thread.new { reader(s) }; end
th = spawn_reader(s)
sleep 0.1
puts "main ran while reader blocked in gets"
c.write("line\r\n")
p th.value
