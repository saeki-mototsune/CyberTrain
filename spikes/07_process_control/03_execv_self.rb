# SPIKE (throwaway): can a Spinel binary execv() into another binary via an ffi_source C shim?
# Builds argv = {path, marker_arg, NULL} and calls execv, replacing the process image.

module Exec
  ffi_source <<~C
    #include <unistd.h>
    int sp_exec_self(const char *path, const char *arg1) {
      char *argv[3];
      argv[0] = (char *)path;
      argv[1] = (char *)arg1;
      argv[2] = NULL;
      execv(path, argv);
      return -1; /* only reached if execv failed */
    }
  C
  ffi_func :sp_exec_self, [:str, :str], :int
end

target = ARGV[0]

puts "gen 1, pid=#{Process.pid}"
STDOUT.flush
rc = Exec.sp_exec_self(target, "gen2marker")
puts "execv failed, rc=#{rc}"
