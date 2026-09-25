# SPIKE (throwaway): IO#wait_readable(t).nil? inside a while loop (no threads)
require "socket"
srv = TCPServer.new("127.0.0.1", 0)
c = TCPSocket.new("127.0.0.1", srv.addr[1])
s = srv.accept
def a(s)            # variant A: result of wait_readable used directly
  n = 0
  while true
    break if s.wait_readable(0.1).nil?
    s.readpartial(10); n += 1
  end
  n
end
def b(s)            # variant B: truthiness, no .nil?
  n = 0
  while true
    break unless s.wait_readable(0.1)
    s.readpartial(10); n += 1
  end
  n
end
def d(s)            # variant D: IO.select single io
  n = 0
  while true
    break if IO.select([s], nil, nil, 0.1).nil?
    s.readpartial(10); n += 1
  end
  n
end
c.write("hi"); p b(s)
c.write("hi"); p d(s)
c.write("hi"); p a(s)
