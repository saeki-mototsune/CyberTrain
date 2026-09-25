# SPIKE (throwaway): can a TCPServer + green-thread-per-connection keep-alive HTTP/1.1 server be written in Spinel Ruby, and how does it perform?
require "socket"

$idle = (ARGV[1] || "5").to_f
BODY = "<!doctype html><html><head><title>cybertrain</title></head><body><h1>Hello from cybertrain</h1><p>spike 05</p></body></html>\n"

$served = 0
$conns = 0
$lock = Mutex.new

def respond(sock, status, body, keep)
  hdr = "HTTP/1.1 #{status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: #{body.bytesize}\r\n"
  hdr << (keep ? "Connection: keep-alive\r\n" : "Connection: close\r\n")
  hdr << "\r\n"
  sock.write(hdr + body)
end

# returns true to keep the connection alive
def handle_request(sock, head, body)
  lines = head.split("\r\n")
  parts = lines[0].split(" ")
  meth = parts[0]
  path = parts[1]
  version = parts[2]
  keep = version == "HTTP/1.1"
  i = 1
  while i < lines.size
    line = lines[i]
    c = line.index(":")
    if c
      name = line[0, c].downcase
      val = line[c + 1, line.size - c - 1].strip
      if name == "connection"
        v = val.downcase
        keep = false if v == "close"
        keep = true if v == "keep-alive"
      end
    end
    i += 1
  end
  if path == "/stats"
    b = "threads=#{Thread.list.size} conns=#{$conns} served=#{$served}\n"
    respond(sock, "200 OK", b, keep)
  else
    respond(sock, "200 OK", BODY, keep)
  end
  $lock.synchronize { $served += 1 }
  keep
end

def content_length(head)
  lines = head.split("\r\n")
  n = 0
  lines.each do |line|
    c = line.index(":")
    if c && line[0, c].downcase == "content-length"
      n = line[c + 1, line.size - c - 1].strip.to_i
    end
  end
  n
end

def serve(sock)
  buf = +""
  loop do
    idx = buf.index("\r\n\r\n")
    while idx.nil?
      return if sock.wait_readable($idle).nil?   # idle timeout
      buf << sock.readpartial(16384)
      return if buf.bytesize > 65536                    # header too large
      idx = buf.index("\r\n\r\n")
    end
    head = buf[0, idx]
    rest = buf[idx + 4, buf.bytesize - idx - 4]
    clen = content_length(head)
    while rest.bytesize < clen
      return if sock.wait_readable($idle).nil?
      rest << sock.readpartial(16384)
    end
    body = rest[0, clen]
    buf = rest[clen, rest.bytesize - clen]
    break unless handle_request(sock, head, body)
  end
rescue EOFError
  # client closed
rescue Errno::ECONNRESET, Errno::EPIPE
  # client vanished
rescue IOError => e
  STDERR.puts "IOError: #{e.message}"
ensure
  sock.close unless sock.closed?
  $lock.synchronize { $conns -= 1 }
end

port = (ARGV[0] || "9292").to_i
server = TCPServer.new("127.0.0.1", port)
server.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
STDERR.puts "listening on #{port} pid=#{Process.pid}"
# NOTE: Thread.new(s) { |c| serve(c) } compiles but serve's param loses its
# static type (see repro/thread_new_arg_sock_type.rb) -> NoMethodError on
# wait_readable at runtime. Capture through a method param instead.
def spawn_conn(sock)
  Thread.new { serve(sock) }
end

loop do
  s = server.accept
  $lock.synchronize { $conns += 1 }
  spawn_conn(s)
end
