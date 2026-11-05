require "cybertrain/app_name"
require "cybertrain/cast"
require "cybertrain/shell"

module Cybertrain
  module Dev
    # Regenerates gen/ and rebuilds the server binary of the application in
    # root, logging both steps' stdout and stderr to log_path (relative to
    # root unless absolute). The build is Spinel's `--incremental` one, which
    # recompiles only the C units an edit changed; a toolchain that predates
    # the flag refuses it, and from then on #rebuild builds without it. An
    # edit that leaves gen's C as it was skips compiling gen as well
    # (docs/design.md, section 6).
    # ErrorPage shows last_output while last_failed.
    # target is the app's bin/<name>.rb executable (the package name);
    # "server" only as a default for tests. ArgumentError when
    # AppName.problem refuses it. While `cybertrain build` holds
    # root/tmp/cybertrain-build.lock (both write build/bin/<target>), #rebuild
    # runs nothing: it fails with last_skipped set and last_output saying so
    # (and, once the lock is gone, that the build has finished).
    class Rebuilder
      attr_reader :log_path, :last_failed, :last_skipped, :incremental

      SKIPPED_MESSAGE = "cybertrain build in progress (tmp/cybertrain-build.lock); " \
                        "rebuild skipped — save the file again once it finishes"
      FINISHED_MESSAGE = "cybertrain build finished; save a file to rebuild"

      # What spinel says to a flag it does not know: a Spinel release older
      # than `--incremental` fails the build with it.
      UNSUPPORTED_INCREMENTAL = "unknown option '--incremental'"

      # What `spin run gen` leaves behind, run without compiling it again.
      DIRECT_GEN = "./build/bin/gen"

      # The C of bin/gen.rb as the compiler sees it now, and the one
      # build/bin/gen was compiled from. Under build/, because spin complains
      # on every command about spinel's output anywhere else in the package.
      GEN_CHECK = "build/gen-check.c"
      GEN_COMPILED = "build/gen-compiled.c"

      # The binary that C was compiled to, as modification time and size: a
      # `spin run gen` by hand replaces it behind the saved C.
      GEN_BINARY = "build/bin/gen"
      GEN_STAMP = "build/gen-compiled.stamp"

      # A lock older than this is presumed abandoned (the build that held it
      # was SIGKILLed, or the machine rebooted) rather than genuinely
      # long-running, so build_in_progress? stops honoring it. Long enough
      # that no real `cybertrain build` should ever hit it.
      STALE_LOCK_AGE = 30 * 60

      def initialize(root, target = "server", log_path = "tmp/rebuild.log")
        # The target is only ever shelled out with here (and by the CLI, which
        # checks the same predicate in Build.app_name), so the check lives
        # where the name is used: a production boot, which never builds,
        # neither pays nor fails for it. The quoting in #command is for the
        # shell only.
        problem = AppName.problem(target)
        raise ArgumentError, "build target #{target.inspect} #{problem}" unless problem.empty?

        @root = root
        @target = target
        @log_path = log_path
        @last_output = ""
        @last_failed = false
        @last_skipped = false
        @incremental = true
      end

      # Runs `spin run gen && spin build <target> -- --incremental` in root;
      # true on success. While #gen_fresh?, gen is the binary already built,
      # which saves compiling it; if that run fails, for whatever reason, the
      # full command follows, so a broken binary never strands the loop. When
      # the toolchain refuses `--incremental`, runs the plain build at once
      # and keeps to it for the rest of the process. The check comes before
      # the build: an edit made during the build then reads as a change next
      # time. A retry after a fresh check records the binary even if the
      # build fails: it came from the same C, and an error in the application
      # must not cost a compile of gen on every attempt to fix it.
      def rebuild
        if build_in_progress?
          @last_failed = true
          @last_skipped = true
          return false
        end

        fresh = gen_fresh?
        direct = fresh && system(command(@incremental, DIRECT_GEN))
        ok = direct || system(command(@incremental))
        output = read_log
        if !ok && @incremental && Rebuilder.incremental_unsupported?(output)
          @incremental = false
          ok = system(command(false))
          output = read_log
        end
        promote_gen_check if !direct && (ok || fresh)
        record_build(ok, output)
        ok
      end

      # True when build/bin/gen is what bin/gen.rb compiles to now: the C is
      # the saved one, and the binary is the one saved with it. Anything
      # else, a check that fails included, means the full command, which
      # reports real errors. A stale check forgets the saved C at once: the
      # full command replaces the binary even if the build then fails, and
      # going back to the old source must not read as a match.
      def gen_fresh?
        fresh = gen_check_matches?
        compiled = File.expand_path(GEN_COMPILED, @root)
        File.delete(compiled) if !fresh && File.exist?(compiled)
        fresh
      rescue StandardError
        false
      end

      # Runs the check and compares its C with the saved one. A failed check
      # leaves no C behind, so that #promote_gen_check has nothing to promote.
      def gen_check_matches?
        check = File.expand_path(GEN_CHECK, @root)
        compiled = File.expand_path(GEN_COMPILED, @root)
        File.delete(check) if File.exist?(check)
        unless system(gen_check_command)
          File.delete(check) if File.exist?(check)
          return false
        end
        stamp = File.expand_path(GEN_STAMP, @root)
        return false unless File.file?(compiled) && File.file?(stamp)
        return false unless File.read(stamp) == gen_binary_stamp

        File.binread(check) == File.binread(compiled)
      rescue StandardError
        false
      end

      # The C that was checked becomes the saved one, after a full build, with
      # the binary that build left. A failure only means the next rebuild
      # compiles gen again.
      def promote_gen_check
        check = File.expand_path(GEN_CHECK, @root)
        return nil unless File.exist?(check)

        File.write(File.expand_path(GEN_STAMP, @root), gen_binary_stamp)
        File.rename(check, File.expand_path(GEN_COMPILED, @root))
        nil
      rescue StandardError
        nil
      end

      # True when a failed build's output is spinel refusing `--incremental`.
      def self.incremental_unsupported?(output)
        output.include?(UNSUPPORTED_INCREMENTAL)
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
        return true if pid.empty? || !Cast.digits?(pid)
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

      # The brace group sends a failing `cd` to the log as well. Every
      # interpolated value is quoted, which is what keeps a stray quote in a
      # name from reaching sh (AppName.problem does not refuse a quote).
      # Everything after `spin build`'s `--` goes to spinel. A build with
      # such flags is never "up to date" to spin, which a rebuild that a
      # change triggered never is anyway.
      def command(incremental = true, gen = "spin run gen")
        log = log_file
        build = "spin build #{Shell.quote(@target)}"
        build += " -- --incremental" if incremental
        "mkdir -p #{Shell.quote(File.dirname(log))} && " \
          "{ cd #{Shell.quote(@root)} && #{gen} && #{build}; } " \
          "> #{Shell.quote(log)} 2>&1"
      end

      # bin/gen.rb to C with the flags spin gives it. Without #line, so a
      # moved comment is not a change. spin flags goes through a variable
      # because a failing $(...) among arguments would not fail the command;
      # its output is split by the shell, so an app under a path with a space
      # fails the check and takes the full command.
      def gen_check_command
        "{ cd #{Shell.quote(@root)} && mkdir -p build && flags=$(spin flags) && " \
          "spinel bin/gen.rb -c -o #{GEN_CHECK} --force --no-line-map $flags; } " \
          "> /dev/null 2>&1"
      end

      # Raises when there is no binary, which reads as not fresh.
      def gen_binary_stamp
        binary = File.expand_path(GEN_BINARY, @root)
        time = File.mtime(binary)
        "#{time.to_i}.#{time.nsec}:#{File.size(binary)}"
      end

      def log_file
        File.expand_path(@log_path, @root)
      end

      def read_log
        log = log_file
        File.exist?(log) ? File.read(log) : ""
      end

      # Where `spin build <target>` puts the binary.
      def binary_path
        File.expand_path("build/bin/#{@target}", @root)
      end
    end
  end
end
