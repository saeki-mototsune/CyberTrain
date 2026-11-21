# Reduced shapes only: the parts of NOTES 72 that match CRuby on
# 2026.11.04.7026, on Linux. Only class names and addresses are printed:
# the message of the Errno raised by a second `connect_nonblock` is worded
# differently by the two runtimes ("Connection refused @ connect - "
# compiled). Not here: `connect_timeout:`, which the compiled program still
# ignores (it hangs; NOTES status 72), `Socket#bind(sockaddr)`, the openssl
# package and macOS. The first line needs a resolver that answers NXDOMAIN
# for a name under .invalid; nothing listens on 127.0.0.1 port 1.
require "socket"

def try(label)
  puts "#{label}: #{yield}"
rescue SocketError
  puts "#{label}: SocketError"
rescue SystemCallError => e
  puts "#{label}: #{e.class.name}"
rescue StandardError => e
  puts "#{label}: #{e.class.name}"
end

try("unresolvable name") { Socket.getaddrinfo("no-such-host.invalid", 80).size }
try("entry[3]") { Socket.getaddrinfo("127.0.0.1", 80)[0][3] }
try("destructured") do
  found = ""
  Socket.getaddrinfo("127.0.0.1", 80).each { |_f, _p, _n, ip, _family, _socktype, _pr| found = ip }
  found
end
try("IPSocket.getaddress") { IPSocket.getaddress("127.0.0.1") }
try("Addrinfo.tcp") { Addrinfo.tcp("127.0.0.1", 80).ip_address }
try("SO_ERROR after a refused connect") do
  s = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
  s.connect_nonblock(Socket.sockaddr_in(1, "127.0.0.1"), exception: false)
  s.wait_writable(1)
  s.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int != 0
end
try("second connect_nonblock") do
  s = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
  s.connect_nonblock(Socket.sockaddr_in(1, "127.0.0.1"), exception: false)
  s.wait_writable(1)
  s.connect_nonblock(Socket.sockaddr_in(1, "127.0.0.1"))
  "connected"
end
try("TCPSocket.new, refused") { TCPSocket.new("127.0.0.1", 1); "connected" }
try("Errno constant") { Errno::ECONNREFUSED::Errno > 0 }
