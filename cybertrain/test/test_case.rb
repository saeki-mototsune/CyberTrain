# Cybertrain::Test::Base and ActiveSupport::TestCase: the base classes of
# the class form (spec section 5.1).
#
# A class-form test file is rewritten by gen into gen/test/ (spec section
# 5.2): each `test "name" do` becomes `def test_name`, `setup do` blocks one
# `def setup` that calls `super` first, `teardown do` blocks one
# `def teardown` that calls `super` last, every method ending in `nil`
# (one return type per name, pre-flight R8). `cybertrain test` then runs
# each test on a new instance through Cybertrain::Test.before_case,
# run_body and after_case (cybertrain/test.rb owns the order). `setup` and
# `teardown` are ordinary overrides of the empty ones here, called through
# the base: no stored block meets a base-class receiver (rule 88).
#
# The class methods `test`, `setup` and `teardown` are reached only when a
# class-form file was compiled without the rewrite (`spin test` of it):
# they refuse with the way to run it (plan D9).
require "cybertrain/test"

module Cybertrain
  module Test
    # The base of every test class: empty `setup` and `teardown` for the
    # subclasses' overrides to call with `super`.
    # @api public
    class Base
      # What the class-level `test`, `setup` and `teardown` raise.
      NOT_REWRITTEN = "class-form tests run with `cybertrain test FILE`; `spin test` runs top-level-form files only"

      # Refused: a class-form file runs with `cybertrain test FILE`.
      # @raise [ArgumentError]
      def self.test(name)
        message = NOT_REWRITTEN
        raise ArgumentError, message
      end

      # Refused: a class-form file runs with `cybertrain test FILE`.
      # @raise [ArgumentError]
      # (Any arguments, so `setup :name` reaches this message too.)
      def self.setup(*names)
        message = NOT_REWRITTEN
        raise ArgumentError, message
      end

      # Refused: a class-form file runs with `cybertrain test FILE`.
      # @raise [ArgumentError]
      def self.teardown(*names)
        message = NOT_REWRITTEN
        raise ArgumentError, message
      end

      # What `test`, and `setup` / `teardown` given a block, raise when
      # reached inside a running test: a declaration gen's rewrite did not
      # turn into a method would otherwise reach the top-level `test` and
      # register a case the class form never runs.
      DECLARED_INSIDE = "a test, setup or teardown declaration was reached inside a running test (gen did not convert it); " \
                        "declare it directly in the class body"

      # Runs before each test; an override calls `super` first. Given a
      # block, it is a declaration that gen did not convert: refused.
      # @return [nil]
      # @raise [ArgumentError] when given a block
      # @api public
      def setup
        if block_given?
          message = DECLARED_INSIDE
          raise ArgumentError, message
        end
        nil
      end

      # Runs after each test, whatever happened in it; an override calls
      # `super` last. Given a block, it is a declaration that gen did not
      # convert: refused.
      # @return [nil]
      # @raise [ArgumentError] when given a block
      # @api public
      def teardown
        if block_given?
          message = DECLARED_INSIDE
          raise ArgumentError, message
        end
        nil
      end

      # A `test "name" do` reached inside a running test: refused (gen
      # converts every one it can place into a method).
      # @raise [ArgumentError]
      def test(name)
        message = DECLARED_INSIDE
        raise ArgumentError, message
      end
    end
  end
end

module ActiveSupport
  # Rails' base class for model, job, mailer and other tests: every
  # assertion, the time helpers and the fixture accessors.
  # @example test/models/article_test.rb
  #   require "test_helper"
  #
  #   class ArticleTest < ActiveSupport::TestCase
  #     test "title must be present" do
  #       refute Article.new(body: "a body long enough").save
  #     end
  #   end
  # @api public
  class TestCase < Cybertrain::Test::Base
    # `fixtures :all` is accepted and does nothing: every fixture is loaded
    # for every test. Any other set is refused.
    # @param name [Symbol] `:all`
    # @return [nil]
    # @raise [ArgumentError] for anything but `:all`
    # @api public
    def self.fixtures(name)
      unless name == :all
        message = "fixtures :all is the only form: every fixture is loaded for every test"
        raise ArgumentError, message
      end

      nil
    end
  end
end
