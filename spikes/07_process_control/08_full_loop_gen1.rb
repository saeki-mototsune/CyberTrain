# SPIKE (throwaway): full dev-server restart loop -- trap("HUP") closes the
# listening socket and execv's into gen2, which rebinds the same port and
# keeps serving. This is the actual mechanism cybertrain's D12 dev server needs.
require "socket"

module ExecShim
  ffi_source <<~C
    #include <unistd.h>
    int sp_reexec(const char *path, const char *port_arg) {
      char *argv[3];
      argv[0] = (char *)path;
      argv[1] = (char *)port_arg;
      argv[2] = NULL;
      return execv(path, argv);
    }
  C
  ffi_func :sp_reexec, [:str, :str], :int
end

srv = TCPServer.new("127.0.0.1", 0)
srv.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1)
port = srv.addr[1]
puts "gen1 pid=#{Process.pid} listening on #{port}"
STDOUT.flush

trap("HUP") do
  puts "gen1: HUP received, closing socket and re-exec'ing"
  STDOUT.flush
  srv.close
  ExecShim.sp_reexec(File.expand_path("out_gen2_full", __dir__), port.to_s)
  puts "reexec failed"
  exit 1
end

30.times { sleep 0.2 }
puts "gen1: timed out waiting for HUP"
