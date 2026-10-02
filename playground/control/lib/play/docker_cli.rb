# frozen_string_literal: true

require "open3"

module Play
  # The one place that runs `docker` (spec §5.4): an argv array straight to
  # the process (never a shell), a time limit after which the process is
  # killed, and redaction for anything that reaches the log (spec §5.11).
  class DockerCLI
    Result = Struct.new(:status, :stdout, :stderr) do
      def ok?
        status.zero?
      end
    end

    class Timeout < StandardError; end

    # TEXT for the log: each SECRETS value (name => value) becomes <name>,
    # any other 32-digit hex number <hex32>; whitespace runs collapse and the
    # result stops at 200 characters.
    def self.redact(text, secrets = {})
      out = text.to_s.dup
      secrets.each { |name, value| out = out.gsub(value, "<#{name}>") unless value.to_s.empty? }
      out = out.gsub(/\h{32}/, "<hex32>").gsub(/\s+/, " ").strip
      out[0, 200]
    end

    def run(argv, timeout:)
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait|
        stdin.close
        out = Thread.new { stdout.read }
        err = Thread.new { stderr.read }
        unless wait.join(timeout)
          begin
            Process.kill("KILL", wait.pid)
          rescue Errno::ESRCH
            nil
          end
          wait.join
          # Only the first words: the rest of an argv can hold a session id.
          raise Timeout, "#{argv.first(3).join(" ")} did not finish within #{timeout} s"
        end
        status = wait.value
        Result.new(status.exitstatus || (128 + status.termsig.to_i), out.value.to_s, err.value.to_s)
      end
    end
  end
end
