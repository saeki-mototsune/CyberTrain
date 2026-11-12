require "test_helper"

# The source of gen/probe_test.rb (TestScan.rewrite_in with ProbeBase as the
# one class-form base), which test/gen_test_rewrite.rb compiles and calls:
# every rewritten method answers nil whatever its body's last value, its
# rescue or ensure clause or a bare return (pre-flight ruling R8).
class ProbeTest < ProbeBase
  setup do
    PROBE_LOG << "setup"
    42
  ensure
    PROBE_LOG << "setup ensure"
  end

  teardown do
    PROBE_LOG << "teardown"
    "a string"
  end

  test "rescued" do
    raise "boom"
  rescue RuntimeError
    PROBE_LOG << "rescued"
    7
  end

  test "bare return" do
    return if PROBE_LOG.size >= 0

    PROBE_LOG << "not reached"
  end

  test "one line" do PROBE_LOG << "one line" end

  def test_written
    PROBE_LOG << "written"
    [1, 2]
  end
end

class ProbeOwnTest < ProbeBase
  def setup
    super
    PROBE_LOG << "own setup"
    :symbol
  ensure
    PROBE_LOG << "own ensure"
  end

  def teardown = PROBE_LOG << "own teardown"
end
