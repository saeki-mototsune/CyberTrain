module Cybertrain
  module Dev
    # Regenerates gen/ and rebuilds the server binary of the application in
    # root, logging both steps' stdout and stderr to log_path (relative to
    # root unless absolute). ErrorPage shows last_output while last_failed.
    # target is the app's bin/<name>.rb executable (the package name);
    # "server" only as a default for tests. While `cybertrain build` holds
    # root/tmp/cybertrain-build.lock (both write build/bin/<target>), #rebuild
    # runs nothing: it fails with last_skipped set and last_output saying so
    # (and, once the lock is gone, that the build has finished).
    class Rebuilder
      attr_reader :log_path, :last_failed, :last_skipped

      SKIPPED_MESSAGE = "cybertrain build in progress (tmp/cybertrain-build.lock); " \
                        "rebuild skipped — save the file again once it finishes"
      FINISHED_MESSAGE = "cybertrain build finished; save a file to rebuild"

      # A lock older than this is presumed abandoned (the build that held it
      # was SIGKILLed, or the machine rebooted) rather than genuinely
      # long-running, so build_in_progress? stops honoring it. Long enough
      # that no real `cybertrain build` should ever hit it.
      STALE_LOCK_AGE = 30 * 60

      def initialize(root, target = "server", log_path = "tmp/rebuild.log")
        @root = root
        @target = target
        @log_path = log_path
        @last_output = ""
        @last_failed = false
        @last_skipped = false
      end

      # Runs `spin run gen && spin build <target>` in root; true on success.
      def rebuild
        if build_in_progress?
          @last_failed = true
          @last_skipped = true
          return false
        end

        ok = system(command)
        log = log_file
        record_build(ok, File.exist?(log) ? File.read(log) : "")
        ok
      end

      # The compiler output of the last build, or, after a skipped rebuild,
      # what the developer should do about it: the text follows the lock,
      # so the banner stops saying "in progress" once the build is over.
      def last_output
        return @last_output unless @last_skipped

        build_in_progress? ? SKIPPED_MESSAGE : FINISHED_MESSAGE
      end

      # Remembers the outcome of a build (what #rebuild does after running).
      def record_build(success, output)
        @last_failed = !success
        @last_output = output
        @last_skipped = false
        nil
      end

      # Created by `cybertrain build`, holding its PID, until dist/ is
      # assembled.
      def lock_path
        File.expand_path("tmp/cybertrain-build.lock", @root)
      end

      # True while a `cybertrain build` holds the lock. A lock whose PID no
      # longer runs (the build was killed, the machine rebooted) is stale:
      # it is deleted and ignored, so the loop does not stay stuck until
      # someone removes it by hand. A lock recording no PID counts as held,
      # unless it is also older than STALE_LOCK_AGE: without the age bound, a
      # PID a SIGKILLed build once held can be reused by an unrelated process
      # and read as still alive, wedging rebuilds forever.
      def build_in_progress?
        path = lock_path
        return false unless File.exist?(path)

        if Time.now - File.mtime(path) >= STALE_LOCK_AGE
          File.delete(path) if File.exist?(path)
          return false
        end

        pid = File.read(path).strip
        return true if pid.empty? || !pid.bytes.all? { |b| b >= 48 && b <= 57 }
        return true if Rebuilder.process_alive?(pid.to_i)

        File.delete(path) if File.exist?(path)
        false
      end

      # Signal 0 probes without delivering anything; EPERM means the process
      # exists but belongs to someone else.
      def self.process_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # The brace group sends a failing `cd` to the log as well.
      def command
        log = log_file
        "mkdir -p #{Rebuilder.shell_quote(File.dirname(log))} && " \
          "{ cd #{Rebuilder.shell_quote(@root)} && spin run gen && spin build #{@target}; } " \
          "> #{Rebuilder.shell_quote(log)} 2>&1"
      end

      def log_file
        File.expand_path(@log_path, @root)
      end

      # Where `spin build <target>` puts the binary.
      def binary_path
        File.expand_path("build/bin/#{@target}", @root)
      end

      def self.shell_quote(text)
        "'#{text.gsub("'", "'\\\\''")}'"
      end
    end
  end
end
