# SPIKE (throwaway): a method called ONLY as Thread.new(sock) { |x| m(x) } gets an untyped param -> sock.wait_readable(t).nil? fails at runtime (minimal repro)
require "socket"
srv = TCPServer.new("127.0.0.1", 0)
c = TCPSocket.new("127.0.0.1", srv.addr[1])
s = srv.accept
def only_via_thread_arg(x)
  r = x.wait_readable(0.1)
  r.nil? ? "timeout" : "ready"
end
def only_via_closure(x)
  r = x.wait_readable(0.1)
  r.nil? ? "timeout" : "ready"
end
p Thread.new { only_via_closure(s) }.value
p Thread.new(s) { |x| only_via_thread_arg(x) }.value
