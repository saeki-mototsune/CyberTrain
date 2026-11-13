# The assertions of spec section 10 beyond the first few, and the checks
# behind every assertion, with Minitest's (or Rails') failure text.
# Required by cybertrain/test at its end; it reopens Cybertrain::Test.
#
# The pattern every assertion follows (pre-flight R17): the check and its
# message live in one module function, `Cybertrain::Test.check_<name>`,
# which counts the assertion, compares, builds the message into a local
# (rule 58) and raises AssertionFailed through {Cybertrain::Test.fail_with};
# it answers nil. The top-level `assert_<name>` (and, where a test class
# shadows the name, its instance method) only gathers the values and calls
# it. A block assertion computes the before value, yields into a local or
# as a statement (rule 90, never `f(yield)`), computes the after value, then
# calls its check; none uses `ensure`. An expression is a lambda passed
# positionally (rule 42).

module Cybertrain
  module Test
    # What `from:` and `to:` of `assert_changes` hold when they are not
    # given (`to: nil` is an expectation). Not for tests to pass.
    UNSET = "\u0000unset"

    # Ruby's own exception classes answer no `superclass` under Spinel
    # ("undefined method 'superclass' for module RuntimeError"; phase 5a
    # spike item 4, spikes/phase5/assert_raises.rb), so above the first
    # builtin the chain `assert_raises` walks is read from their parents
    # (checked against CRuby 3.3's `superclass`); every `Errno::` class's
    # parent is SystemCallError (see {builtin_parent}).
    BUILTIN_PARENTS = {
      "Exception" => "", "StandardError" => "Exception", "ScriptError" => "Exception",
      "NoMemoryError" => "Exception", "SecurityError" => "Exception", "SignalException" => "Exception",
      "SystemExit" => "Exception", "SystemStackError" => "Exception", "Interrupt" => "SignalException",
      "LoadError" => "ScriptError", "NotImplementedError" => "ScriptError", "SyntaxError" => "ScriptError",
      "ArgumentError" => "StandardError", "EncodingError" => "StandardError", "FiberError" => "StandardError",
      "IOError" => "StandardError", "IndexError" => "StandardError", "LocalJumpError" => "StandardError",
      "NameError" => "StandardError", "RangeError" => "StandardError", "RegexpError" => "StandardError",
      "RuntimeError" => "StandardError", "SystemCallError" => "StandardError", "ThreadError" => "StandardError",
      "TypeError" => "StandardError", "ZeroDivisionError" => "StandardError", "EOFError" => "IOError",
      "KeyError" => "IndexError", "StopIteration" => "IndexError", "ClosedQueueError" => "StopIteration",
      "NoMethodError" => "NameError", "FloatDomainError" => "RangeError", "FrozenError" => "RuntimeError",
      "UncaughtThrowError" => "ArgumentError", "NoMatchingPatternError" => "StandardError",
      "NoMatchingPatternKeyError" => "NoMatchingPatternError", "Math::DomainError" => "StandardError",
      "Timeout::Error" => "RuntimeError", "Timeout::ExitException" => "Exception", "SocketError" => "StandardError",
      "Date::Error" => "ArgumentError", "JSON::JSONError" => "StandardError", "JSON::ParserError" => "JSON::JSONError",
      "JSON::NestingError" => "JSON::ParserError", "JSON::GeneratorError" => "JSON::JSONError",
      "Encoding::CompatibilityError" => "EncodingError", "Encoding::UndefinedConversionError" => "EncodingError",
      "Encoding::InvalidByteSequenceError" => "EncodingError", "Encoding::ConverterNotFoundError" => "EncodingError",
      "URI::Error" => "StandardError", "URI::InvalidURIError" => "URI::Error",
      "URI::InvalidComponentError" => "URI::Error", "URI::BadURIError" => "URI::Error",
      "IO::EAGAINWaitReadable" => "Errno::EAGAIN", "IO::EAGAINWaitWritable" => "Errno::EAGAIN",
      "IO::TimeoutError" => "IOError", "Regexp::TimeoutError" => "RegexpError"
    }.freeze

    # Fails the current assertion with `text`.
    # @param text [String]
    # @raise [AssertionFailed]
    def self.fail_with(text)
      raise AssertionFailed, text
    end

    # `assert_equal`: Minitest's two lines.
    def self.check_equal(expected, actual)
      count_assertion
      return nil if expected == actual

      text = "Expected: #{expected.inspect}\n  Actual: #{actual.inspect}"
      fail_with(text)
      nil
    end

    # `assert_not_equal`: Minitest's refute_equal.
    def self.check_not_equal(expected, actual)
      count_assertion
      return nil unless expected == actual

      text = "Expected #{actual.inspect} to not be equal to #{expected.inspect}."
      fail_with(text)
      nil
    end

    # `assert_in_delta`: Minitest's text, the difference an Integer when
    # both values are.
    def self.check_in_delta(expected, actual, delta)
      count_assertion
      diff = (expected.to_f - actual.to_f).abs
      return nil if diff <= delta.to_f

      shown = expected.is_a?(Integer) && actual.is_a?(Integer) ? diff.to_i.to_s : diff.to_s
      text = "Expected |#{expected} - #{actual}| (#{shown}) to be <= #{delta}."
      fail_with(text)
      nil
    end

    # Whether `string` matches: a Regexp is matched, a String is a
    # substring.
    def self.matcher_matches?(matcher, string)
      s = string.to_s
      case matcher
      when Regexp then s.match?(matcher)
      else !s.index(matcher.to_s).nil?
      end
    end

    # `assert_match` (want true) and `assert_no_match` (want false).
    def self.check_match(matcher, string, want)
      count_assertion
      return nil if matcher_matches?(matcher, string) == want

      text = want ? "Expected #{matcher.inspect} to match #{string.inspect}." : "Expected #{matcher.inspect} to not match #{string.inspect}."
      fail_with(text)
      nil
    end

    # `assert_not_nil`.
    def self.check_not_nil(object)
      count_assertion
      return nil unless object.nil?

      text = "Expected #{object.inspect} to not be nil."
      fail_with(text)
      nil
    end

    # `assert_not`: Rails' text.
    def self.check_not(object)
      count_assertion
      return nil unless object

      text = "Expected #{object.inspect} to be nil or false"
      fail_with(text)
      nil
    end

    # `assert_not_includes`: a String contains `object.to_s`, an Array
    # includes it (narrowed first, as `assert_includes`); anything else
    # includes nothing.
    def self.check_not_includes(collection, object)
      count_assertion
      found = false
      case collection
      when String
        n = object.to_s
        found = !collection.index(n).nil?
      when Array
        found = collection.include?(object)
      end
      return nil unless found

      text = "Expected #{collection.inspect} to not include #{object.inspect}."
      fail_with(text)
      nil
    end

    # Whether a String, Array or Hash is empty; anything else is not.
    def self.empty_value?(object)
      case object
      when String then object.empty?
      when Array then object.empty?
      when Hash then object.empty?
      else false
      end
    end

    # `assert_empty` (want true) and `assert_not_empty` (want false).
    def self.check_empty(object, want)
      count_assertion
      return nil if empty_value?(object) == want

      text = want ? "Expected #{object.inspect} to be empty." : "Expected #{object.inspect} to not be empty."
      fail_with(text)
      nil
    end

    # `assert_nothing_raised`, given what its block raised.
    def self.check_nothing_raised(exception)
      count_assertion
      name = exception.class.name.to_s
      raise exception if name.include?("AssertionFailed")

      text = "Expected nothing to be raised, got #{name}: #{exception.message}"
      fail_with(text)
      nil
    end

    # `assert_nothing_raised` when its block raised nothing.
    def self.count_nothing_raised
      count_assertion
      nil
    end

    # `assert_difference` and `assert_no_difference` (difference 0).
    def self.check_difference(before, after, difference)
      count_assertion
      actual = after - before
      return nil if actual == difference

      text = "Expected change of #{difference}, got #{actual} (from #{before} to #{after})"
      fail_with(text)
      nil
    end

    # `assert_changes`, in Rails' order: the value before against `from`,
    # then whether it changed, then the value after against `to`.
    def self.check_changes(before, after, from, to)
      count_assertion
      unless from == UNSET || from == before
        text = "Expected change from #{from.inspect}, got #{before.inspect}"
        fail_with(text)
      end
      if before == after
        text = "Expected #{before.inspect} to change"
        fail_with(text)
      end
      return nil if to == UNSET || to == after

      text = "Expected change to #{to.inspect}, got #{after.inspect}"
      fail_with(text)
      nil
    end

    # The name `assert_raises` prints for what it expects: the class's
    # name, the text given, or StandardError when nothing was.
    def self.expected_text(expected)
      case expected
      when String then expected == "" ? "StandardError" : expected
      else expected.name.to_s
      end
    end

    # Whether the raised class `raised` is what `expected` names: a Class
    # by name along the superclass chain (rules 46, 47), a String as part
    # of the name, "" any StandardError (`standard`: the exception is one,
    # Minitest's default). A built-in class whose parent is unknown fails
    # the assertion when it is a StandardError, and does not match (so it
    # is raised on) when it is not.
    def self.raised_matches?(expected, raised, standard)
      if expected.is_a?(String)
        return standard if expected == ""

        return raised.name.to_s.include?(expected)
      end
      want = expected.name.to_s
      k = raised
      name = k.name.to_s
      builtin = false
      loop do
        return true if name == want

        parent = builtin_parent(name)
        if parent.nil? && !builtin
          up = superclass_or_nil(k)
          if up.nil?
            return false unless standard

            text = "assert_raises: the parent class of #{name} is not known under Spinel; " \
                   "expect #{name} itself, or compare by name: assert_raises(\"#{want}\")"
            fail_with(text)
          end
          k = up
          name = k.name.to_s
        else
          builtin = true
          return false if parent.nil? || parent == ""

          name = parent
        end
      end
      false
    end

    # The parent of one of Ruby's own exception classes, by name: the
    # table's, SystemCallError for every `Errno::` class, else nil.
    def self.builtin_parent(name)
      parent = BUILTIN_PARENTS[name]
      return parent unless parent.nil?
      return "SystemCallError" if name.start_with?("Errno::")

      nil
    end

    # A user class's superclass; nil for a class of Ruby's own, which
    # answers none under Spinel (a NoMethodError there).
    def self.superclass_or_nil(klass)
      klass.superclass
    rescue StandardError
      nil
    end

    # `assert_raises`, given what its block raised: a failed assertion the
    # caller did not name is raised on, and so is an unexpected exception
    # that is not a StandardError (`SystemExit`, `Interrupt`, as Minitest
    # lets them through); another class than expected fails with
    # Minitest's text.
    def self.raise_unless_expected(expected, exception)
      name = exception.class.name.to_s
      if name.include?("AssertionFailed") && !expected_text(expected).include?("AssertionFailed")
        raise exception
      end
      return nil if raised_matches?(expected, exception.class, exception.is_a?(StandardError))
      raise exception unless exception.is_a?(StandardError)

      text = "[#{expected_text(expected)}] exception expected, not\nClass: <#{name}>\nMessage: <#{exception.message.inspect}>"
      fail_with(text)
      nil
    end

    # `assert_raises` after its block: Minitest's text when nothing was
    # raised.
    def self.check_raised(expected, raised)
      return nil if raised

      text = "#{expected_text(expected)} expected but nothing was raised."
      fail_with(text)
      nil
    end
  end
