# Cybertrain::Test -- the framework's own minimal test harness.
#
# minitest and RSpec cannot run under Spinel (they discover test methods by
# reflection), so tests are plain programs: each test/*.rb file registers
# blocks with `test "name" do ... end` and finishes with `Cybertrain::Test.run!`.
# `spin test` compares the program's stdout against test/<name>.rb.expected,
# so every line printed here is deterministic (no timings, no addresses).
#
# The order of one test (spec section 5.3, plan D3) is owned here and
# nowhere else: 1-2. the bundle's database steps (Test.before_each_bundled,
# `cybertrain test` only), 3. the Test.on_reset hooks, 4. setup, 5. the
# body (only if 1-4 raised nothing), 6. teardown, always, 7. travel_back and
# the Test.after_this_case callables (the receivers' stop). The class form
# runs them through Test.before_case / Test.run_body / Test.after_case, the
# top-level form through Test.run_top_level_case.
require "cybertrain/clock"
require "cybertrain/test/time_helpers"

module Cybertrain
  # The test harness for applications (and the framework's own tests).
  # minitest and RSpec cannot run under Spinel, so a test file is a plain
  # program: it registers cases with the top-level `test "name" do ... end`,
  # asserts with the top-level `assert*` methods (see the
  # {file:docs/api/README.md overview}), and ends with
  # {Test.run! Cybertrain::Test.run!}. For requests, see {Test::Client}.
  # An application's tests are usually the class form instead
  # (ActiveSupport::TestCase and its subclasses, run by `cybertrain test`;
  # docs/guide/testing.md); this is the top-level form.
  #
  # `cybertrain spin test` compiles each `test/*.rb` (not `test/support/`)
  # into its own program and compares its output with `test/<name>.rb.expected`.
  # Top-level `setup do ... end` and `teardown do ... end` run before and
  # after every case of the file; after each case the clock is real again
  # and every receiver the case started is stopped; before each case
  # nothing rendered or requested is left for `assert_select`, no log tags
  # are left on the thread (`Cybertrain.logger.tagged`), and the
  # {Test.on_reset} hooks run (with `cybertrain/test_help`: the default
  # locale, the rate-limit counters, `Mailer.deliveries` and the
  # broadcasts' starting point). The database is not reset under
  # `spin test`: clear what you need in `setup`
  # (e.g. `Article.all.delete_all`). In `cybertrain test` every table is
  # emptied and the fixtures loaded before each case, and the configured
  # time zone is restored.
  # @example test/article_title.rb
  #   require "test_helper"
  #
  #   setup do
  #     Article.all.delete_all
  #   end
  #
  #   test "title must be present" do
  #     article = Article.new(body: "a body long enough to pass length")
  #     refute article.save
  #     assert_includes article.errors.full_messages, "Title can't be blank"
  #   end
  #
  #   Cybertrain::Test.run!
  # @api public
  module Test
    # What a failed assertion raises; the case is reported as `FAIL`.
    # @api public
    class AssertionFailed < StandardError
    end

    # The top-level `setup` and `teardown` blocks of one top-level-form file
    # (under `spin test` the program is one file).
    class TopLevelFile
      attr_reader :top_file_path, :setup_blocks, :teardown_blocks, :case_names, :case_lines

      def initialize(path)
        @top_file_path = path
        @setup_blocks = Array.new(0) { -> { nil } }
        @teardown_blocks = Array.new(0) { -> { nil } }
        # In the bundle, gen's record of the file's `test "<literal>"`
        # calls and their lines (plan decision 10), from Test.begin_file.
        @case_names = Array.new(0) { "" }
        @case_lines = Array.new(0) { 0 }
      end

      # The line of the `nth` (from 0) `test` call whose literal is `name`;
      # 0 for a computed name (gen records no line for it).
      # @param name [String]
      # @param nth [Integer]
      # @return [Integer]
      def line_for(name, nth)
        seen = 0
        k = 0
        while k < @case_names.length
          if @case_names[k] == name
            return @case_lines[k] if seen == nth

            seen += 1
          end
          k += 1
        end
        0
      end
    end

    # A case registered with the top-level `test`, and the file whose
    # `setup` / `teardown` blocks wrap it.
    class Case
      attr_reader :name, :block, :top_file

      def initialize(name, block, top_file)
        @name = name
        @block = block
        @top_file = top_file
      end
    end

    # Module-level instance variables, not @@class_variables: Spinel
    # 2026.09.12 does not mark class variables for the garbage collector, so
    # a cases Array only a @@variable held was swept as soon as the program
    # allocated enough before run! (booting an app, running migrations), and
    # run! iterated over whatever reused its memory (spikes/NOTES.md rules
    # 18 and 64; test/harness_gc.rb). Seeded with the element type (rule 9).
    @top_file = TopLevelFile.new("")
    @cases = Array.new(0) { Case.new("", -> { nil }, TopLevelFile.new("")) }
    @failures = 0
    @assertions = 0
    # The hooks of the order (plan D3, D4): each takes no receiver and no
    # argument (rules 2 and 88) and is a lambda created in a method or
    # passed positionally (rule 82).
    @before_each = Array.new(0) { -> { nil } }
    @resets = Array.new(0) { -> { nil } }
    @after_this_case = Array.new(0) { -> { nil } }
    @in_case = false
    # Per running case, innermost last: where its after_this_case callables
    # start, and the travelled instant (microseconds, -1 for none) of the
    # case it is nested in.
    @case_marks = Array.new(0) { 0 }
    @travel_marks = Array.new(0) { 0 }
    # Per running case, innermost last: the log scope of the case it is
    # nested in (Logger::NO_SCOPE for an outermost case).
    @scope_marks = Array.new(0) { Cybertrain::Logger::NO_SCOPE }
    # The case just run: "ok", "FAIL" or "ERR", and its message.
    @status = ""
    @message = ""
    # Read by later features (pre-flight ruling R7): the application the
    # bundle booted, and the HTML the last request or render answered.
    @app = nil
    @last_html = ""
    # Whether this test has rendered or requested anything yet: each case
    # starts with nothing (Test.case_begin), so assert_select cannot read
    # the HTML an earlier test left.
    @last_html_given = false
    # Whether the last HTML is an integration response's body (not a
    # render_inline), and that response's Content-Type (assert_turbo_stream
    # checks its media type, as turbo-rails does).
    @last_html_response = false
    @last_content_type = ""
    # True inside `cybertrain test`'s program (Test.bundled!): run! at the
    # end of a top-level-form file then does nothing.
    @bundled = false

    # Marks this program as the bundle `cybertrain test` compiles (gen's
    # gen/tests.rb calls it before requiring the test files): {run!} then
    # does nothing, since the bundle's runner runs every test once.
    # @return [nil]
    # @api private
    def self.bundled!
      @bundled = true
      nil
    end

    # Whether {bundled!} was called.
    # @return [Boolean]
    # @api private
    def self.bundled? = @bundled

    # Sets the flag {bundled!} sets (the framework's own tests turn it off
    # again).
    # @param value [Boolean]
    # @api private
    def self.bundled=(value)
      @bundled = value
    end

    # In the bundle, before each test file is required: the cases, `setup`
    # and `teardown` blocks it registers belong to `path`, and gen's
    # `names` / `lines` give each literal test name its line (plan
    # decision 10).
    # @param path [String] "test/legacy.rb"
    # @param names [Array<String>]
    # @param lines [Array<Integer>]
    # @return [nil]
    # @api private
    def self.begin_file(path, names, lines)
      file = TopLevelFile.new(path)
      names.each { |n| file.case_names << n }
      lines.each { |n| file.case_lines << n }
      @top_file = file
      nil
    end

    # The cases registered with the top-level `test`, in registration
    # order (each knows its file: {begin_file}).
    # @return [Array<Cybertrain::Test::Case>]
    # @api private
    def self.top_level_cases = @cases

    # The assertions counted so far in this program.
    # @return [Integer]
    # @api private
    def self.assertion_count = @assertions

    def self.register(name, block)
      @cases << Case.new(name, block, @top_file)
      nil
    end

    def self.add_setup(block)
      @top_file.setup_blocks << block
      nil
    end

    def self.add_teardown(block)
      @top_file.teardown_blocks << block
      nil
    end

    def self.count_assertion
      @assertions += 1
    end

    # Registers a hook run before every test's setup (step 3 of the order:
    # `Mailer.deliveries`, the rate-limit counters, `I18n.locale`), in
    # registration order. `cybertrain/test_help` registers the framework's.
    # @param callable [Proc] a lambda taking no argument
    # @return [nil]
    # @api public
    def self.on_reset(callable)
      @resets << callable
      nil
    end

    # Registers a callable run once, after the current test's teardown
    # (step 7), then forgotten; such callables run newest first. A
    # receiver's `start` registers its `stop` here.
    # @param callable [Proc] a lambda taking no argument
    # @return [nil]
    # @api public
    def self.after_this_case(callable)
      @after_this_case << callable
      nil
    end

    # Whether a test is running, from its first reset to its last cleanup:
    # what a receiver asks before registering its `stop`.
    # @return [Boolean]
    # @api public
    def self.in_case?
      @in_case
    end

    # Registers the bundle's database steps (1 and 2 of the order: the
    # clear and the fixtures), run first for every test; a failure is
    # reported as `in fixtures: ...`. Only `cybertrain test`'s program
    # registers them.
    # @param callable [Proc] a lambda taking no argument
    # @return [nil]
    # @api private
    def self.before_each_bundled(callable)
      @before_each << callable
      nil
    end

    # The application `cybertrain test` booted (nil under `spin test`).
    # @return [Cybertrain::Application, nil]
    # @api private
    def self.app = @app

    def self.app=(app)
      @app = app
    end

    # The HTML the last integration request or `render_inline` of the
    # running test answered, which `assert_select` reads; "" before the
    # first (see {last_html?}).
    # @return [String]
    # @api private
    def self.last_html = @last_html

    def self.last_html=(html)
      @last_html_given = true
      @last_html_response = false
      @last_content_type = ""
      @last_html = html
    end

    # Keeps a response's body as the last HTML, with its Content-Type:
    # what an integration request records (`last_html=` is a render's).
    # @param body [String]
    # @param content_type [String] "" when the response has none
    # @return [nil]
    # @api private
    def self.record_last_response(body, content_type)
      Cybertrain::Test.last_html = body
      @last_html_response = true
      @last_content_type = content_type
      nil
    end

    # Whether the last HTML came from a response (true) or from
    # `render_inline` (false).
    # @return [Boolean]
    # @api private
    def self.last_html_response?
      @last_html_response
    end

    # The Content-Type of the response kept as the last HTML; "" for a
    # render, or a response without one.
    # @return [String]
    # @api private
    def self.last_content_type = @last_content_type

    # Whether the running test has made a request or a `render_inline`
    # yet: false at the start of every test, so "nothing rendered" is never
    # read as an empty page (or as the previous test's).
    # @return [Boolean]
    # @api private
    def self.last_html?
      @last_html_given
    end

    # Forgets the last HTML: the start of every test (step 3).
    # @return [nil]
    # @api private
    def self.clear_last_html
      @last_html_given = false
      @last_html_response = false
      @last_content_type = ""
      @last_html = ""
      nil
    end

    # The status of the case just run: `"ok"`, `"FAIL"` or `"ERR"`.
    # @return [String]
    # @api public
    def self.last_status = @status

    # The message of the case just run: "" when it passed; for a failure
    # outside the body, the step first (`in setup: RuntimeError: boom`); a
    # failing teardown adds `in teardown: ...` on a line of its own after
    # the body's message.
    # @return [String]
    # @api public
    def self.last_message = @message

    # Steps 1-4 of the order for a class-form test: the bundle's database
    # steps, the resets, then `t.setup` (which calls `super` first). False
    # when one of them raised: the case is then `ERR` with the step named
    # and its body must not run. Records only; the runners print.
    # @example what `cybertrain test` runs for each test
    #   t = ArticleTest.new
    #   if Cybertrain::Test.before_case(t)
    #     Cybertrain::Test.run_body(t) { t.test_title_must_be_present }
    #   end
    #   Cybertrain::Test.after_case(t)
    # @param t [Cybertrain::Test::Base]
    # @return [Boolean]
    # @api public
    def self.before_case(t)
      return false unless case_begin

      t.setup
      true
    rescue AssertionFailed => e
      step_failed("in setup", e.message)
      false
    rescue StandardError => e
      step_failed("in setup", "#{e.class.name}: #{e.message}")
      false
    rescue NotImplementedError, SystemStackError, ScriptError => e
      step_failed("in setup", "#{e.class.name}: #{e.message}")
      false
    end

    # Step 5: runs the body and records `ok`, `FAIL` (a failed assertion,
    # its message) or `ERR` (another exception, `<Class>: <message>`).
    # A StandardError, NotImplementedError, any other ScriptError and
    # SystemStackError are recorded and the run goes on (teardown, the next
    # test, the totals), as Minitest records every exception but
    # NoMemoryError, SignalException (Interrupt) and SystemExit; those three
    # are left to end the program. The second arm is Job::Executor's
    # (`rescue NotImplementedError, SystemStackError, ScriptError`): a
    # `rescue Exception` would catch Interrupt and SystemExit too. Under
    # Spinel a stack overflow is a SIGSEGV of the process, so only a
    # SystemStackError raised by hand reaches the arm there.
    # @param t [Cybertrain::Test::Base, Cybertrain::Test::Case] the test
    #   instance, or the top-level case; not used
    # @yield the test method
    # @return [nil]
    # @api public
    def self.run_body(t)
      begin
        yield
        @status = "ok"
      rescue AssertionFailed => e
        @status = "FAIL"
        text = e.message
        @message = text
      rescue StandardError => e
        @status = "ERR"
        text = "#{e.class.name}: #{e.message}"
        @message = text
      rescue NotImplementedError, SystemStackError, ScriptError => e
        @status = "ERR"
        text = "#{e.class.name}: #{e.message}"
        @message = text
      end
      nil
    end

    # Steps 6-7: `t.teardown`, always (a failure is reported after the
    # body's, on a line of its own), then, in this plain method's `ensure`,
    # travel_back and every {after_this_case} callable.
    # @param t [Cybertrain::Test::Base]
    # @return [nil]
    # @api public
    def self.after_case(t)
      t.teardown
      nil
    rescue AssertionFailed => e
      step_failed("in teardown", e.message)
      nil
    rescue StandardError => e
      step_failed("in teardown", "#{e.class.name}: #{e.message}")
      nil
    rescue NotImplementedError, SystemStackError, ScriptError => e
      step_failed("in teardown", "#{e.class.name}: #{e.message}")
      nil
    ensure
      case_cleanup
    end

    # Steps 1-7 for a case registered with the top-level `test`: the
    # bundle's steps and the resets, the file's `setup` blocks in order, the
    # body, the file's `teardown` blocks in reverse, then travel_back and
    # the receivers. Records {last_status} and {last_message}; prints
    # nothing (`run!` and the bundle's runner do).
    # @param c [Cybertrain::Test::Case]
    # @return [nil]
    # @api private
    def self.run_top_level_case(c)
      if top_level_setup(c.top_file)
        run_body(c) { c.block.call }
      end
      top_level_teardown(c.top_file)
    end

    def self.top_level_setup(file)
      case_begin && run_case_hooks(file.setup_blocks, "in setup")
    end

    # Every teardown block runs, newest first, each on its own: one that
    # raises is reported and the others still run (step 6 is "always").
    def self.top_level_teardown(file)
      list = file.teardown_blocks
      i = list.length - 1
      while i >= 0
        run_case_hook(list[i], "in teardown")
        i -= 1
      end
      nil
    ensure
      case_cleanup
    end

    # Steps 1-3; false when a hook raised (the case is ERR, the step named).
    # A case begun inside a running case (driven by hand, as the
    # framework's own tests do) records where the outer case stands, so
    # its cleanup gives the outer case back its travel, its after_this_case
    # callables and in_case?.
    def self.case_begin
      @status = ""
      @message = ""
      @case_marks << @after_this_case.length
      @travel_marks << (@in_case && Cybertrain::Clock.travelling? ? Cybertrain::Clock.travelled_micros : -1)
      # The log tags (spec section 20): each test starts with no log scope;
      # a case driven inside a running one keeps the outer case's.
      @scope_marks << (@in_case ? Cybertrain::Logger.current_scope : Cybertrain::Logger::NO_SCOPE)
      Cybertrain::Logger.reset_scope unless @in_case
      # Each test starts with nothing rendered; a case driven by hand inside
      # a running one leaves the outer case's HTML alone.
      clear_last_html unless @in_case
      @in_case = true
      run_case_hooks(@before_each, "in fixtures") && run_case_hooks(@resets, "in reset")
    end

    # Runs the hooks in order and stops at the first that raises (false).
    def self.run_case_hooks(list, step)
      i = 0
      while i < list.length
        return false unless run_case_hook(list[i], step)

        i += 1
      end
      true
    end

    # Runs one hook or block; a failure is recorded under `step` (an
    # assertion's message as it is, another exception with its class; the
    # same exceptions as {run_body}'s are caught).
    def self.run_case_hook(callable, step)
      callable.call
      true
    rescue AssertionFailed => e
      step_failed(step, e.message)
      false
    rescue StandardError => e
      step_failed(step, "#{e.class.name}: #{e.message}")
      false
    rescue NotImplementedError, SystemStackError, ScriptError => e
      step_failed(step, "#{e.class.name}: #{e.message}")
      false
    end

    # Step 7: a travel without a block lasts to the end of its case,
    # whatever happened (spec section 2.1), so the clock is real again,
    # and the log scope is the outer case's (none for an outermost case);
    # then each after_this_case callable the case registered, newest first
    # and each on its own (one that raises does not stop the others); then
    # they are forgotten. A case nested in another hands the outer one back
    # its travel and its own callables.
    def self.case_cleanup
      Cybertrain::Clock.travel_back
      # A Scope the case swapped in and never swapped back is dropped: the
      # slot becomes the outer case's Scope, or empty (NO_SCOPE is stored
      # as nil) for an outermost case.
      outer_scope = @scope_marks.empty? ? Cybertrain::Logger::NO_SCOPE : @scope_marks.pop
      Cybertrain::Logger.swap_scope(outer_scope)
      from = @case_marks.empty? ? 0 : @case_marks.pop
      outer_micros = @travel_marks.empty? ? -1 : @travel_marks.pop
      list = @after_this_case
      i = list.length - 1
      while i >= from
        run_case_hook(list[i], "after teardown")
        i -= 1
      end
      list.pop while list.length > from
      Cybertrain::Clock.travel_to(Time.at(outer_micros / 1_000_000).utc) if outer_micros >= 0
      @in_case = !@case_marks.empty?
      nil
    end

    # A step outside the body failed: the case is ERR unless the body
    # already failed, and the step's line follows the body's message.
    def self.step_failed(step, text)
      line = "#{step}: #{text}"
      if @status == "" || @status == "ok"
        @status = "ERR"
        @message = line
      else
        joined = "#{@message}\n#{line}"
        @message = joined
      end
      nil
    end

    # The line `run!` prints for the case just run: `ok   <name>`,
    # `FAIL <name>: <message>` or `ERR  <name>: <message>`; a message of
    # several lines continues on the lines that follow.
    # @param name [String]
    # @return [String]
    # @api private
    def self.result_line(name)
      return "ok   #{name}" if @status == "ok"

      "#{@status.ljust(4)} #{name}: #{@message}"
    end

    # Runs every registered case in registration order, prints one line per
    # case plus a summary, and exits non-zero when anything failed.
    #
    # Each case runs as {run_top_level_case} does: the resets, the file's
    # `setup` blocks, the body, its `teardown` blocks, then travel_back and
    # the receivers' stop. The lines are `ok   <name>`,
    # `FAIL <name>: <message>` for a failed assertion,
    # `ERR  <name>: <Class>: <message>` for another exception
    # (`ERR  <name>: in setup: <Class>: <message>` outside the body), then
    # `<n> tests, <n> assertions, <n> failures`. Call it at the end of
    # every test file. Inside `cybertrain test`'s program ({bundled?}) it
    # does nothing: the bundle runs every test once, at its end. The cases
    # of a file the bundle began ({begin_file}) are the bundle's, not run!'s.
    # @return [void]
    # @api public
    def self.run!
      return nil if @bundled

      @cases.each do |c|
        next unless c.top_file.top_file_path.empty?

        run_top_level_case(c)
        @failures += 1 unless @status == "ok"
        puts result_line(c.name)
      end
      run = 0
      @cases.each { |c| run += 1 if c.top_file.top_file_path.empty? }
      puts "#{run} tests, #{@assertions} assertions, #{@failures} failures"
      exit(1) if @failures > 0
    end
  end
