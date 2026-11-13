require "test_helper"

# Copied to test/failing_test.rb by script/test-command-e2e: a failing
# assertion and an exception, each reported with its test's line, exit 1.
class FailingTest < ApplicationTest
  test "counts the articles" do
    write_article("One")
    assert_equal 2, Article.count
  end

  test "raises" do
    raise ArgumentError, "boom"
  end

  test "still passes" do
    assert_equal 1, User.count
  end
end
