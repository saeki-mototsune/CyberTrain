# SPIKE (throwaway): does a socket param captured by a `loop do` block lose its type?
require "socket"
def m(s)
  n = 0
  loop do
    return "timeout" if s.wait_readable(0.2).nil?
    n += s.readpartial(10).bytesize
  end
  n
rescue EOFError
  "eof #{n}"
ensure
  s.close unless s.closed?
end
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
c = TCPSocket.new("127.0.0.1", port)
s = srv.accept
c.write("hi")
t = Thread.new(s) { |x| m(x) }
p t.value
