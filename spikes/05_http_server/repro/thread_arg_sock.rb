# SPIKE (throwaway): does a socket passed via Thread.new(arg) keep its type inside a method?
require "socket"
def m(s)
  r = s.wait_readable(0.2)
  return "timeout" if r.nil?
  s.readpartial(10)
end
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
c = TCPSocket.new("127.0.0.1", port)
s = srv.accept
c.write("hi")
t = Thread.new(s) { |x| m(x) }
p t.value
t2 = Thread.new { m(s) }
p t2.value
