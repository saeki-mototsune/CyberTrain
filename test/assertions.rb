# The assertions of spec section 10 and Minitest's failure text: each one
# passing and failing once, the failure caught with
# `assert_raises("AssertionFailed") { ... }` and its message compared.
# CRuby-runnable: it requires the harness alone.
#
# Each block names its locals apart from every other block's (rule 63), and
# each failure is caught inline rather than through a yielding helper
# (rule 90, pre-flight N29).
require "cybertrain/test"

class NotFound < StandardError
end

class DeepNotFound < NotFound
end

test "assert_equal prints Expected and Actual on two lines" do
  assert_equal "Expected: 1\n  Actual: 0", assert_raises("AssertionFailed") { assert_equal 1, 0 }
  assert_equal "Expected: \"a\"\n  Actual: nil", assert_raises("AssertionFailed") { assert_equal "a", nil }
end

test "assert_in_delta" do
  assert_in_delta 0.1, 0.1004
  assert_in_delta 1, 1.5, 0.5
  assert_equal "Expected |0.1 - 0.2| (0.1) to be <= 0.001.", assert_raises("AssertionFailed") { assert_in_delta 0.1, 0.2 }
  assert_equal "Expected |1 - 3| (2) to be <= 0.001.", assert_raises("AssertionFailed") { assert_in_delta 1, 3 }
end

test "assert_match with a String and a Regexp" do
  assert_match "ell", "hello"
  assert_match(/h.l/, "hello")
  assert_no_match(/z/, "hello")
  assert_no_match "z", "hello"
  assert_equal "Expected /z/ to match \"hello\".", assert_raises("AssertionFailed") { assert_match(/z/, "hello") }
  assert_equal "Expected \"z\" to match \"hello\".", assert_raises("AssertionFailed") { assert_match "z", "hello" }
  assert_equal "Expected /h/ to not match \"hello\".", assert_raises("AssertionFailed") { assert_no_match(/h/, "hello") }
end

test "assert_not_equal, assert_not_nil, assert_not_includes, assert_empty, assert_not_empty" do
  assert_not_equal 1, 2
  assert_not_nil 0
  assert_not_includes [1, 2], 3
  assert_not_includes "hello", "z"
  assert_equal "Expected 1 to not be equal to 1.", assert_raises("AssertionFailed") { assert_not_equal 1, 1 }
  assert_equal "Expected nil to not be nil.", assert_raises("AssertionFailed") { assert_not_nil nil }
  assert_equal "Expected [1, 2] to not include 2.", assert_raises("AssertionFailed") { assert_not_includes [1, 2], 2 }
  assert_equal "Expected \"hello\" to not include \"ell\".", assert_raises("AssertionFailed") { assert_not_includes "hello", "ell" }
  assert_empty({})
  assert_empty ""
  assert_empty []
  assert_not_empty [1]
  assert_not_empty "a"
  assert_not_empty({ "k" => 1 })
  assert_equal "Expected [1] to be empty.", assert_raises("AssertionFailed") { assert_empty [1] }
  assert_equal "Expected \"\" to not be empty.", assert_raises("AssertionFailed") { assert_not_empty "" }
end

test "assert_not is refute" do
  assert_not false
  assert_not nil
  assert_equal "Expected 1 to be nil or false", assert_raises("AssertionFailed") { assert_not 1 }
end

test "assert_nothing_raised reports the class and message" do
  assert_nothing_raised { 1 + 1 }
  assert_equal "Expected nothing to be raised, got ArgumentError: bad",
               assert_raises("AssertionFailed") { assert_nothing_raised { raise ArgumentError, "bad" } }
  # A failed assertion inside the block is that assertion's failure.
  assert_equal "Expected: 1\n  Actual: 2", assert_raises("AssertionFailed") { assert_nothing_raised { assert_equal 1, 2 } }
end

test "assert_difference and assert_no_difference" do
  count = [0]
  assert_difference(-> { count[0] }, 2) { count[0] += 2 }
  assert_difference(-> { count[0] }) { count[0] += 1 }
  assert_no_difference(-> { count[0] }) { nil }
  assert_equal "Expected change of 1, got 0 (from 3 to 3)", assert_raises("AssertionFailed") { assert_difference(-> { count[0] }) { nil } }
  assert_equal "Expected change of 0, got 1 (from 3 to 4)",
               assert_raises("AssertionFailed") { assert_no_difference(-> { count[0] }) { count[0] += 1 } }
end

