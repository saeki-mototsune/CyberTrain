# Cybertrain::Test::Bundle -- the runner of `cybertrain test`'s program,
# gen/tests.rb (docs/design.md D83): its boot (a fresh, migrated test
# database and the application) and its run over every test of the
# application, filtered by the run-time arguments (Cybertrain::Test::Args),
# printed as docs/guide/testing.md's "Running the tests" shows: a heading
# per file, a line per test, then the totals.
#
# What depends on the adapter is the adapter's bundle entry's:
# Bundle.refusal (whether the configured database may be emptied, decided
# before anything is opened) and Bundle.fresh_database (the empty, marked,
# migrated test database), in cybertrain/test/bundle/sqlite.rb (SQLite: the
# file is deleted and created again; cybertrain/test/bundle requires it) and
# cybertrain/test/bundle/mysql.rb (MySQL: the database's tables are dropped;
# cybertrain/test/bundle_mysql requires it).
require "cybertrain/test"
require "cybertrain/test/args"
require "cybertrain/test/client"
require "cybertrain/test/database"

module Cybertrain
  module Test
    # gen/tests.rb boots with {boot!}, hands over its table of class-form
    # tests with {use_table} and ends with `exit(Bundle.run!(ARGV, dispatcher))`.
    # @api private
    module Bundle
      # What {boot} raises when it refuses the database (an ArgumentError,
      # as before): {boot!} prints it and exits 2.
      # @api private
      class Refused < ArgumentError
      end

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

      # The sender a test's mail has when the application gives none
      # (Rails' generated ApplicationMailer uses it too).
      DEFAULT_SENDER = "from@example.com".freeze

      # Where a test's uploads go when config/app.rb sets no
      # `upload_root`: emptied by every boot, never storage/uploads.
      TEST_UPLOADS = "tmp/test_uploads".freeze

      # Deletes what `dir` holds (files, symlinks and directories, the
      # latter emptied first; a symlink is removed, never followed), and
      # keeps `dir` itself. Nothing when it does not exist.
      # @param dir [String]
      # @return [nil]
      def self.empty_directory(dir)
        return nil unless File.directory?(dir) && !File.symlink?(dir)

        Dir.children(dir).each { |child| Bundle.remove_tree("#{dir}/#{child}") }
        nil
      end

      # Removes a file, a symlink, or a directory with what it holds.
      def self.remove_tree(path)
        if File.directory?(path) && !File.symlink?(path)
          Dir.children(path).each { |child| Bundle.remove_tree("#{path}/#{child}") }
          Dir.rmdir(path)
        else
          File.delete(path)
        end
        nil
      end

      # Hands over gen's table: the test files in path order, then one entry
      # per class-form test (its file, the line of its `test` call, its
      # class, name and method), entry i being the test that
      # Gen::Tests.run_case(i) runs (through Gen::Tests.case_<i>).
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

      # Boots the application on a new test database: refuses first
      # (Bundle.refusal, raising ArgumentError, nothing deleted), turns forgery
      # protection off unless config/app.rb set `csrf` (Rails' test
      # environment), keeps mail at delivery `:test` and `force_ssl` off
      # unless config/app.rb set them (whatever CYBERTRAIN_MAIL_DELIVERY_METHOD
      # and CYBERTRAIN_FORCE_SSL say), accepts the test host
      # (www.example.com) and leaves the host check off unless config/app.rb set
      # `hosts_from_env` (whatever CYBERTRAIN_HOSTS says), puts uploads in
      # {TEST_UPLOADS}, emptied here, unless config/app.rb set
      # `upload_root`, silences the request log unless config/app.rb set
      # `log_level` (its lines, with timings, would print between the test
      # lines; Rails writes them to log/test.log; error-level lines, which
      # carry no timings, still print), keeps text log lines unless
      # config/app.rb set `log_format` (whatever CYBERTRAIN_LOG_FORMAT says;
      # tests read captured log text), sends no error report unless
      # config/app.rb set `sentry_dsn` (whatever CYBERTRAIN_SENTRY_DSN says),
      # gives mail the sender
      # {DEFAULT_SENDER} unless CYBERTRAIN_SMTP_FROM or config/app.rb set
      # `smtp_from`, makes the test database afresh (Bundle.fresh_database:
      # on SQLite deletes the database and its -wal / -shm, creates it
      # marked with Database::TEST_MARKER (`PRAGMA application_id`); then
      # migrates Migration.all, quietly), boots, and sets {Cybertrain::Test.app}. Every test
      # then starts in the configured time zone (a reset hook).
      # @param router [Cybertrain::Router]
      # @param url_resolver [Proc]
      # @return [Cybertrain::Application]
      def self.boot(router, url_resolver)
        problem = Bundle.refusal
        raise Refused, problem unless problem.empty?

        c = Cybertrain.config
        c.csrf_unless_given(false)
        c.log_level_unless_given(:none)
        c.log_format_unless_given(:text)
        c.smtp_from_unless_given(DEFAULT_SENDER)
        c.mail_delivery_method_unless_given(:test)
        c.force_ssl_unless_given(false)
        c.sentry_dsn_unless_given("")
        c.hosts_from_env_unless_given(Array.new(0) { "" })
        c.allowed_hosts << Client::TEST_HOST unless c.allowed_hosts.any? { |h| h == Client::TEST_HOST }
        unless c.upload_root_given?
          c.upload_root_unless_given(TEST_UPLOADS)
          Bundle.empty_directory(TEST_UPLOADS)
        end
        Bundle.fresh_database
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

      # {boot}, or, when it refuses, the reason on STDOUT and exit status 2:
      # what gen/tests.rb calls.
      # @return [nil]
      def self.boot!(router, url_resolver)
        check_database!
        problem = Bundle.boot_problem(router, url_resolver)
        unless problem.empty?
          puts problem
          exit(2)
        end
        nil
      end

      # {boot}, answering "" or the refusal it raised ({Refused}); the
      # rescue in this plain method (NOTES rules 32/45).
      # @return [String]
      def self.boot_problem(router, url_resolver)
        boot(router, url_resolver)
        ""
      rescue Refused => e
        e.message
      end

      # When Bundle.refusal refuses the configured database: the reason on
      # STDOUT and exit status 2. gen/tests.rb calls it right after
      # config/app.rb, before any helper, support or test file is loaded.
      # @return [nil]
      def self.check_database!
        problem = Bundle.refusal
        unless problem.empty?
          puts problem
          exit(2)
        end
        nil
      end

      # When argv is not good for the table handed over ({use_table}): the
      # usage and the reason, exit status 2, before the boot.
      # @param argv [Array<String>]
      # @return [nil]
      def self.check_args!(argv)
        args = Args.parse(argv, @files, Dir.pwd)
        unless args.arg_error.empty?
          say(Args::USAGE)
          say(args.arg_error)
          exit(2)
        end
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
      # totals; when a filter kept no test, Args::NOTHING_MATCHED comes
      # before them. Answers the exit status: 0, 1 when a test failed, 2 for bad
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
              report_case("#{@case_class[i]}: #{@case_name[i]}", "#{file}:#{@case_line[i]}")
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
              line = c.top_file.line_for(c.name, same_name_before(cases, k))
              report_case(c.name, line > 0 ? "#{file}:#{line}" : file)
            end
            k += 1
          end
          f += 1
        end
        say(Args::NOTHING_MATCHED) if tests.zero? && args.filtered?
        say("")
        say("#{counted(tests, "test")}, #{counted(Cybertrain::Test.assertion_count - before, "assertion")}, #{counted(failures, "failure")}")
        failures > 0 ? 1 : 0
      end

      # How many cases before cases[k] in its file have its name: the n-th
      # of one name takes the n-th line gen recorded for it.
      def self.same_name_before(cases, k)
        c = cases[k]
        n = 0
        j = 0
        while j < k
          other = cases[j]
          n += 1 if other.name == c.name && other.top_file.top_file_path == c.top_file.top_file_path
          j += 1
        end
        n
      end

      # The lines of the test just run.
      def self.report_case(label, where)
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
