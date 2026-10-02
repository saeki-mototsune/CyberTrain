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
    def initialize(io)
      @io = io
      @mutex = Mutex.new
    end

    def event(name, **fields)
      line = +"play event=#{name}"
      fields.each { |key, value| line << " #{key}=#{format(value)}" }
      @mutex.synchronize do
        @io.puts(line)
        @io.flush
      end
    end

    private

    def format(value)
      text = value.to_s
      return text if text.match?(/\A[^\s"=\\]+\z/)

      "\"#{text.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }}\""
    end
  end
end

require_relative "play/config"
require_relative "play/subnets"
require_relative "play/templates"
require_relative "play/docker_cli"
require_relative "play/limits"
require_relative "play/probe"
