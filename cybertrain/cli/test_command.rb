# `cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]` (spec section 8): every
# test of the application in one program. The arguments are checked first
# (Test::Args, the same parser the compiled bundle filters with), then
# `spin run gen` writes gen/tests.rb and gen/test/**, gen/tests.rb is
# compiled into build/test/tests only when an input is newer than that
# binary, and the binary runs with the arguments: a filter never
# recompiles. gen's and the compiler's output go to stderr, so stdout is
# the test run's alone. Plain Ruby: runs under CRuby (the gem) and compiles
# under Spinel (bin/cybertrain.rb).
require "cybertrain/shell"
require "cybertrain/test_files"
require "cybertrain/test/args"
require "cybertrain/cli/templates"
require "cybertrain/cli/toolchain"

module Cybertrain
  module CLI
    module TestCommand
      BINARY = "build/test/tests".freeze
      GEN = "spin run gen".freeze
      # The application's top-level directories whose files are no input of
      # the bundle: build output, the release, scratch files, data.
      SKIPPED = ["build", "dist", "tmp", "storage"].freeze
      # The extensions of the files the bundle is built from: Ruby, YAML
      # (fixtures, locales) and templates.
      INPUTS = [".rb", ".yml", ".erb"].freeze

      # The world outside the command: the toolchain, the shell and stdout.
      # TestCommand.run takes one so tests can stand in for spin.
      class Runner
        # Whether a Spinel of the pinned release is on PATH (installed the
        # first time).
        def ready?
          Toolchain.ensure!
        end

        # Runs a spin or spinel command in root, its output on stderr; true
        # when it succeeds.
        def run_step(root, command)
          system("cd #{Shell.quote(root)} && #{command} 1>&2")
        end

        def stale?(root)
          TestCommand.stale?(root, "#{root}/#{BINARY}")
        end

        # Runs build/test/tests in root with argv; its exit status.
        def run_tests(root, argv)
          words = argv.map { |arg| Shell.quote(arg) }.join(" ")
          command = "cd #{Shell.quote(root)} && ./#{BINARY} #{words}"
          pid = Process.spawn("/bin/sh", "-c", command)
          Process.wait(pid)
          TestCommand.exit_code($?)
        end

        # Prints a line of the command's own (not the test run's) on stdout.
        def say(text)
          puts text
          nil
        end
      end

      # The command; its exit status: the test run's (0 or 1), 2 for bad
      # arguments, 1 when gen, the compile or the bundle (gen's refusal of
      # duplicate helpers) fails.
      # @param root [String]
      # @param argv [Array<String>]
      # @return [Integer]
      def self.run(root, argv, runner = Runner.new)
        files = TestFiles.list(root)
        # Before any step: a compiled bundle boots the application before it
        # reads its arguments, and a compile takes minutes.
        args = Cybertrain::Test::Args.parse(argv, files, root)
        unless args.arg_error.empty?
          runner.say("#{Cybertrain::Test::Args::USAGE}\n#{args.arg_error}")
          return 2
        end
        if files.empty?
          runner.say("0 tests, 0 assertions, 0 failures")
          return 0
        end
        return 1 unless runner.ready?
        return 1 unless runner.run_step(root, GEN)

        problem = refusal(root)
        unless problem.empty?
          runner.say(problem)
          return 1
        end
        if runner.stale?(root)
          Templates.mkdir_p("#{root}/build/test")
          return 1 unless runner.run_step(root, compile_command(root))
        end
        runner.run_tests(root, argv)
      end

      # The bundle's compile, run in the application's directory (plan
      # decision 7, as task 1's spike recorded it): gen/test before test,
      # so a top-level-form file's `require "test_helper"` finds the copy
      # the bundle already loaded (ruling R9).
      # @param root [String]
      # @return [String]
      def self.compile_command(root)
        "spinel gen/tests.rb $(spin flags) -I gen/test -I test -o #{BINARY}"
      end

      # Whether binary must be compiled again: it is missing, or one of its
      # inputs is newer: a *.rb, *.yml or *.erb of the application (outside
      # build/, dist/, tmp/, storage/ and dot directories), the framework's
      # cybertrain.rb and cybertrain/**/*.rb (the framework root is the
      # `-I` of `spin flags` that is not the application), or a toolchain
      # file of `spin flags --deps`.
      # @param root [String]
      # @param binary [String]
      # @return [Boolean]
      def self.stale?(root, binary)
        built = mtime_ns(binary)
        return true if built < 0
        return true if newer_under?(root, "", built, true)

        framework_roots(root, `cd #{Shell.quote(root)} && spin flags`).each do |dir|
          return true if mtime_ns("#{dir}/cybertrain.rb") > built
          return true if newer_under?(dir, "cybertrain", built, false)
        end
        `cd #{Shell.quote(root)} && spin flags --deps`.split.each do |path|
          return true if mtime_ns(path) > built
        end
        false
      end

      # The `-I` directories of `spin flags` output other than root's own.
      def self.framework_roots(root, flags)
        own = File.expand_path(root)
        out = Array.new(0) { "" }
        words = flags.split
        i = 0
        while i < words.size
          if words[i] == "-I" && i + 1 < words.size
            dir = File.expand_path(words[i + 1], own)
            out << dir unless dir == own || out.include?(dir)
            i += 2
          else
            i += 1
          end
        end
        out
      end

      # Whether a bundle input under base/rel is newer than built; at the
      # application's top level (top) SKIPPED is left out. Dot entries
      # (.git, .github) never are inputs.
      def self.newer_under?(base, rel, built, top)
        dir = rel.empty? ? base : "#{base}/#{rel}"
        return false unless File.directory?(dir)

        Dir.children(dir).each do |entry|
          next if entry.start_with?(".")
          next if top && SKIPPED.include?(entry)

          child = rel.empty? ? entry : "#{rel}/#{entry}"
          path = "#{base}/#{child}"
          if File.directory?(path)
            return true if newer_under?(base, child, built, false)
          elsif INPUTS.any? { |ext| entry.end_with?(ext) }
            return true if mtime_ns(path) > built
          end
        end
        false
      end

      # path's mtime in nanoseconds, -1 when it is no file.
      def self.mtime_ns(path)
        return -1 unless File.file?(path)

        t = File.mtime(path)
        t.to_i * 1_000_000_000 + t.nsec
      end

      # gen's refusal of the bundle (a gen/tests.rb that only aborts, with
      # the reason: duplicate top-level helpers, an unsupported block form),
      # or "" when gen/tests.rb is a program to compile.
      # @param root [String]
      # @return [String]
      def self.refusal(root)
        path = "#{root}/gen/tests.rb"
        return "" unless File.file?(path)

        File.read(path).each_line do |line|
          text = line.chomp
          next if text.start_with?("#") || text.empty?
          return "" unless text.start_with?("abort(\"") && text.end_with?("\")")

          return unescape(text[7, text.size - 9].to_s)
        end
        ""
      end

      # The text of a Ruby double-quoted literal's body as gen writes it
      # (\\, \", \n and \#).
      def self.unescape(body)
        out = +""
        i = 0
        while i < body.size
          ch = body[i]
          if ch == "\\" && i + 1 < body.size
            nxt = body[i + 1]
            out << (nxt == "n" ? "\n" : nxt)
            i += 2
          else
            out << ch
            i += 1
          end
        end
        out
      end

      # A child's exit status, 1 when it has none (a signal ended it).
      def self.exit_code(status)
        return 1 if status.nil?

        code = status.exitstatus
        code.nil? ? 1 : code
      end
    end
  end
end
