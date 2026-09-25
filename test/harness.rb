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

test "refute and assert_nil" do
  refute false
  assert_nil nil
end

Cybertrain::Test.run!