end

# Passes when `actual` is within `delta` of `expected` (Minitest's default
# delta, 0.001).
# @example
#   assert_in_delta 0.3, 0.1 + 0.2
# @param expected [Numeric]
# @param actual [Numeric]
# @param delta [Numeric]
# @return [nil]
# @api public
def assert_in_delta(expected, actual, delta = 0.001)
  Cybertrain::Test.check_in_delta(expected, actual, delta)
end

# Passes when `string` matches: a Regexp is matched, a String is looked
# for as a substring.
# @example
#   assert_match(/\A\d+\z/, response.body)
# @param matcher [Regexp, String]
# @param string [String]
# @return [nil]
# @api public
def assert_match(matcher, string)
  Cybertrain::Test.check_match(matcher, string, true)
end

# Passes when `string` does not match (see {assert_match}).
# @param matcher [Regexp, String]
# @param string [String]
# @return [nil]
# @api public
def assert_no_match(matcher, string)
  Cybertrain::Test.check_match(matcher, string, false)
end

# Passes when `expected != actual`.
# @param expected [Object]
# @param actual [Object]
# @return [nil]
# @api public
def assert_not_equal(expected, actual)
  Cybertrain::Test.check_not_equal(expected, actual)
end

# Passes when `object` is not nil.
# @param object [Object]
# @return [nil]
# @api public
def assert_not_nil(object)
  Cybertrain::Test.check_not_nil(object)
