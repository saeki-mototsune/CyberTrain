

# The source of gen/probe_test.rb (TestScan.rewrite_in with ProbeBase as the
# one class-form base), which test/gen_test_rewrite.rb compiles and calls:
# every rewritten method answers nil whatever its body's last value, its
# rescue or ensure clause or a bare return (pre-flight ruling R8).
class ProbeTest < ProbeBase; def setup; super; setup_probe_test_1; nil; end; def teardown; teardown_probe_test_1; super; nil; end
  def setup_probe_test_1; begin
    PROBE_LOG << "setup"
    42
  ensure
    PROBE_LOG << "setup ensure"
  end; nil; end

  def teardown_probe_test_1; begin
    PROBE_LOG << "teardown"
    "a string"
  end; nil; end

  def test_rescued; begin
    raise "boom"
  rescue RuntimeError
    PROBE_LOG << "rescued"
    7
  end; nil; end

  def test_bare_return; begin
    return if PROBE_LOG.size >= 0

    PROBE_LOG << "not reached"
  end; nil; end

  def test_one_line; begin; PROBE_LOG << "one line"; end; nil; end

  def test_written; begin
    PROBE_LOG << "written"
    [1, 2]
  end; nil; end
end

class ProbeOwnTest < ProbeBase
  def setup; begin
    super
    PROBE_LOG << "own setup"
    :symbol
  ensure
    PROBE_LOG << "own ensure"
  end; nil; end

  def teardown; begin; PROBE_LOG << "own teardown"; end; nil; end
end
