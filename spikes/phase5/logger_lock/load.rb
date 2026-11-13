# Phase 5b spike, item 9: the load generator run.sh uses when `wrk` is not
# installed (CRuby). Keep-alive connections over 127.0.0.1, one per thread,
# each sending GET / and GET /articles/1 in turn for SECONDS seconds; a
# request slower than 1 s is a stall, a request that fails (a closed
# connection, no answer in 5 s) is an error and the thread reconnects.
#
# usage: ruby load.rb PORT SECONDS THREADS
# Prints one line: requests, requests per second, stalls, errors, the
# slowest request, the status codes seen, and the server's port.
require "socket"

PORT = Integer(ARGV.fetch(0))
SECONDS = Float(ARGV.fetch(1))
THREADS = Integer(ARGV.fetch(2))
PATHS = ["/", "/articles/1"].freeze
STALL = 1.0
TIMEOUT = 5.0

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def connect = Socket.tcp("127.0.0.1", PORT, connect_timeout: TIMEOUT)

def read_exactly(sock, buf, n)
  while buf.bytesize < n
    raise IOError, "timeout" unless sock.wait_readable(TIMEOUT)

    chunk = sock.read_nonblock(65_536, exception: false)
    next if chunk == :wait_readable
    raise IOError, "closed" if chunk.nil?

    buf << chunk
  end
end

# One request on a kept-alive socket; answers the status. Leftover bytes
# stay in `buf` (there are none with one request in flight).
def request(sock, buf, path)
  sock.write("GET #{path} HTTP/1.1\r\nHost: 127.0.0.1:#{PORT}\r\nConnection: keep-alive\r\n\r\n")
  until (head_end = buf.index("\r\n\r\n"))
    raise IOError, "timeout" unless sock.wait_readable(TIMEOUT)

    chunk = sock.read_nonblock(65_536, exception: false)
    next if chunk == :wait_readable
    raise IOError, "closed" if chunk.nil?

    buf << chunk
  end
  head = buf.byteslice(0, head_end)
  status = head[9, 3].to_i
  length = head[/^content-length:\s*(\d+)/i, 1]
  raise IOError, "no Content-Length in #{head.lines.first.inspect}" if length.nil?

  total = head_end + 4 + length.to_i
  read_exactly(sock, buf, total)
  buf.replace(buf.byteslice(total, buf.bytesize - total))
  status
end

results = Array.new(THREADS) { { n: 0, stalls: 0, errors: 0, max: 0.0, codes: Hash.new(0) } }
deadline = now + SECONDS
threads = Array.new(THREADS) do |t|
  Thread.new(results[t]) do |r|
    sock = nil
    buf = +""
    i = t
    while now < deadline
      begin
        sock ||= connect
        started = now
        code = request(sock, buf, PATHS[i % PATHS.size])
        took = now - started
        r[:n] += 1
        r[:codes][code] += 1
        r[:stalls] += 1 if took > STALL
        r[:max] = took if took > r[:max]
      rescue IOError, SystemCallError => e
        r[:errors] += 1
        warn "load: #{e.class}: #{e.message}" if r[:errors] <= 3
        sock&.close
        sock = nil
        buf = +""
      end
      i += 1
    end
    sock&.close
  end
end
threads.each(&:join)
n = results.sum { |r| r[:n] }
codes = Hash.new(0)
results.each { |r| r[:codes].each { |k, v| codes[k] += v } }
puts format("requests %d rps %.0f stalls %d errors %d max_ms %.1f codes %s",
            n, n / SECONDS, results.sum { |r| r[:stalls] }, results.sum { |r| r[:errors] },
            results.map { |r| r[:max] }.max * 1000, codes.sort.to_h.inspect)
