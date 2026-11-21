# Reduced shapes only: NOTES 21 and 27, over loopback TCP. `IO#gets` on a
# socket still returns a character String on 2026.11.04.7026 (NOTES status
# 27), so it is not here.
require "socket"

# 21: a socket handed over as a `Thread.new` argument.
echo_srv = TCPServer.new("127.0.0.1", 0)
echo_thread = Thread.new do
  sock = echo_srv.accept
  th = Thread.new(sock) do |c|
    if c.wait_readable(2)
      data = c.readpartial(100)
      c.write("echo:" + data)
    end
    c.close
  end
  th.join
end
echo_cl = TCPSocket.new("127.0.0.1", echo_srv.addr[1])
echo_cl.write("ping")
echo_cl.wait_readable(2)
puts echo_cl.readpartial(100)
echo_cl.close
echo_thread.join

# 27: what `readpartial` on a socket returns, accumulated in a buffer.
part_srv = TCPServer.new("127.0.0.1", 0)
part_thread = Thread.new do
  c = part_srv.accept
  c.write("héllo\r\nrest")
  c.close
end
part_cl = TCPSocket.new("127.0.0.1", part_srv.addr[1])
buf = +""
while part_cl.wait_readable(2)
  begin
    buf << part_cl.readpartial(100)
  rescue EOFError
    break
  end
end
part_thread.join
puts buf.encoding
puts buf.size
puts buf.bytesize
puts buf.index("\r\n")
puts buf.byteindex("\r\n")

# 27: what `read(n)` returns.
read_srv = TCPServer.new("127.0.0.1", 0)
read_thread = Thread.new do
  c = read_srv.accept
  c.write("café")
  c.close
end
read_cl = TCPSocket.new("127.0.0.1", read_srv.addr[1])
three = read_cl.read(3)
puts "read " + three.encoding.to_s + " #{three.size} #{three.bytesize}"
read_cl.close
read_thread.join

# 27: what `read_nonblock` returns, and Strings sliced, concatenated,
# interpolated, duplicated and split from it; then `readpartial` appended to
# `String.new`.
nb_srv = TCPServer.new("127.0.0.1", 0)
nb_thread = Thread.new do
  c = nb_srv.accept
  c.write("café 日本\r\nXY")
  sleep 0.3
  c.write("héé\r\nmore")
  c.close
end
nb_cl = TCPSocket.new("127.0.0.1", nb_srv.addr[1])
nb_cl.wait_readable(2)
got = nb_cl.read_nonblock(100, exception: false)
case got
when String
  puts "nb " + got.encoding.to_s + " #{got.size} #{got.bytesize}"
  head = got.byteslice(0, 5)
  puts "slice " + head.encoding.to_s + " #{head.size} #{head.bytesize}"
  cat = "x" + got
  puts "cat " + cat.encoding.to_s + " #{cat.size} #{cat.bytesize}"
  ip = "#{got}"
  puts "interp " + ip.encoding.to_s + " #{ip.size} #{ip.bytesize}"
  d = got.dup
  puts "dup " + d.encoding.to_s + " #{d.size}"
  puts got.index("\r\n").to_s + " " + got.byteindex("\r\n").to_s
  parts = got.split("\r\n")
  puts "split " + parts[0].encoding.to_s + " #{parts[0].size}"
else
  puts "not a string"
end
sleep 0.5
nb_cl.wait_readable(2)
acc = String.new
acc << nb_cl.readpartial(100)
puts "acc " + acc.encoding.to_s + " #{acc.size} #{acc.bytesize}"
nb_cl.close
nb_thread.join
