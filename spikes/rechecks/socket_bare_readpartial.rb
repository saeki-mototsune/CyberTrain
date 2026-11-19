# Reduced shape only: NOTES 20. At `SPINEL_WORKERS=1` another green thread
# keeps running while one sits in a bare `readpartial`. One idle connection;
# decided by a 0.35 s timing window, so a loaded machine can fail it.
require "socket"
ENV["SPINEL_WORKERS"] = "1"
srv = TCPServer.new("127.0.0.1", 0)
port = srv.addr[1]
ticks = 0
idle = Thread.new do
  c = srv.accept
  begin
    c.readpartial(10)   # nothing is ever sent for 0.6 s
  rescue EOFError
  end
  c.close
end
cl = TCPSocket.new("127.0.0.1", port)
ticker = Thread.new do
  6.times { sleep 0.1; ticks += 1 }
end
sleep 0.35
seen = ticks
ticker.join
cl.close
idle.join
puts(seen >= 2 ? "ticker ran while readpartial waited" : "ticker stalled (#{seen})")