end

# Registers a test case, run in order by {Cybertrain::Test.run!}.
# @example
#   test "POST /articles creates an article" do
#     ...
#   end
# @param name [String]
# @return [void]
# @api public
def test(name, &block)
  Cybertrain::Test.register(name, block)
end

# Registers a block run before every case of this file, after the reset
# hooks; several run in the order written. In a test class (the class
# form) `setup do` becomes the class's `def setup` instead.
# @example
#   setup do
#     Cybertrain.config.http_allow_private = true
#   end
# @return [nil]
# @api public
def setup(&block)
  Cybertrain::Test.add_setup(block)
end

# Registers a block run after every case of this file, whatever happened
# in it; several run in the reverse of the order written.
# @example
#   teardown do
#     Cybertrain.config.http_allow_private = false
#   end
# @return [nil]
# @api public
def teardown(&block)
  Cybertrain::Test.add_teardown(block)
end

# Fails the current case.
# @param message [String]
# @return [void]
# @raise [Cybertrain::Test::AssertionFailed]
# @api public
def flunk(message)
  raise Cybertrain::Test::AssertionFailed, message
end

# Passes when the condition is truthy.
# @param condition [Object]
# @param message [String] the failure message
# @return [void]
# @api public
def assert(condition, message = "expected condition to be truthy")
  Cybertrain::Test.count_assertion
  flunk(message) unless condition
