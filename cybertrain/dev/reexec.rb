module Cybertrain
  module Dev
    # Replaces the running server with a freshly built binary, keeping the
    # PID (spikes/07_process_control). The C shim passes the port as argv[1].
    #
    # Before execv it unblocks every signal, because exec inherits the
    # calling thread's signal mask: were HUP blocked there, the new process
    # could never be sent HUP again. Application calls it from the main
    # thread, outside any signal handler (Spinel runs trap blocks inside
    # its C signal handler, where execv's surroundings are unsafe), so this
    # is a guard, not a requirement. It
    # also marks every descriptor above stderr close-on-exec, so client
    # connections and the database do not leak into the new process.
    module Reexec
      ffi_source <<~C
        #include <unistd.h>
        #include <fcntl.h>
        #include <signal.h>
        #include <pthread.h>
        int sp_reexec(const char *path, const char *port_arg) {
          char *argv[3];
          sigset_t none;
          long max_fd = sysconf(_SC_OPEN_MAX);
          if (max_fd < 0 || max_fd > 65536) max_fd = 65536;
          for (int fd = 3; fd < max_fd; fd++) fcntl(fd, F_SETFD, FD_CLOEXEC);
          sigemptyset(&none);
          pthread_sigmask(SIG_SETMASK, &none, NULL);
          argv[0] = (char *)path;
          argv[1] = (char *)port_arg;
          argv[2] = NULL;
          return execv(path, argv);
        }
      C
      ffi_func :sp_reexec, [:str, :str], :int

      # Never returns on success; returns execv's -1 when the exec failed.
      def self.exec_self(binary_path, port)
        Reexec.sp_reexec(binary_path, port)
      end
    end
  end
end
