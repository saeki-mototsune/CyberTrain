# Cybertrain::Test::Bundle -- the runner of `cybertrain test`'s program,
# gen/tests.rb (spec sections 5.2 and 8): its boot (a fresh, migrated test
# database and the application, plan decision 19) and its run over every
# test of the application, filtered by the run-time arguments
# (Cybertrain::Test::Args, plan decision 11), printed as plan decision 5
# says: a heading per file, a line per test, then the totals.
require "cybertrain"
require "cybertrain/test"
require "cybertrain/test/args"

module Cybertrain
  module Test
    # gen/tests.rb boots with {boot!}, hands over its table of class-form
    # tests with {use_table} and ends with `exit(Bundle.run!(ARGV, dispatcher))`.
    # @api private
    module Bundle
      # The class-form tests, parallel Arrays (gen's Gen::Tests table), and
      # the test files in path order.
      @files = Array.new(0) { "" }
      @case_file = Array.new(0) { "" }
      @case_line = Array.new(0) { 0 }
      @case_class = Array.new(0) { "" }
      @case_name = Array.new(0) { "" }
      @case_method = Array.new(0) { "" }
      # The zone config/app.rb configured, restored before every test.
      @configured_zone = Cybertrain::Clock.zone
      @zone_hooked = false
      # The framework's own tests read the printed lines here.
      @capturing = false
      @captured = Array.new(0) { "" }

      # The database `cybertrain test` may delete: storage/test.sqlite3, or
      # the file CYBERTRAIN_TEST_DATABASE names.
      DEFAULT_DATABASE = "storage/test.sqlite3".freeze

      # Hands over gen's table: the test files in path order, then one entry
      # per class-form test (its file, the line of its `test` call, its
      # class, name and method), in the order of Gen::Tests.run_case's arms.
      # @return [nil]
      def self.use_table(files, case_file, case_line, case_class, case_name, case_method)
        @files = files
        @case_file = case_file
        @case_line = case_line
        @case_class = case_class
        @case_name = case_name
        @case_method = case_method
        nil
      end

      # Why boot must not delete the configured database ("" when it may):
      # the environment is not test, or the path is neither
      # storage/test.sqlite3 nor the one CYBERTRAIN_TEST_DATABASE names.
      # @return [String]
      def self.refusal
        c = Cybertrain.config
        path = c.database_path
        named = ENV["CYBERTRAIN_TEST_DATABASE"].to_s
        return "" if c.env == "test" && (path == DEFAULT_DATABASE || (!named.empty? && path == named))

        "cybertrain test refuses to delete #{path}: not a test database (env #{c.env})"
      end

      # Boots the application on a new test database: refuses first
      # ({refusal}, raising ArgumentError, nothing deleted), turns forgery
      # protection off unless config/app.rb set `csrf` (Rails' test
      # environment), deletes the database and its -wal / -shm, migrates
      # Migration.all (quietly), boots, and sets {Cybertrain::Test.app}. Every test
      # then starts in the configured time zone (a reset hook).
      # @param router [Cybertrain::Router]
      # @param url_resolver [Proc]
      # @return [Cybertrain::Application]
      def self.boot(router, url_resolver)
        problem = refusal
        raise ArgumentError, problem unless problem.empty?

        c = Cybertrain.config
        c.csrf = false unless c.csrf_given?
        path = c.database_path
        [path, "#{path}-wal", "#{path}-shm"].each { |f| File.delete(f) if File.exist?(f) }
        connection = Cybertrain::DB::Connection.new(path)
        migrator = Cybertrain::DB::Migrator.new(connection)
        migrator.quiet!
        migrator.migrate(Cybertrain::Migration.all)
        connection.close
        app = Cybertrain::Application.new(router: router, url_resolver: url_resolver)
        app.boot
        Cybertrain::Test.app = app
        @configured_zone = Cybertrain::Clock.zone
        unless @zone_hooked
          @zone_hooked = true
          Cybertrain::Test.on_reset(zone_reset)
        end
        app
      end

      # {boot}, or, when it refuses, the reason on STDOUT and exit status 2
      # (plan decision 19): what gen/tests.rb calls.
      # @return [nil]
      def self.boot!(router, url_resolver)
        problem = refusal
        unless problem.empty?
          puts problem
          exit(2)
        end
        boot(router, url_resolver)
        nil
      end

      # The zone {boot} found configured.
      # @return [Cybertrain::TimeZone]
      def self.configured_zone = @configured_zone

      # The reset hook that gives every test the configured zone back.
      def self.zone_reset
        -> {
          Cybertrain::Clock.zone = Cybertrain::Test::Bundle.configured_zone
          nil
        }
      end

      # Runs the tests argv keeps (Test::Args), file by file in path order:
      # a file's class-form tests through `dispatch` (gen's
      # Gen::Tests.run_case), its top-level-form tests through
      # Test.run_top_level_case. Prints the file's path before its first
      # test, `  ok   Class: name`, or `  FAIL Class: name (path:line)` /
      # `  ERR  ...` with each message line indented by nine spaces (the
      # top-level form without `Class: `), then an empty line and the
      # totals. Answers the exit status: 0, 1 when a test failed, 2 for bad
      # arguments (the usage and the reason are printed, nothing runs).
      # @param argv [Array<String>]
      # @param dispatch [Proc] takes the index of a class-form test
      # @return [Integer]
      def self.run!(argv, dispatch)
        args = Args.parse(argv, @files, Dir.pwd)
        unless args.arg_error.empty?
          say(Args::USAGE)
          say(args.arg_error)
          return 2
        end
        tests = 0
        failures = 0
        before = Cybertrain::Test.assertion_count
        cases = Cybertrain::Test.top_level_cases
        f = 0
        while f < @files.length
          file = @files[f]
          heading = false
          i = 0
          while i < @case_file.length
            if @case_file[i] == file && args.keep?(file, @case_name[i], @case_method[i])
              say(file) unless heading
              heading = true
              dispatch.call(i)
              tests += 1
              failures += 1 unless Cybertrain::Test.last_status == "ok"
              report("#{@case_class[i]}: #{@case_name[i]}", "#{file}:#{@case_line[i]}")
            end
            i += 1
          end
          k = 0
          while k < cases.length
            c = cases[k]
            if c.top_file.top_file_path == file && args.keep?(file, c.name, Args.method_for(c.name))
              say(file) unless heading
              heading = true
              Cybertrain::Test.run_top_level_case(c)
              tests += 1
              failures += 1 unless Cybertrain::Test.last_status == "ok"
              line = c.top_file.line_of(c.name)
              report(c.name, line > 0 ? "#{file}:#{line}" : file)
            end
            k += 1
          end
          f += 1
        end
        say("")
        say("#{counted(tests, "test")}, #{counted(Cybertrain::Test.assertion_count - before, "assertion")}, #{counted(failures, "failure")}")
        failures > 0 ? 1 : 0
      end

      # The lines of the test just run.
      def self.report(label, where)
        status = Cybertrain::Test.last_status
        if status == "ok"
          say("  ok   #{label}")
          return nil
        end
        say("  #{status.ljust(4)} #{label} (#{where})")
        Cybertrain::Test.last_message.split("\n").each { |line| say("         #{line}") }
        nil
      end

      # "1 test", "3 tests".
      def self.counted(n, word)
        n == 1 ? "1 #{word}" : "#{n} #{word}s"
      end

      def self.say(line)
        if @capturing
          @captured << line
        else
          puts line
        end
        nil
      end

      # From now on (`on` true) the runner's lines are kept for
      # {captured_output} instead of printed; false prints again.
      # @return [nil]
      def self.capture_output(on)
        @capturing = on
        @captured = Array.new(0) { "" } if on
        nil
      end

      # The lines kept since {capture_output}.
      # @return [Array<String>]
      def self.captured_output = @captured
    end
  end
end
