require "cybertrain"
require "cybertrain/test"

test "assert_equal passes on equal values" do
  assert_equal 1, 1
  assert_equal "a", "a"
  assert_equal [1, 2], [1, 2]
  assert_equal nil, nil
end

test "assert_includes on strings and arrays" do
  assert_includes "hello world", "world"
  assert_includes [1, 2, 3], 2
end

test "assert_raises returns the message and checks the class name" do
  msg = assert_raises("ArgumentError") { raise ArgumentError, "bad arg" }
  assert_equal "bad arg", msg
  assert_raises { raise "anything" }
end

# A failing assertion inside the block must not count as "the expected
# exception" (it used to: AssertionFailed is a StandardError, so every
# assert_raises { assert_equal ... } passed vacuously). The failure is observed
# with a plain begin/rescue because a FAIL line cannot live in this snapshot.
test "assert_raises lets a failing assertion in its block propagate" do
  failure = ""
  begin
    assert_raises { assert_equal 1, 2 }
  rescue Cybertrain::Test::AssertionFailed => e
    failure = e.message
  end
  assert_includes failure, "expected 1, got 2"

  failure = ""
  begin
    assert_raises("ArgumentError") { flunk("inner flunk") }
  rescue Cybertrain::Test::AssertionFailed => e
    failure = e.message
  end
  assert_equal "inner flunk", failure
end

# ... unless the caller names AssertionFailed, which is how the assertion
# helpers themselves are tested (test/client.rb).
test "assert_raises accepts AssertionFailed when it is named" do
  msg = assert_raises("AssertionFailed") { assert_equal 1, 2 }
  assert_equal "expected 1, got 2", msg
end

test "refute and assert_nil" do
  refute false
  assert_nil nil
end

Cybertrain::Test.run!
