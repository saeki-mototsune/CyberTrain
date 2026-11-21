module Nap
  ffi_source <<~C
    #include <time.h>
    #include <errno.h>
    int probe_nap(int ms) {
      struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
      while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
      return 0;
    }
  C
  ffi_func :probe_nap, [:int], :int, offload: true
end
def napper = Thread.new { Nap.probe_nap(600) }
t0 = Time.now.to_f
n = napper
ticks = 0
while Time.now.to_f - t0 < 0.5
  sleep 0.05
  ticks += 1
end
n.join
puts "ticks=#{ticks}"
