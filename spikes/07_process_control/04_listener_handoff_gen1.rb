# SPIKE (throwaway): can gen1 bind a TCPServer with SO_REUSEADDR, close it, execv into gen2, and can gen2
# immediately bind the SAME port with no "address already in use"?
require "socket"

module Exec
  ffi_source <<~C
    #include <unistd.h>
    int sp_exec_self(const char *path, const char *port_str) {
      char *argv[3];
      argv[0] = (char *)path;
      argv[1] = (char *)port_str;
      argv[2] = NULL;
      execv(path, argv);
      return -1;
    }
  C
  ffi_func :sp_exec_self, [:str, :str], :int
end

srv = TCPServer.new("127.0.0.1", 0)
srv.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
port = srv.addr[1]
puts "gen1 bound port #{port}, pid=#{Process.pid}"
STDOUT.flush
srv.close

target = ARGV[0]
rc = Exec.sp_exec_self(target, port.to_s)
puts "execv failed rc=#{rc}"