end

# Passes when the condition is false or nil.
# @param condition [Object]
# @param message [String] the failure message
# @return [void]
# @api public
def refute(condition, message = "expected condition to be falsy")
  Cybertrain::Test.count_assertion
  flunk(message) if condition
end

# Passes when `expected == actual`; fails with Minitest's text, the two
# values' `inspect` on two lines (`Expected: 1` / `  Actual: 0`).
# @param expected [Object]
# @param actual [Object]
# @return [void]
# @api public
def assert_equal(expected, actual)
  Cybertrain::Test.check_equal(expected, actual)
end

# Passes when `actual` is nil.
# @param actual [Object]
# @return [void]
# @api public
def assert_nil(actual)
  Cybertrain::Test.count_assertion
  flunk("expected nil, got #{actual.inspect}") unless actual.nil?
end

# Passes when a String contains `needle.to_s` or an Array includes
# `needle`. Any other haystack (a Hash) fails.
#
# `include?` on a polymorphic receiver mis-dispatches under Spinel 2026.09.12
# when the argument is also polymorphic (and String#include? does so as soon
# as SafeString is in the program), so the receiver is narrowed first and the
# String case goes through #index.
# @example
#   assert_includes article.errors.full_messages, "Title can't be blank"
#   assert_includes client.response.body, "Hello Rails"
# @param haystack [String, Array]
# @param needle [Object]
# @return [void]
# @api public
def assert_includes(haystack, needle)
  Cybertrain::Test.count_assertion
  found = false
  case haystack
  when String
    n = needle.to_s
    found = !haystack.index(n).nil?
  when Array
    found = haystack.include?(needle)
  end
  unless found
    flunk("expected #{haystack.inspect} to include #{needle.inspect}")
  end
