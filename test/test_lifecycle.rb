# The top-level form's lifecycle (spec sections 5.3 and 5.4): the file's
# `setup` blocks in order and its `teardown` blocks in reverse around every
# case, after the reset hooks; the clock real again after each case.
# CRuby-runnable: it requires the harness alone.
require "cybertrain/test"

# A constant, not a local (rule 64's sibling: the blocks must share it).
ORDER = Array.new(0) { "" }
setup    { ORDER << "setup1" }
setup    { ORDER << "setup2" }
teardown { ORDER << "teardown1" }
teardown { ORDER << "teardown2" }
Cybertrain::Test.on_reset(-> { ORDER << "reset" })

test "top-level setup and teardown wrap every case in order" do
  ORDER << "body"
end

test "a case that travels without a block" do
  ORDER << "body2"
  freeze_time
end

test "the order was reset, setup1, setup2, body, teardown2, teardown1 each time, and the clock is real" do
  assert_equal %w[reset setup1 setup2 body teardown2 teardown1 reset setup1 setup2 body2 teardown2 teardown1 reset setup1 setup2],
               ORDER
  refute Cybertrain::Clock.travelling?
end

test "in_case? is true inside a case" do
  assert Cybertrain::Test.in_case?
end

Cybertrain::Test.run!
