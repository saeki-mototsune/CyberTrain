# SPIKE (throwaway): Spinel-compiled keep-alive load client with per-request latency (us). usage: loadgen PORT CONC REQS_PER_CONN [idle_conns]
require "socket"
REQ = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"

def now_us
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1_000_000).to_i
end

# read one response: headers until \r\n\r\n, then Content-Length body. returns leftover buffer
def read_resp(s, buf)
  idx = buf.index("\r\n\r\n")
  while idx.nil?
    s.wait_readable(30)
    buf << s.readpartial(16384)
    idx = buf.index("\r\n\r\n")
  end
  head = buf[0, idx]
  c = head.index("Content-Length: ")
  clen = head[c + 16, 12].to_i
  need = idx + 4 + clen
  while buf.bytesize < need
    s.wait_readable(30)
    buf << s.readpartial(16384)
  end
  buf[need, buf.bytesize - need]
end

def worker(port, n)
  lat = []
  s = TCPSocket.new("127.0.0.1", port)
  buf = +""
  i = 0
  while i < n
    t = now_us
    s.write(REQ)
    buf = read_resp(s, buf)
    lat << (now_us - t)
    i += 1
  end
  s.close
  lat
end

def spawn_worker(port, n)
  Thread.new { worker(port, n) }
end

port = ARGV[0].to_i
conc = ARGV[1].to_i
per = ARGV[2].to_i
idle = []
(ARGV[3] || "0").to_i.times { idle << TCPSocket.new("127.0.0.1", port) }
t0 = now_us
ths = []
conc.times { ths << spawn_worker(port, per) }
all = []
ths.each { |t| t.value.each { |x| all << x } }
el = now_us - t0
all.sort!
nn = all.size
puts "conc=#{conc} idle=#{idle.size} reqs=#{nn} rps=#{(nn * 1_000_000 / el)} p50=#{all[nn / 2]}us p99=#{all[nn * 99 / 100]}us p99.9=#{all[nn * 999 / 1000]}us max=#{all[nn - 1]}us"
idle.each { |s| s.close }
