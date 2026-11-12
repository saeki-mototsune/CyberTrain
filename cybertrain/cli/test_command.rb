# `cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]` (spec section 8): every
# test of the application in one program. The arguments are checked first
# (Test::Args, the same parser the compiled bundle filters with), then
# `spin run gen` writes gen/tests.rb and gen/test/**, gen/tests.rb is
# compiled into build/test/tests only when an input changed since that
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
      # (fixtures, locales) and templates. A file of another kind that gen
      # or the program reads at build time is not watched: none exists
      # today; add its extension here when one does.
      INPUTS = [".rb", ".yml", ".erb"].freeze
      # Beside the binary: what it was built from (TestCommand.compile_bundle).
      RECORD = ".inputs".freeze

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
        # Before any step: a compile takes minutes. Parsed against the
        # absolute root, as the bundle parses against Dir.pwd, so an
        # absolute file argument means the same to both.
        args = Cybertrain::Test::Args.parse(argv, files, File.expand_path(root))
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
          return 1 unless compile_bundle(root, runner)
        end
        runner.run_tests(root, argv)
      end

      # Compiles build/test/tests and records what it was built from in
      # build/test/tests.inputs ({inputs_record}). The record is written
      # before the compile starts and kept only when it succeeds, so its
      # mtime is the start: a source edited during the compile is newer
      # than it. The old binary and record go first, so an interrupted or
      # failed compile leaves nothing that looks fresh.
      def self.compile_bundle(root, runner)
        binary = "#{root}/#{BINARY}"
        record = "#{binary}#{RECORD}"
        pending = "#{record}.tmp"
        Templates.mkdir_p("#{root}/build/test")
        File.delete(binary) if File.exist?(binary)
        File.delete(record) if File.exist?(record)
        File.write(pending, inputs_record(root, spin_flags_in(root)))
        unless runner.run_step(root, compile_command(root))
          File.delete(pending) if File.exist?(pending)
          return false
        end
        File.rename(pending, record)
        true
      end

      # `spin flags` in root.
      def self.spin_flags_in(root)
        `cd #{Shell.quote(root)} && spin flags`
      end

      # What a bundle is built from besides its sources' contents: the
      # compile command, the `spin flags` output (which framework checkout
      # and which load path), each framework root's cybertrain/version.rb,
      # and spin.toml and spin.lock as they are. A different record
      # (another framework version or checkout, a repointed dependency)
      # means a compile, whatever the mtimes say.
      # @param root [String]
      # @param flags [String] the `spin flags` output
      # @return [String]
      def self.inputs_record(root, flags)
        out = +"compile: #{compile_command(root)}\nflags: #{flags.strip}\n"
        framework_roots(root, flags).each do |dir|
          out << "framework: #{dir}\n" << file_text("#{dir}/cybertrain/version.rb")
        end
        out << "spin.toml:\n" << file_text("#{root}/spin.toml")
        out << "spin.lock:\n" << file_text("#{root}/spin.lock")
        out
      end

      # path's contents, or "(none)\n".
      def self.file_text(path)
        File.file?(path) ? File.read(path) : "(none)\n"
      end

      # The bundle's compile, run in the application's directory (plan
      # decision 7, as task 1's spike recorded it): gen/test before test,
      # so a top-level-form file's `require "test_helper"` finds the copy
      # the bundle already loaded (ruling R9). `$(spin flags)` is split by
      # the shell, as spin prints it: a path with a space in it cannot be
      # passed through it.
      # @param root [String]
      # @return [String]
      def self.compile_command(root)
        "spinel gen/tests.rb $(spin flags) -I gen/test -I test -o #{BINARY}"
      end

      # Whether binary must be compiled again: it or its record
      # (binary + ".inputs", written by {compile_bundle}) is missing, the record
      # differs from {inputs_record} now, or an input is newer than the
      # record (the compile's start): a *.rb, *.yml or *.erb of the
      # application (outside build/, dist/, tmp/, storage/ and dot
      # directories), the framework's cybertrain.rb and cybertrain/**/*.rb
      # (the framework root is the `-I` of `spin flags` that is not the
      # application), or a toolchain file of `spin flags --deps`.
      # @param root [String]
      # @param binary [String]
      # @return [Boolean]
      def self.stale?(root, binary)
        record = "#{binary}#{RECORD}"
        return true unless File.file?(binary) && File.file?(record)

        flags = spin_flags_in(root)
        return true unless File.read(record) == inputs_record(root, flags)

        built = mtime_ns(record)
        return true if newer_under?(root, "", built, true)

        framework_roots(root, flags).each do |dir|
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
