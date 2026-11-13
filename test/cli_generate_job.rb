require "tmpdir"
require "cybertrain/cli"
require "cybertrain/generator/job_scan"
require "cybertrain/generator/jobs_emitter"
require "cybertrain/test"

# `cybertrain generate job`: a Job::Base subclass under app/jobs, with a
# retry_on line per --retry, and a test that runs it through perform_now.
TMP = Dir.mktmpdir("cybertrain-cli-generate-job")
Dir.chdir(TMP)

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit do
  Dir.chdir("/")
  rm_tree(TMP)
end

Cybertrain::CLI::NewApp.create("shop", "{ path = \"../cybertrain\" }")

def generate(args)
  Dir.chdir("shop") { Cybertrain::CLI.run(["generate", "job"] + args) }
end

test "generate job send_digest writes a Job::Base subclass with an empty perform and a test" do
  assert_equal 0, generate(["send_digest"])
  assert_equal <<~'RUBY', File.read("shop/app/jobs/send_digest_job.rb")
    class SendDigestJob < Cybertrain::Job::Base
      # SendDigestJob.perform_later("id" => record.id) queues it; a worker runs
      # perform with that Hash read back from JSON, so narrow its values with
      # Cybertrain::Cast.int / Cast.str. Declare policies above, one line each
      # with literal values: retry_on Klass, wait: 60, attempts: 5 /
      # discard_on Klass / limits_concurrency to: 1, key: "id". `spin run gen`
      # writes perform_later, perform_at, perform_in and perform_now (gen/jobs.rb).
      def perform(args)
        nil
      end
    end
  RUBY
  refute File.exist?("shop/test/send_digest_job.rb")
end

test "the job test is in the class form and performs the job with perform_enqueued_jobs" do
  assert_equal <<~'RUBY', File.read("shop/test/jobs/send_digest_job_test.rb")
    require "test_helper"

    # app/jobs/send_digest_job.rb: perform_enqueued_jobs performs the jobs its block queues.
    class SendDigestJobTest < ActiveSupport::TestCase
      test "SendDigestJob runs" do
        assert_equal "SendDigestJob", SendDigestJob.job_kind
        performed = perform_enqueued_jobs do
          SendDigestJob.perform_later({ "id" => 1 })
        end
        assert_equal 1, performed
      end
    end
  RUBY
  refute File.exist?("shop/test/support/app_test.rb")
end

test "a name given as the class name is not doubled: SendDigestJob is send_digest_job.rb" do
  assert_equal 0, generate(["SendDigestJob"])
  refute File.exist?("shop/app/jobs/send_digest_job_job.rb")
  assert File.read("shop/app/jobs/send_digest_job.rb").start_with?("class SendDigestJob < Cybertrain::Job::Base\n")
end

test "--retry writes a retry_on line each, and spin run gen's scan reads them" do
  assert_equal 0, generate(["Admin::Report", "--retry", "Cybertrain::Mailer::TimeoutError:60:5",
                            "--retry", "StandardError:polynomially_longer:20"])
  source = File.read("shop/app/jobs/admin/report_job.rb")
  assert source.start_with?("module Admin\n  class ReportJob < Cybertrain::Job::Base\n" \
                            "    retry_on Cybertrain::Mailer::TimeoutError, wait: 60, attempts: 5\n" \
                            "    retry_on StandardError, wait: :polynomially_longer, attempts: 20\n\n")
  assert_includes File.read("shop/test/jobs/admin/report_job_test.rb"), "class Admin::ReportJobTest < ActiveSupport::TestCase\n"
  infos = Cybertrain::Gen::JobScan.scan_dir("shop/app/jobs")
  assert_equal ["Admin::ReportJob", "SendDigestJob"], infos.map { |i| i.class_name }
  out = Cybertrain::Gen::JobsEmitter.emit(infos)
  assert_includes out, "retry_later(run, e, 60, false, 5)"
  assert_includes out, "retry_later(run, e, 0, true, 20)"
  assert_includes out, "Cybertrain::Job.register(\"Admin::ReportJob\", concurrency: 0, concurrency_key: \"\", max_attempts: 20)"
end

test "an existing, different file is refused unless --force" do
  File.write("shop/app/jobs/send_digest_job.rb", "class SendDigestJob < Cybertrain::Job::Base\nend\n")
  assert_equal 1, generate(["send_digest_job"])
  assert_equal "class SendDigestJob < Cybertrain::Job::Base\nend\n", File.read("shop/app/jobs/send_digest_job.rb")
  assert_equal 0, generate(["send_digest", "--force"])
  assert_includes File.read("shop/app/jobs/send_digest_job.rb"), "  def perform(args)\n"
  assert_equal 0, generate(["send_digest"])
end

test "bad names, bad --retry values and usage are rejected" do
  assert_equal 1, generate(["9lives"])
  assert_equal 1, generate([])
  assert_equal 1, generate(["a", "b"])
  assert_equal 1, generate(["a", "--retry"])
  assert_equal 1, generate(["a", "--wait", "3"])
  assert_equal 1, generate(["a", "--retry", "TimeoutError:60"])
  assert_equal 1, generate(["a", "--retry", "TimeoutError:5.minutes:3"])
  assert_equal 1, generate(["a", "--retry", "TimeoutError:60:0"])
  assert_equal 1, generate(["a", "--retry", "timeout:60:3"])
  refute File.exist?("shop/app/jobs/a_job.rb")
  assert_equal 1, Cybertrain::CLI.run(["generate", "job", "prices"])
end

Cybertrain::Test.run!
