# SPIKE (throwaway): gen2 of the full-loop test -- rebinds and accepts one client.
require "socket"
port = ARGV[0].to_i
srv = TCPServer.new("127.0.0.1", port)
puts "gen2 pid=#{Process.pid} rebound #{srv.addr[1]}"
STDOUT.flush
client = srv.accept
line = client.gets
client.write("echo:#{line}")
client.close
srv.close
puts "gen2: served one client, done"
