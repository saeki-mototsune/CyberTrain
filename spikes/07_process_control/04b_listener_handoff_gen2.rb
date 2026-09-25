# SPIKE (throwaway): gen2 rebinds the port passed via argv/marker with SO_REUSEADDR set.
require "socket"

port = ARGV[0].to_i
srv = TCPServer.new("127.0.0.1", port)
srv.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
puts "gen2 rebound port #{port} OK, pid=#{Process.pid}"
srv.close
