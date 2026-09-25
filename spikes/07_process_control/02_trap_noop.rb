# SPIKE (throwaway): does trap("TERM") { ... } compile and actually fire on kill -TERM?
# (test/signal_trap_stub.rb in the spinel source says trap compiles to a no-op.)
puts "pid=#{Process.pid}"
trap("TERM") { puts "GOT TERM"; exit 0 }
puts "waiting"
30.times do |i|
  sleep 0.2
end
puts "timed out, trap never fired"
