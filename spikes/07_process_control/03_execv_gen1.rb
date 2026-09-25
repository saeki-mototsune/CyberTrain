# SPIKE (throwaway): execv-based self-replacement, generation 1.
# Uses an ffi_source C shim sp_exec_self(path) that builds argv {path, NULL}
# and calls execv, replacing the running process image in place.
module ExecShim
  ffi_source <<~C
    #include <unistd.h>
    #include <stdlib.h>
    int sp_exec_self(const char *path) {
      char *argv[2];
      argv[0] = (char *)path;
      argv[1] = NULL;
      return execv(path, argv);
    }
  C
  ffi_func :sp_exec_self, [:str], :int
end

puts "gen 1 pid=#{Process.pid}"
STDOUT.flush
rc = ExecShim.sp_exec_self(File.expand_path("out_gen2", __dir__))
# if we get here, execv failed
puts "execv failed rc=#{rc}"
