require "stringio"
require "cybertrain/config"
require "cybertrain/background"
require "cybertrain/test"

# Cybertrain::Background: a service registered from outside
# application.rb (as cybertrain/websocket.rb will register itself) is
# started by start_all and stopped by stop_all through the base class's
# methods, start_all honours Config#worker, and a name is registered once.
# Application#serve calls start_all/stop_all next to Scheduler's.

B = Cybertrain::Background

# What the probe did, read back by the tests (a constant: NOTES rule 64).
CALLS = Array.new(0) { "" }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# A subclass held in the registry typed by the base class: the calls
# dispatch to its methods.
class ProbeService < Cybertrain::Background::Service
  def service_name
    "probe"
  end

  def service_start(config)
    CALLS << "start"
    true
  end

  def service_stop
    CALLS << "stop"
    nil
  end
end

# A second subclass, which would refuse to start: its problem is what
# Application#serve fails the boot with.
class MisconfiguredService < Cybertrain::Background::Service
  def service_name
    "misconfigured"
  end

  def service_problem
    "misconfigured has no handler"
  end
end

# Registered at top level, as a required file does.
B.register(ProbeService.new)
B.register(MisconfiguredService.new)

test "start_all starts every registered service" do
  assert_equal 1, B.start_all(Cybertrain::Config.new)
  assert_equal ["start"], CALLS
end

test "stop_all stops them" do
  B.stop_all
  assert_equal "stop", CALLS[CALLS.size - 1]
end

test "start_all does nothing when the worker is off" do
  config = Cybertrain::Config.new
  config.worker = false
  before = CALLS.size
  assert_equal 0, B.start_all(config)
  assert_equal before, CALLS.size
end

test "boot_problem names the first service that would refuse to start" do
  assert_equal "misconfigured has no handler", B.boot_problem(Cybertrain::Config.new)
end

test "boot_problem is empty when the worker is off" do
  config = Cybertrain::Config.new
  config.worker = false
  assert_equal "", B.boot_problem(config)
end

test "a name registered twice is refused" do
  assert_includes assert_raises("ArgumentError") { B.register(ProbeService.new) }, "already registered"
end

Cybertrain::Test.run!
