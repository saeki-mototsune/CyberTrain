# SPIKE (throwaway): does IO#wait_readable(t).nil? compile/run on a socket?
require "socket"
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
c = TCPSocket.new("127.0.0.1", port)
s = srv.accept
r = s.wait_readable(0.1)
p r.nil?
p(r ? "ready" : "timeout")
c.write("x")
r2 = s.wait_readable(0.1)
p(r2 ? "ready" : "timeout")
p s.wait_readable(0.1).nil?
def m(s)
  return :to if s.wait_readable(0.1).nil?
  :ok
end
p m(s)