end

# Passes when a String does not contain `object.to_s`, or an Array does
# not include `object` (the opposite of `assert_includes`).
# @param collection [String, Array]
# @param object [Object]
# @return [nil]
# @api public
def assert_not_includes(collection, object)
  Cybertrain::Test.check_not_includes(collection, object)
end

# Passes when a String, Array or Hash is empty.
# @param object [String, Array, Hash]
# @return [nil]
# @api public
def assert_empty(object)
  Cybertrain::Test.check_empty(object, true)
end

# Passes when a String, Array or Hash is not empty.
# @param object [String, Array, Hash]
# @return [nil]
# @api public
def assert_not_empty(object)
  Cybertrain::Test.check_empty(object, false)
end

# Passes when `object` is false or nil (Rails' name for `refute`).
# @param object [Object]
# @return [nil]
# @api public
def assert_not(object)
  Cybertrain::Test.check_not(object)
end

# Passes when the block raises nothing; otherwise fails naming the
# exception's class and message. A failed assertion in the block fails
# with its own message.
# @example
#   assert_nothing_raised { Article.find(article.id) }
# @yield the code that must not raise
# @return [nil] not the block's value, as in Rails: one return type per
#   method name (spikes/NOTES.md rules 10, 34)
# @api public
def assert_nothing_raised
  begin
    yield
    Cybertrain::Test.count_nothing_raised
  rescue StandardError => e
    Cybertrain::Test.check_nothing_raised(e)
  end
  nil
