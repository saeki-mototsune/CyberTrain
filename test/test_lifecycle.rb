# The top-level form's lifecycle (spec sections 5.3 and 5.4): the file's
# `setup` blocks in order and its `teardown` blocks in reverse around every
# case, after the reset hooks; the clock real again after each case.
# CRuby-runnable: it requires the harness alone.
require "cybertrain/test"
require "cybertrain/test/http_receiver"
require "cybertrain/test/test_case"

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

# The failure paths, each driven by hand through run_top_level_case inside
# a case (a failing case of this file would make run! exit 1): a file of
# its own with the setup and teardown blocks given, and a body.
STEPS = Array.new(0) { "" }
OUTER_RAN = Array.new(0) { "" }
RESET_RAISES = [false]
RECEIVERS = Array.new(0) { Cybertrain::Test::HttpReceiver.new }
Cybertrain::Test.on_reset(-> { raise "rz" if RESET_RAISES[0] })

def top_level_file(setups, teardowns)
  file = Cybertrain::Test::TopLevelFile.new("by_hand.rb")
  setups.each { |b| file.setup_blocks << b }
  teardowns.each { |b| file.teardown_blocks << b }
  file
end

def run_by_hand(file, body)
  Cybertrain::Test.run_top_level_case(Cybertrain::Test::Case.new("by hand", body, file))
  [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
end

test "a raising setup block skips the later blocks and the body; every teardown runs" do
  STEPS.clear
  file = top_level_file([-> { STEPS << "s1" }, -> { STEPS << "s2"; raise "boom" }, -> { STEPS << "s3" }],
                        [-> { STEPS << "t1" }, -> { STEPS << "t2" }])
  assert_equal ["ERR", "in setup: RuntimeError: boom"], run_by_hand(file, -> { STEPS << "body" })
  assert_equal %w[s1 s2 t2 t1], STEPS
end

test "a raising teardown block does not stop the others; each failure is reported" do
  STEPS.clear
  file = top_level_file([-> { STEPS << "s1" }],
                        [-> { STEPS << "t1" }, -> { STEPS << "t2"; raise "x" }, -> { STEPS << "t3"; flunk "td3" }])
  assert_equal ["ERR", "in teardown: td3\nin teardown: RuntimeError: x"], run_by_hand(file, -> { STEPS << "body" })
  assert_equal %w[s1 body t3 t2 t1], STEPS
end

test "a raising on_reset hook is an ERR in reset: setup and body skipped, teardown run" do
  STEPS.clear
  file = top_level_file([-> { STEPS << "s1" }], [-> { STEPS << "t1" }])
  RESET_RAISES[0] = true
  result = run_by_hand(file, -> { STEPS << "body" })
  RESET_RAISES[0] = false
  assert_equal ["ERR", "in reset: RuntimeError: rz"], result
  assert_equal %w[t1], STEPS
end

test "after_this_case callables run newest first, each on its own, after teardown" do
  STEPS.clear
  file = top_level_file([], [-> { STEPS << "teardown" }])
  body = lambda do
    Cybertrain::Test.after_this_case(-> { STEPS << "a" })
    Cybertrain::Test.after_this_case(-> { STEPS << "b"; raise "hb" })
    Cybertrain::Test.after_this_case(-> { STEPS << "c"; flunk "hc" })
    Cybertrain::Test.after_this_case(-> { STEPS << "d" })
  end
  assert_equal ["ERR", "after teardown: hc\nafter teardown: RuntimeError: hb"], run_by_hand(file, body)
  assert_equal %w[teardown d c b a], STEPS
end

test "travel and receivers are undone after a raising teardown" do
  file = top_level_file([], [-> { raise "td" }])
  body = lambda do
    freeze_time
    rx = Cybertrain::Test::HttpReceiver.new(accept_window: 30.0)
    RECEIVERS << rx
    rx.start
  end
  assert_equal ["ERR", "in teardown: RuntimeError: td"], run_by_hand(file, body)
  refute Cybertrain::Clock.travelling?
  refute RECEIVERS[0].serving?
end

# NotImplementedError, ScriptError and SystemStackError are not
# StandardErrors; Minitest records them as errors and goes on, and so does
# this runner (only Interrupt, SystemExit and NoMemoryError end the run).
# Each lambda does something before it raises (NOTES rule 79).
test "NotImplementedError, ScriptError and SystemStackError in a body are ERR; teardown still runs" do
  STEPS.clear
  file = top_level_file([], [-> { STEPS << "t" }])
  assert_equal ["ERR", "NotImplementedError: subclass must implement"],
               run_by_hand(file, -> { STEPS << "b1"; raise NotImplementedError, "subclass must implement" })
  assert_equal ["ERR", "ScriptError: no such file"], run_by_hand(file, -> { STEPS << "b2"; raise ScriptError, "no such file" })
  assert_equal ["ERR", "SystemStackError: stack level too deep"],
               run_by_hand(file, -> { STEPS << "b3"; raise SystemStackError, "stack level too deep" })
  assert_equal %w[b1 t b2 t b3 t], STEPS
end

test "the same three in setup, teardown and an on_reset hook are ERR with the step named" do
  STEPS.clear
  in_setup = top_level_file([-> { STEPS << "s"; raise NotImplementedError, "ns" }], [-> { STEPS << "t" }])
  assert_equal ["ERR", "in setup: NotImplementedError: ns"], run_by_hand(in_setup, -> { STEPS << "body" })
  in_teardown = top_level_file([], [-> { STEPS << "t2" }, -> { STEPS << "t1"; raise ScriptError, "st" }])
  assert_equal ["ERR", "in teardown: ScriptError: st"], run_by_hand(in_teardown, -> { STEPS << "body2" })
  after = top_level_file([], [])
  body = lambda do
    STEPS << "body3"
    Cybertrain::Test.after_this_case(-> { STEPS << "a"; raise SystemStackError, "deep" })
  end
  assert_equal ["ERR", "after teardown: SystemStackError: deep"], run_by_hand(after, body)
  assert_equal %w[s t body2 t1 t2 body3 a], STEPS
end

# 0: nothing raises; 1: setup raises; 2: setup and teardown raise.
CLASS_MODE = [0]

# A class-form test, driven the way gen/tests.rb's run_case arms drive one.
class LifecycleClassTest < ActiveSupport::TestCase
  def setup
    super
    STEPS << "setup"
    raise NotImplementedError, "setup not written" if CLASS_MODE[0] >= 1
  end

  def teardown
    STEPS << "teardown"
    raise SystemStackError, "teardown too deep" if CLASS_MODE[0] >= 2
  end

  def test_abstract
    STEPS << "body"
    raise NotImplementedError, "abstract"
  end
end

def run_class_case(t)
  if Cybertrain::Test.before_case(t)
    Cybertrain::Test.run_body(t) { t.test_abstract }
  end
  Cybertrain::Test.after_case(t)
  [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
end

test "a class-form test: the three are ERR in the body, setup and teardown; teardown runs" do
  STEPS.clear
  assert_equal ["ERR", "NotImplementedError: abstract"], run_class_case(LifecycleClassTest.new)
  CLASS_MODE[0] = 1
  assert_equal ["ERR", "in setup: NotImplementedError: setup not written"], run_class_case(LifecycleClassTest.new)
  CLASS_MODE[0] = 2
  result = run_class_case(LifecycleClassTest.new)
  CLASS_MODE[0] = 0
  assert_equal ["ERR", "in setup: NotImplementedError: setup not written\nin teardown: SystemStackError: teardown too deep"], result
  assert_equal %w[setup body teardown setup teardown setup teardown], STEPS
end

test "a case driven inside a case leaves the outer case's travel, hooks and in_case? alone" do
  travel_to Time.utc(2001, 9, 9)
  Cybertrain::Test.after_this_case(-> { OUTER_RAN << "outer" })
  file = top_level_file([], [])
  assert_equal ["ok", ""], run_by_hand(file, -> { freeze_time })
  assert Cybertrain::Test.in_case?
  assert_equal 999_993_600, Time.current.to_i
  assert_equal [], OUTER_RAN
end

test "the outer case's after_this_case callable ran at its own end" do
  assert_equal ["outer"], OUTER_RAN
  refute Cybertrain::Clock.travelling?
end

# The log scope (spec section 20: "resets ... the log tags"): a Scope a case
# swapped in and never swapped back is gone before the next case, as a
# travel is; a case driven inside a case gives the outer case its own back.
SCOPE_SEEN = Array.new(0) { "" }

def lifecycle_scope(id)
  tags = Array.new(0) { "" }
  tags << id
  context = { "" => "" }
  context.delete("")
  Cybertrain::Logger::Scope.new(id, "GET", "/", "", tags, 0, context)
end

test "a case that swaps in a log scope and never swaps it back" do
  Cybertrain::Logger.swap_scope(lifecycle_scope("leaked"))
  assert_equal "leaked", Cybertrain::Logger.current_scope.scope_request_id
end

test "the next case starts with no log scope" do
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
  assert_nil Thread.current[Cybertrain::Logger::SCOPE_KEY]
end

test "a case driven inside a case leaves the outer case's log scope alone and drops its own" do
  outer = lifecycle_scope("outer")
  Cybertrain::Logger.swap_scope(outer)
  file = top_level_file([], [])
  SCOPE_SEEN.clear
  body = lambda do
    SCOPE_SEEN << Cybertrain::Logger.current_scope.scope_request_id
    Cybertrain::Logger.swap_scope(lifecycle_scope("inner"))
    nil
  end
  assert_equal ["ok", ""], run_by_hand(file, body)
  assert_equal ["outer"], SCOPE_SEEN
  assert Cybertrain::Logger.current_scope.equal?(outer)
end

test "and the case after it starts with no log scope again" do
  assert Cybertrain::Logger.current_scope.equal?(Cybertrain::Logger::NO_SCOPE)
end

Cybertrain::Test.run!
