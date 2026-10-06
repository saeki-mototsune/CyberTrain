# frozen_string_literal: true

require_relative "test_helper"

class EventLogTest < Minitest::Test
  def logged
    io = StringIO.new
    yield Play::EventLog.new(io)
    io.string
  end

  def test_one_line_per_event_with_bare_and_quoted_values
    out = logged do |log|
      log.event(:session_created, handle: "1f2e3d4c5b6a7980", sessions: 2, reason: :ttl)
      log.event(:docker_failed, stderr: 'Error: "ctplay-n-1f2e3d4c5b6a7980" is in use \ retry', option: "a=b",
                                empty: "", none: nil)
      log.event(:reaper_tick)
    end
    assert_equal "play event=session_created handle=1f2e3d4c5b6a7980 sessions=2 reason=ttl\n" \
                 'play event=docker_failed stderr="Error: \"ctplay-n-1f2e3d4c5b6a7980\" is in use \\\\ retry" ' \
                 "option=\"a=b\" empty=\"\" none=\"\"\n" \
                 "play event=reaper_tick\n", out
  end

  def test_control_characters_are_escaped_so_that_an_event_stays_one_line
    out = logged do |log|
      log.event(:create_failed, error: "line one\nplay event=forged sid=x", color: "\e[31mred\e[0m",
                                rest: "a\tb\rc\0d\x7Fe\u0085f")
    end
    assert_equal ['play event=create_failed error="line one\nplay event=forged sid=x" ' \
                  'color="\u001b[31mred\u001b[0m" rest="a\tb\rc\u0000d\u007fe\u0085f"' "\n"], out.lines
  end
end
