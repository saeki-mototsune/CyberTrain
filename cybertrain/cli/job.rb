# `cybertrain generate job send_digest --retry Cybertrain::Mailer::TimeoutError:60:5`:
# writes app/jobs/send_digest_job.rb (a Cybertrain::Job::Base subclass with
# an empty `perform(args)` and a `retry_on` line per --retry) and
# test/send_digest_job.rb, which runs it through `perform_now`. A name may
# carry a namespace ("admin/report" -> Admin::ReportJob in
# app/jobs/admin/report_job.rb). `spin run gen` then writes the class's
# perform_later / perform_at / perform_in / perform_now into gen/jobs.rb.
require "cybertrain/generator/inflector"
require "cybertrain/cli/templates"
require "cybertrain/cli/scaffold"
require "cybertrain/cli/helper"

module Cybertrain
  module CLI
    module Job
      USAGE = "usage: cybertrain generate job NAME [--retry Klass:wait:attempts ...] [--force]"

      # The value of each `--retry` in argv after `generate job`.
      def self.retry_specs(args)
        specs = Array.new(0) { "" }
        i = 0
        while i < args.size
          if args[i] == "--retry"
            raise InvalidArgument, USAGE if i + 1 >= args.size

            specs << args[i + 1]
            i += 1
          end
          i += 1
        end
        specs
      end

      # argv after `generate job` without `--force` and the `--retry`
      # options; any other option raises InvalidArgument.
      def self.positional(args)
        out = Array.new(0) { "" }
        i = 0
        while i < args.size
          arg = args[i]
          if arg == "--retry"
            i += 1
          elsif arg.start_with?("-") && arg != "--force"
            raise InvalidArgument, USAGE
          elsif arg != "--force"
            out << arg
          end
          i += 1
        end
        out
      end

      # Returns the paths written. retries: "Klass:wait:attempts" each.
      def self.generate(root, name, retries, force = false)
        GeneratedFiles.require_app!(root)

        # Underscored first, so "SendDigestJob" and "send_digest_job" are
        # both send_digest_job.rb.
        segments = GeneratedFiles.name_segments(name, "job")
        stem = segments.last.delete_suffix("_job")
        raise InvalidArgument, "bad job name '#{name}'" if stem.empty?

        segments[segments.size - 1] = "#{stem}_job"
        modules = segments.map { |s| Inflector.camelize(s) }
        full = modules.join("::")
        rel = segments.join("/")
        lines = Array.new(0) { "" }
        retries.each { |spec| lines << retry_line(spec) }
        files = [
          ["app/jobs/#{rel}.rb", class_source(modules, lines)],
          ["test/#{segments.join("_")}.rb", test_source(full, rel)]
        ]
        GeneratedFiles.write_all(root, files, force)
      end

      # "Cybertrain::Mailer::TimeoutError:60:5" -> the retry_on line; the
      # wait is seconds or polynomially_longer, the attempts 1 or more.
      def self.retry_line(spec)
        bad = "bad --retry '#{spec}': use Klass:wait:attempts (wait in seconds or polynomially_longer, attempts 1 or more)"
        parts = spec.split(":", -1)
        raise InvalidArgument, bad if parts.size < 3

        attempts = parts[parts.size - 1].to_s
        wait = parts[parts.size - 2].to_s
        klass = parts[0, parts.size - 2].join(":")
        raise InvalidArgument, bad unless constant_path?(klass)
        raise InvalidArgument, bad unless digits?(attempts) && attempts.to_i >= 1

        if wait == "polynomially_longer"
          "retry_on #{klass}, wait: :polynomially_longer, attempts: #{attempts.to_i}"
        elsif digits?(wait)
          "retry_on #{klass}, wait: #{wait.to_i}, attempts: #{attempts.to_i}"
        else
          raise InvalidArgument, bad
        end
      end

      def self.digits?(text)
        return false if text.empty?

        text.each_char { |ch| return false unless ch >= "0" && ch <= "9" }
        true
      end

      # "Net::TimeoutError": segments of a capital letter and word characters.
      def self.constant_path?(text)
        return false if text.empty?

        text.split("::", -1).each do |seg|
          return false if seg.empty? || !(seg[0] >= "A" && seg[0] <= "Z")

          seg.each_char do |ch|
            return false unless (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
          end
        end
        true
      end

      def self.class_source(modules, retry_lines)
        name = modules.join("::")
        body = +""
        body << "class #{modules.last} < Cybertrain::Job::Base\n"
        retry_lines.each { |line| body << "  #{line}\n" }
        body << "\n" unless retry_lines.empty?
        body << "  # #{name}.perform_later(\"id\" => record.id) queues it; a worker runs\n"
        body << "  # perform with that Hash read back from JSON, so narrow its values with\n"
        body << "  # Cybertrain::Cast.int / Cast.str. Declare policies above, one line each\n"
        body << "  # with literal values: retry_on Klass, wait: 60, attempts: 5 /\n"
        body << "  # discard_on Klass / limits_concurrency to: 1, key: \"id\". `spin run gen`\n"
        body << "  # writes perform_later, perform_at, perform_in and perform_now (gen/jobs.rb).\n"
        body << "  def perform(args)\n"
        body << "    nil\n"
        body << "  end\n"
        body << "end\n"
        GeneratedFiles.nest(modules[0, modules.size - 1], body)
      end

      def self.test_source(full, rel)
        out = GeneratedFiles.test_head("")
        out << "\n"
        out << "# app/jobs/#{rel}.rb, run on this thread (perform_now: no queue, no retry).\n"
        out << "test \"#{full} runs\" do\n"
        out << "  assert_equal \"#{full}\", #{full}.job_kind\n"
        out << "  assert_nil #{full}.perform_now({ \"id\" => 1 })\n"
        out << "end\n"
        out << "\n"
        out << "Cybertrain::Test.run!\n"
        out
      end
    end
  end
end