# Rails' order (pre-flight R14): the value before against from:, then
# "changed at all", then the value after against to:.
test "assert_changes" do
  title = ["a"]
  assert_changes(-> { title[0] }, from: "a", to: "b") { title[0] = "b" }
  assert_changes(-> { title[0] }) { title[0] = "c" }
  assert_changes(-> { title[0] }, to: nil) { title[0] = nil }
  assert_changes(-> { title[0] }, from: nil) { title[0] = "b" }
  assert_equal "Expected \"b\" to change", assert_raises("AssertionFailed") { assert_changes(-> { title[0] }) { nil } }
  assert_equal "Expected change to \"c\", got \"d\"",
               assert_raises("AssertionFailed") { assert_changes(-> { title[0] }, to: "c") { title[0] = "d" } }
  assert_equal "Expected change from \"x\", got \"d\"",
               assert_raises("AssertionFailed") { assert_changes(-> { title[0] }, from: "x", to: "e") { title[0] = "e" } }
  # from: is checked before "changed": the value did not change either.
  assert_equal "Expected change from \"x\", got \"e\"",
               assert_raises("AssertionFailed") { assert_changes(-> { title[0] }, from: "x") { nil } }
end

test "assert_raises with a class answers the message" do
  assert_equal "x", assert_raises(ArgumentError) { raise ArgumentError, "x" }
  assert_equal "z", assert_raises(Cybertrain::Test::AssertionFailed) { flunk "z" }
  # A subclass matches, as in Minitest: a user class, then Ruby's own.
  assert_equal "deep", assert_raises(NotFound) { raise DeepNotFound, "deep" }
  assert_equal "key not found: \"k\"", assert_raises(IndexError) { {}.fetch("k") }
  assert_equal "plain", assert_raises(StandardError) { raise "plain" }
end

test "assert_raises fails with Minitest's text" do
  assert_equal "[ArgumentError] exception expected, not\nClass: <RuntimeError>\nMessage: <\"y\">",
               assert_raises("AssertionFailed") { assert_raises(ArgumentError) { raise "y" } }
  assert_equal "[DeepNotFound] exception expected, not\nClass: <NotFound>\nMessage: <\"up\">",
               assert_raises("AssertionFailed") { assert_raises(DeepNotFound) { raise NotFound, "up" } }
  assert_equal "ArgumentError expected but nothing was raised.",
               assert_raises("AssertionFailed") { assert_raises(ArgumentError) { 1 } }
  assert_equal "[RecordNotFound] exception expected, not\nClass: <KeyError>\nMessage: <\"no\">",
               assert_raises("AssertionFailed") { assert_raises("RecordNotFound") { raise KeyError, "no" } }
  assert_equal "RecordNotFound expected but nothing was raised.",
               assert_raises("AssertionFailed") { assert_raises("RecordNotFound") { 2 } }
  assert_equal "StandardError expected but nothing was raised.", assert_raises("AssertionFailed") { assert_raises { 3 } }
end

test "assert_raises with an exception that is not a StandardError" do
  assert_equal "abstract", assert_raises(NotImplementedError) { raise NotImplementedError, "abstract" }
  assert_equal "sub", assert_raises(ScriptError) { raise NotImplementedError, "sub" }
  assert_equal "any", assert_raises(Exception) { raise "any" }
  # Not expected and not a StandardError: raised on untouched, as Minitest
  # lets SystemExit and Interrupt through.
  passed_through = ""
  begin
    assert_raises(ArgumentError) { raise NotImplementedError, "through" }
  rescue NotImplementedError => e
    passed_through = e.message
  end
  assert_equal "through", passed_through
  # With nothing expected only a StandardError matches (Minitest's default).
  assert_equal "x", assert_raises { raise "x" }
  bare_through = ""
  begin
    assert_raises { raise NotImplementedError, "bare" }
  rescue NotImplementedError => e
    bare_through = e.message
  end
  assert_equal "bare", bare_through
end

# Ruby's own namespaced classes answer no superclass under Spinel: their
# parents come from the table (Errno::* is a SystemCallError).
test "assert_raises with Ruby's namespaced exceptions" do
  assert_includes assert_raises(StandardError) { File.read("/nonexistent/assertions") }, "No such file"
  assert_includes assert_raises(SystemCallError) { File.read("/nonexistent/assertions") }, "No such file"
  assert_includes assert_raises(Errno::ENOENT) { File.read("/nonexistent/assertions") }, "No such file"
  assert_includes assert_raises(StandardError) { Math.sqrt(-1) }, "out of domain"
  assert_equal "[ArgumentError] exception expected, not\nClass: <Math::DomainError>\nMessage: <\"Numerical argument is out of domain - sqrt\">",
               assert_raises("AssertionFailed") { assert_raises(ArgumentError) { Math.sqrt(-1) } }
end

test "assert_raises(StandardError) lets a failed assertion in its block through" do
  assert_equal "Expected: 1\n  Actual: 2", assert_raises("AssertionFailed") { assert_raises(StandardError) { assert_equal 1, 2 } }
end

Cybertrain::Test.run!
