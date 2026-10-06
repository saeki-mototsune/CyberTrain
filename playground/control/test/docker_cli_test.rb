# frozen_string_literal: true

require_relative "test_helper"

# Play::DockerCLI without Docker: redaction, and #run on sh -c commands.
class DockerCLITest < Minitest::Test
  SID = "0123456789abcdef0123456789abcdef"
  PID = "fedcba9876543210fedcba9876543210"

  def cli
    Play::DockerCLI.new
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # What the block writes to $stderr, including what threads it started
  # write before they end (waits up to 2 s for them).
  def stderr_of
    before = Thread.list
    _, err = capture_io do
      yield
      deadline = monotonic + 2
      sleep 0.01 until (Thread.list - before).empty? || monotonic > deadline
    end
    err
  end

  def test_redact_names_each_secret_and_hides_other_32_digit_hex_numbers
    assert_equal "Conflict: ctplay-s-1f2e3d4c5b6a7980 has the aliases s-<sid> and p-<pid>",
                 Play::DockerCLI.redact("Conflict: ctplay-s-1f2e3d4c5b6a7980 has the aliases s-#{SID} and p-#{PID}",
                                        "sid" => SID, "pid" => PID)
    assert_equal "the alias s-<hex32> is taken", Play::DockerCLI.redact("the alias s-#{SID} is taken")
    assert_equal "container <hex32><hex32> is not running",
                 Play::DockerCLI.redact("container #{"0123456789abcdef" * 4} is not running")
  end

  def test_redact_gives_one_line_cut_after_redacting
    assert_equal "Error: one two", Play::DockerCLI.redact("Error:\n  one\r\n\ttwo\n")
    assert_equal "#{"x" * 190} <hex32>", Play::DockerCLI.redact("#{"x" * 190}\n#{SID}")
    assert_equal "y" * 200, Play::DockerCLI.redact("y" * 500)
    assert_equal "", Play::DockerCLI.redact(nil)
  end

  def test_redact_reads_odd_bytes_without_raising
    # Without LANG, Ruby reads docker's UTF-8 output as US-ASCII.
    assert_equal "café <hex32>", Play::DockerCLI.redact("caf\xC3\xA9 #{SID}".dup.force_encoding(Encoding::US_ASCII))
    assert_equal "bad � byte <hex32>", Play::DockerCLI.redact("bad \xFF byte #{SID}")
  end

  def test_run_gives_the_status_and_both_outputs
    result = cli.run(["sh", "-c", "printf out; printf err >&2; exit 3"], timeout: 5)
    assert_equal [3, "out", "err"], [result.status, result.stdout, result.stderr]
    refute_predicate result, :ok?
    assert_predicate cli.run(["sh", "-c", "exit 0"], timeout: 5), :ok?
  end

  def test_a_command_killed_by_a_signal_gives_128_plus_its_number
    assert_equal 143, cli.run(["sh", "-c", "kill -TERM $$"], timeout: 5).status
  end

  def test_a_hung_command_is_killed_at_its_deadline_quietly
    error = nil
    started = monotonic
    stderr = stderr_of do
      error = assert_raises(Play::DockerCLI::Timeout) do
        cli.run(["sh", "-c", "exec sleep 5", "s-#{SID}"], timeout: 0.2)
      end
    end
    assert_operator monotonic - started, :<, 1
    assert_equal "sh -c exec sleep 5 did not finish within 0.2 s", error.message
    assert_equal "", stderr
  end

  def test_the_readers_end_quietly_when_a_child_keeps_the_pipes_open
    stderr = stderr_of do
      assert_raises(Play::DockerCLI::Timeout) { cli.run(["sh", "-c", "sleep 1 & exec sleep 5"], timeout: 0.2) }
    end
    assert_equal "", stderr
  end
end
