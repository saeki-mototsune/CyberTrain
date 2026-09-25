# SPIKE (throwaway): gen2 target -- immediately re-binds the port passed via argv.
require "socket"
port = ARGV[0].to_i
srv = TCPServer.new("127.0.0.1", port)
srv.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
puts "gen2 pid=#{Process.pid} rebound port=#{srv.addr[1]}"
srv.close
puts "ok"
