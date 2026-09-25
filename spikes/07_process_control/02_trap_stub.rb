# SPIKE (throwaway): does trap("TERM") { ... } actually fire on a real SIGTERM in a compiled Spinel binary?
# (spinel test/signal_trap_stub.rb documents trap as a compile-time no-op; verify against a real signal too)

fired = false
trap("TERM") { fired = true; puts "TERM HANDLER FIRED" }
puts "pid=#{Process.pid}"
puts "waiting"
STDOUT.flush
sleep 3
puts "fired=#{fired}"