end

# Passes when the block raises the exception `expected` names, and answers
# that exception's **message**, a String. A Class matches that class or a
# subclass, as Minitest's does (`assert_raises(ArgumentError)`,
# `assert_raises(NotImplementedError)`, `assert_raises(Cybertrain::DB::Error)`);
# a String matches a class whose name contains it (`"RecordNotFound"`);
# nothing given matches any StandardError. The failures are Minitest's:
# `[ArgumentError] exception expected, not` with the raised class and
# message on the next two lines, or `ArgumentError expected but nothing was
# raised.`
#
# Unlike Rails (Minitest answers the exception), the answer is already the
# message: where Rails writes `error = assert_raises(X) { ... }` and then
# `error.message`, write `message = assert_raises(X) { ... }` and use
# `message` itself.
#
# An exception that is not a StandardError (`SystemExit`, `Interrupt`,
# `NoMemoryError`, ...) and is not the one expected is raised on untouched.
# A failed assertion inside the block is not "the expected exception":
# AssertionFailed is a StandardError, so it is raised on (the test fails
# with that assertion's message) unless `expected` names AssertionFailed,
# which is how the assertion helpers themselves are tested
# (`assert_raises("AssertionFailed") { ... }`).
#
# Ruby's own exception classes answer no `superclass` under Spinel, so a
# subclass is recognised above them from a table of their parents (the
# Errno family, JSON's, Encoding's, URI's and the core classes); a
# built-in class outside it fails with its name, asking for the
# exact class or the name form (`assert_raises("Name")`).
# @example
#   message = assert_raises(Cybertrain::RecordNotFound) { Article.find(999) }
#   assert_includes message, "id=999"
# @param expected [Class, String] the exception's class, or part of its name
# @yield the code that must raise
# @return [String] the exception's message (not the exception)
# @api public
def assert_raises(expected = "")
  Cybertrain::Test.count_assertion
  message = ""
  raised = false
  begin
    yield
  rescue Exception => e
    # Exception, so NotImplementedError and other non-StandardErrors can be
    # expected; the helper raises on what was not. One clause only (a
    # second `=> e` of another type in this yielding method is untested
    # under Spinel, NOTES rule 32); the class is told
    # apart by name in the helper, which reads `name.to_s` (Class#name is
    # nil for an anonymous class under CRuby, and a NoMethodError from
    # here would replace the exception being asserted on).
    Cybertrain::Test.raise_unless_expected(expected, e)
    raised = true
    message = e.message
  end
  Cybertrain::Test.check_raised(expected, raised)
  message
end

require "cybertrain/test/assertions"
