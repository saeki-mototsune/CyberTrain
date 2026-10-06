# frozen_string_literal: true

# The hosted playground's control plane (spec
# docs/superpowers/specs/2026-10-02-web-playground-sp2-design.md, §5): the
# entry page, session creation, limits, the reaper and the stop switch.
# config.ru wires the pieces; bin/playctl reuses them for the operator.
module Play
  # Wall clock (Unix seconds), monotonic clock and sleep, in one object so
  # that tests can replace all three (test/fakes.rb, FakeClock).
  class Clock
    def now
      Time.now.to_i
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sleep(seconds)
      Kernel.sleep(seconds)
    end
  end

  # One event per line: `play event=<name> key=value ...` (spec §5.11).
  # Callers pass only handles, counts, reasons and redacted Docker output:
  # never a session id, a preview id, a session host name or an IP address.
  class EventLog
    # How a quoted value writes the quote, the backslash and the commonest
    # control characters; any other control character becomes \u followed by
    # four hex digits (JSON's escapes).
    ESCAPES = { '"' => '\\"', "\\" => "\\\\", "\b" => "\\b", "\t" => "\\t", "\n" => "\\n", "\f" => "\\f",
                "\r" => "\\r" }.freeze

    def initialize(io)
      @io = io
      @mutex = Mutex.new
    end

    def event(name, **fields)
      line = +"play event=#{name}"
      fields.each { |key, value| line << " #{key}=#{render_value(value)}" }
      @mutex.synchronize do
        @io.puts(line)
        @io.flush
      end
    end

    private

    # VALUE as it appears in the line: bare when it is one plain word, else
    # in double quotes with the quote, the backslash and every control
    # character (C0, DEL and C1, newlines among them) escaped, so that an
    # event is always exactly one line.
    def render_value(value)
      text = value.to_s
      return text if text.match?(/\A[^ "=\\[:cntrl:]]+\z/)

      "\"#{text.gsub(/[\\"[:cntrl:]]/) { |char| ESCAPES[char] || format("\\u%04x", char.ord) }}\""
    end
  end
end

require_relative "play/config"
require_relative "play/subnets"
require_relative "play/templates"
require_relative "play/docker_cli"
require_relative "play/limits"
require_relative "play/probe"
require_relative "play/sessions"
require_relative "play/ctl"
require_relative "play/guard"
