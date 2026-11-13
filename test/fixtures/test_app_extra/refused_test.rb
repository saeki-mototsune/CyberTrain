# Copied to test/refused_test.rb by script/test-command-e2e: a class-form
# file the rewrite refuses (a test method that takes parameters). gen
# still succeeds; `cybertrain test` prints the place and exits 1.
require "test_helper"

class RefusedTest < ActiveSupport::TestCase
  def test_with_argument(name = "x")
    assert name
  end
end
