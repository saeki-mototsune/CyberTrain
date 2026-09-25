# SPIKE (throwaway): does a socket method param used inside `loop do` keep its type when the method is called from a thread?
require "socket"
def m(s)
  n = 0
  loop do
    break if s.wait_readable(0.2).nil?
    n += 1
    s.readpartial(10)
  end
  n
end
def w(s)
  n = 0
  while true
    break if s.wait_readable(0.2).nil?
    n += 1
    s.readpartial(10)
  end
  n
end
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
c = TCPSocket.new("127.0.0.1", port)
s = srv.accept
c.write("hi")
p Thread.new(s) { |x| w(x) }.value
c.write("hi")
p Thread.new(s) { |x| m(x) }.value
