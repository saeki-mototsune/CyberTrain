# SPIKE (throwaway): open a TCPServer with SO_REUSEADDR, close it, then execv into
# gen2 which immediately re-binds the same port. Verifies no "address in use" race.
require "socket"

module ExecShim
  ffi_source <<~C
    #include <unistd.h>
    int sp_exec_self2(const char *path, const char *port_arg) {
      char *argv[3];
      argv[0] = (char *)path;
      argv[1] = (char *)port_arg;
      argv[2] = NULL;
      return execv(path, argv);
    }
  C
  ffi_func :sp_exec_self2, [:str, :str], :int
end

srv = TCPServer.new("127.0.0.1", 0)
srv.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
port = srv.addr[1]
puts "gen1 pid=#{Process.pid} bound port=#{port}"
STDOUT.flush
srv.close
rc = ExecShim.sp_exec_self2(File.expand_path("out_gen2_reuse", __dir__), port.to_s)
puts "execv failed rc=#{rc}"
