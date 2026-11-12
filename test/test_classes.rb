# The class form's lifecycle (spec sections 5.1 to 5.3, plan D3 and D9):
# hand-written classes in the shape gen's rewrite writes (every test
# method, setup and teardown ends in nil, pre-flight R8), driven by hand
# through Cybertrain::Test.before_case / run_body / after_case as
# gen/tests.rb's arms drive them. Requires cybertrain/test_help, so its
# reset hooks are registered and the program compiles everything an
# application's test helper loads.
require "cybertrain/test_help"
require "cybertrain/test/http_receiver"

LOG = Array.new(0) { "" }

class AppBase < ActiveSupport::TestCase
  def setup
    super
    LOG << "base setup"
    nil
  end

  def teardown
    LOG << "base teardown"
    super
    nil
  end
end

class ThingTest < AppBase
  def setup
    super
    @thing = "x"
    LOG << "setup"
    nil
  end

  def teardown
    LOG << "teardown"
    super
    nil
  end

  def test_uses_ivar
    LOG << "body #{@thing}"
    assert_equal "x", @thing
    nil
  end

  def thing = @thing.to_s

  def test_raises
    raise ArgumentError, "nope"
    nil
  end

  def test_tears_down_badly
    LOG << "body"
    nil
  end

  private def helper = "h"
end

test "setup and teardown order with an inherited base" do
  t = ThingTest.new
  Cybertrain::Test.run_body(t) { t.test_uses_ivar } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  assert_equal ["base setup", "setup", "body x", "teardown", "base teardown"], LOG
  assert_equal ["ok", ""], [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
end

test "teardown after an exception; each test gets a new instance" do
  LOG.clear
  t = ThingTest.new
  Cybertrain::Test.run_body(t) { t.test_raises } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  assert_equal ["base setup", "setup", "teardown", "base teardown"], LOG
  assert_equal "ERR", Cybertrain::Test.last_status
  assert_equal "ArgumentError: nope", Cybertrain::Test.last_message
  assert_equal "", ThingTest.new.thing # a new instance: setup has not run on it
end

class FailingSetupTest < ActiveSupport::TestCase
  def setup
    super
    freeze_time
    raise "setup failed"
    nil
  end

  def teardown
    LOG << "teardown ran"
    super
    nil
  end

  def test_never
    LOG << "never"
    nil
  end
end

test "a failing setup after freeze_time leaves the next test on real time" do
  LOG.clear
  failing = FailingSetupTest.new
  Cybertrain::Test.run_body(failing) { failing.test_never } if Cybertrain::Test.before_case(failing)
  Cybertrain::Test.after_case(failing)
  assert_equal ["teardown ran"], LOG
  assert_equal ["ERR", "in setup: RuntimeError: setup failed"], [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
  assert_equal "ERR  a case: in setup: RuntimeError: setup failed", Cybertrain::Test.result_line("a case")
  refute Cybertrain::Clock.travelling?
end

class TwiceFailingTest < ActiveSupport::TestCase
  def teardown
    raise "td"
    nil
  end

  def test_flunks
    flunk("body")
    nil
  end

  def test_passes
    assert true
    nil
  end
end

test "teardown runs after a failed assertion, and a teardown failure is reported after the body's" do
  twice = TwiceFailingTest.new
  Cybertrain::Test.run_body(twice) { twice.test_flunks } if Cybertrain::Test.before_case(twice)
  Cybertrain::Test.after_case(twice)
  assert_equal ["FAIL", "body\nin teardown: RuntimeError: td"], [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
  assert_equal "FAIL a case: body\nin teardown: RuntimeError: td", Cybertrain::Test.result_line("a case")
end

test "a teardown failure after a passing body is an ERR naming teardown" do
  passing = TwiceFailingTest.new
  Cybertrain::Test.run_body(passing) { passing.test_passes } if Cybertrain::Test.before_case(passing)
  Cybertrain::Test.after_case(passing)
  assert_equal ["ERR", "in teardown: RuntimeError: td"], [Cybertrain::Test.last_status, Cybertrain::Test.last_message]
end

test "fixtures accepts :all only" do
  assert_equal "fixtures :all is the only form: every fixture is loaded for every test",
               assert_raises("ArgumentError") { ActiveSupport::TestCase.fixtures(:articles) }
  assert_nil ActiveSupport::TestCase.fixtures(:all)
end

test "the class-level test, setup and teardown refuse an unrewritten class-form file" do
  refused = "class-form tests run with `cybertrain test FILE`; `spin test` runs top-level-form files only"
  assert_equal refused, assert_raises("ArgumentError") { ActiveSupport::TestCase.test("a name") }
  assert_equal refused, assert_raises("ArgumentError") { ActiveSupport::TestCase.setup }
  assert_equal refused, assert_raises("ArgumentError") { ThingTest.teardown }
end

test "test_help's reset hooks put the locale back before setup" do
  I18n.available_locales = [:en, :ja]
  I18n.locale = :ja
  assert_equal :ja, I18n.locale
  t = ThingTest.new
  Cybertrain::Test.run_body(t) { t.test_uses_ivar } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  assert_equal :en, I18n.locale
  I18n.available_locales = [:en]
end

OUTSIDE = Cybertrain::Test::HttpReceiver.new(accept_window: 30.0)
OUTSIDE.start # at the top of the file, outside any case

test "a receiver left running by a failing test is stopped; one started outside a case is not" do
  inside = Cybertrain::Test::HttpReceiver.new(accept_window: 30.0)
  t = ThingTest.new
  Cybertrain::Test.run_body(t) { inside.start; flunk "x" } if Cybertrain::Test.before_case(t)
  Cybertrain::Test.after_case(t)
  refute inside.serving?
  assert OUTSIDE.serving?
  OUTSIDE.stop
end

Cybertrain::Test.run!