end

# Passes when the block changes the value of `expression` by
# `difference`. The expression is a lambda, passed positionally (Rails'
# String expression needs `eval`).
# @example
#   assert_difference(-> { Article.count }, 1) do
#     post "/articles", params: { article: { title: "x" } }
#   end
# @param expression [Proc] a lambda answering an Integer
# @param difference [Integer]
# @yield the code that makes the change
# @return [nil] not the block's value, as in Rails: one return type per
#   method name (spikes/NOTES.md rules 10, 34)
# @api public
def assert_difference(expression, difference = 1)
  before = expression.call
  yield
  after = expression.call
  Cybertrain::Test.check_difference(before, after, difference)
end

# Passes when the block leaves the value of `expression` unchanged.
# @param expression [Proc] a lambda answering an Integer
# @yield the code that must not change it
# @return [nil] not the block's value, as in Rails: one return type per
#   method name (spikes/NOTES.md rules 10, 34)
# @api public
def assert_no_difference(expression)
  before = expression.call
  yield
  after = expression.call
  Cybertrain::Test.check_difference(before, after, 0)
end

# Passes when the block changes the value of `expression` (compared with
# `==`), from `from:` and to `to:` when they are given (`to: nil` is an
# expectation). Checked in Rails' order: `from:`, then the change, then
# `to:`.
# @example
#   assert_changes(-> { article.reload.title }, from: "a", to: "b") do
#     patch article_path(article), params: { article: { title: "b" } }
#   end
# @param expression [Proc] a lambda
# @param from [Object] the value before
# @param to [Object] the value after
# @yield the code that makes the change
# @return [nil] not the block's value, as in Rails: one return type per
#   method name (spikes/NOTES.md rules 10, 34)
# @api public
def assert_changes(expression, from: Cybertrain::Test::UNSET, to: Cybertrain::Test::UNSET)
  before = expression.call
  yield
  after = expression.call
  Cybertrain::Test.check_changes(before, after, from, to)
end
