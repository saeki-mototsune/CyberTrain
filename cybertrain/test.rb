# Cybertrain::Test -- the framework's own minimal test harness.
#
# minitest and RSpec cannot run under Spinel (they discover test methods by
# reflection), so tests are plain programs: each test/*.rb file registers
# blocks with `test "name" do ... end` and finishes with `Cybertrain::Test.run!`.
# `spin test` compares the program's stdout against test/<name>.rb.expected,
# so every line printed here is deterministic (no timings, no addresses).
module Cybertrain
  # The test harness for applications (and the framework's own tests).
  # minitest and RSpec cannot run under Spinel, so a test file is a plain
  # program: it registers cases with the top-level `test "name" do ... end`,
  # asserts with the top-level `assert*` methods (see the
  # {file:docs/api/README.md overview}), and ends with
  # {Test.run! Cybertrain::Test.run!}. For requests, see {Test::Client}.
  #
  # `cybertrain spin test` compiles each `test/*.rb` (not `test/support/`)
  # into its own program and compares its output with `test/<name>.rb.expected`.
  # There is no setup/teardown and no isolation between cases: reset what
  # you need at the top of a case (e.g. `Article.all.delete_all`).
  # @example test/articles.rb
  #   require_relative "support/blog_test"   # boots the app as BLOG, see examples/blog
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

    class Case
      attr_reader :name, :block

      def initialize(name, block)
        @name = name
        @block = block
      end
    end

    @@cases = []
    @@failures = 0
    @@assertions = 0

    def self.register(name, block)
      @@cases << Case.new(name, block)
    end

    def self.count_assertion
      @@assertions += 1
    end

    # Runs every registered case in registration order, prints one line per
    # case plus a summary, and exits non-zero when anything failed.
    #
    # The lines are `ok   <name>`, `FAIL <name>: <message>` for a failed
    # assertion, `ERR  <name>: <Class>: <message>` for another exception,
    # then `<n> tests, <n> assertions, <n> failures`. Call it at the end of
    # every test file.
    # @return [void]
    # @api public
    def self.run!
      @@cases.each do |c|
        begin
          c.block.call
          puts "ok   #{c.name}"
        rescue AssertionFailed => e
          @@failures += 1
          puts "FAIL #{c.name}: #{e.message}"
        rescue StandardError => e
          @@failures += 1
          puts "ERR  #{c.name}: #{e.class.name}: #{e.message}"
        end
      end
      puts "#{@@cases.size} tests, #{@@assertions} assertions, #{@@failures} failures"
      exit(1) if @@failures > 0
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

# Passes when `expected == actual`; fails with `expected X, got Y`.
# @param expected [Object]
# @param actual [Object]
# @return [void]
# @api public
def assert_equal(expected, actual)
  Cybertrain::Test.count_assertion
  unless expected == actual
    flunk("expected #{expected.inspect}, got #{actual.inspect}")
  end
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

# Passes when the block raises. `class_name` (optional) must be a substring of
# the raised exception's class name; the raised message is returned so callers
# can assert on it. A failing assertion inside the block is not "the expected
# exception": AssertionFailed is a StandardError, so without its own clause
# (first, it is the more specific class) the rescue below would swallow it and
# the test would pass vacuously. It is re-raised so the enclosing test fails,
# unless the caller names it (`assert_raises("AssertionFailed") { ... }` is how
# the assertion helpers themselves are tested).
# @example
#   message = assert_raises("RecordNotFound") { Article.find(999) }
#   assert_includes message, "id=999"
# @param class_name [String] part of the expected exception's class name
#   (`"RecordNotFound"`); the class itself cannot be given
# @yield the code that must raise a StandardError
# @return [String] the exception's message
# @api public
def assert_raises(class_name = "")
  Cybertrain::Test.count_assertion
  message = ""
  raised = false
  begin
    yield
  rescue StandardError => e
    # One clause only (a second `=> e` of another type in this yielding
    # method is untested under Spinel, NOTES rule 32). `to_s`: Class#name is
    # nil for an anonymous class under CRuby (`Class.new(StandardError)`), and
    # a NoMethodError from inside this rescue clause would replace the very
    # exception being asserted on.
    name = e.class.name.to_s
    if name.include?("AssertionFailed") && !(class_name != "" && name.include?(class_name))
      raise e
    end
    raised = true
    message = e.message
    if class_name != "" && !name.include?(class_name)
      flunk("expected #{class_name} to be raised, got #{name}: #{e.message}")
    end
  end
  flunk("expected #{class_name == "" ? "an exception" : class_name} to be raised") unless raised
  message
end
