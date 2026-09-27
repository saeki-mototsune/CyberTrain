module Cybertrain
  module Dev
    # Regenerates gen/ and rebuilds the server binary of the application in
    # root, logging both steps' stdout and stderr to log_path (relative to
    # root unless absolute). ErrorPage shows last_output while last_failed.
    # target is the app's bin/<name>.rb executable (the package name);
    # "server" only as a default for tests. While `cybertrain build` holds
    # root/tmp/cybertrain-build.lock (both write build/bin/<target>), #rebuild
    # runs nothing: it fails with last_skipped set and a message that says so.
    class Rebuilder
      attr_reader :root, :target, :log_path, :last_output, :last_failed, :last_skipped

      SKIPPED_MESSAGE = "cybertrain build in progress; rebuild skipped — save the file again once it finishes"

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
        if File.exist?(lock_path)
          record_build(false, SKIPPED_MESSAGE)
          @last_skipped = true
          return false
        end

        ok = system(command)
        log = log_file
        record_build(ok, File.exist?(log) ? File.read(log) : "")
        ok
      end

      # Remembers the outcome of a build (what #rebuild does after running).
      def record_build(success, output)
        @last_failed = !success
        @last_output = output
        @last_skipped = false
        nil
      end

      # Created by `cybertrain build` for the duration of its steps.
      def lock_path
        File.expand_path("tmp/cybertrain-build.lock", @root)
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
