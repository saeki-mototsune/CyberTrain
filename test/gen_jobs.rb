require "tmpdir"
require "fileutils"
require "cybertrain/test"
require "cybertrain/generator"
require "cybertrain/generator/job_scan"
require "cybertrain/generator/jobs_emitter"

# The job generator as text (CRuby-portable, no database): Gen::JobScan
# reads app/jobs/**/*.rb, Gen::JobsEmitter writes gen/jobs.rb. The
# fixture app's WelcomeJob and Admin::ReportJob, then small app trees
# written to a temporary directory for the orderings and the refusals
# (test/gen_jobs_compiles.rb runs the fixture's generated code).
FIXTURE = "test/fixtures/gen_app"
TMP = Dir.mktmpdir("cybertrain-gen-jobs")

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  elsif File.exist?(path)
    File.delete(path)
  end
end

at_exit { rm_tree(TMP) }

# A fresh app tree under TMP with `files` ({ "app/jobs/x_job.rb" => source }).
def app_tree(files)
  root = Dir.mktmpdir("app", TMP)
  files.each do |rel, source|
    path = File.join(root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
  end
  root
end

def scan(root)
  Cybertrain::Gen::JobScan.scan_dir("#{root}/app/jobs")
end

def emit(root)
  Cybertrain::Gen::JobsEmitter.emit(scan(root))
end

# The message of the JobScan::Error scanning `root` raises.
def refusal(root)
  scan(root)
  flunk("expected Gen::JobScan::Error")
  ""
rescue Cybertrain::Gen::JobScan::Error => e
  Cybertrain::Test.count_assertion
  e.message
end

# One job class with `macro` as its first body line.
def job_source(name, *macros)
  out = +"class #{name} < Cybertrain::Job::Base\n"
  macros.each { |m| out << "  #{m}\n" }
  out << "\n  def perform(args)\n    nil\n  end\nend\n"
  out
end

# Asserts the pieces appear in `text` in this order.
def assert_in_order(text, pieces)
  at = 0
  pieces.each do |piece|
    found = text.index(piece, at)
    Cybertrain::Test.count_assertion
    flunk("#{piece.inspect} not found after offset #{at} in:\n#{text}") if found.nil?
    at = found + piece.size
  end
end

test "the fixture's jobs: WelcomeJob and Admin::ReportJob with their policies in declaration order" do
  infos = scan(FIXTURE)
  assert_equal ["Admin::ReportJob", "DigestJob", "WelcomeJob"], infos.map { |i| i.class_name }
  assert_equal "Admin::ReportJob", infos[1].superclass_name
  welcome = infos[2]
  assert_equal "#{FIXTURE}/app/jobs/welcome_job.rb", welcome.file
  assert_equal "Cybertrain::Job::Base", welcome.superclass_name
  assert_equal ["retry", "discard"], welcome.policies.map { |p| p.policy_kind }
  assert_equal ["Cybertrain::Mailer::TimeoutError", "ArgumentError"], welcome.policies.map { |p| p.exception_class }
  assert_equal [60, 0], welcome.policies.map { |p| p.wait_base }
  assert_equal [false, false], welcome.policies.map { |p| p.polynomial }
  assert_equal [5, 0], welcome.policies.map { |p| p.attempts }
  assert_equal 1, welcome.concurrency_to
  assert_equal "user_id", welcome.concurrency_key
  assert welcome.has_perform
  assert welcome.has_exhausted_hook
  report = infos[0]
  assert_equal ["retry", "discard"], report.policies.map { |p| p.policy_kind }
  assert_equal ["StandardError", "ArgumentError"], report.policies.map { |p| p.exception_class }
  assert_equal [0, true, 20], [report.policies[0].wait_base, report.policies[0].polynomial, report.policies[0].attempts]
  assert_equal 0, report.concurrency_to
  assert_equal "", report.concurrency_key
  refute report.has_exhausted_hook
end

test "WelcomeJob's run_job: the retry arm with the hook behind OUTCOME_FAILED, then the discard arm" do
  out = Cybertrain::Gen::JobsEmitter.emit(scan(FIXTURE))
  assert_in_order(out, [
    "class WelcomeJob < Cybertrain::Job::Base\n",
    "  def self.run_job(run)\n" \
    "    job = new\n" \
    "    begin\n" \
    "      job.perform(run.run_args)\n" \
    "    rescue ::Cybertrain::Mailer::TimeoutError => e\n" \
    "      if Cybertrain::Job.retry_later(run, e, 60, false, 5) == Cybertrain::Job::OUTCOME_FAILED\n" \
    "        job.retries_exhausted(e)\n" \
    "      end\n" \
    "    rescue ::ArgumentError => e\n" \
    "      Cybertrain::Job.discard(run, e)\n" \
    "    end\n" \
    "    nil\n" \
    "  end\n",
    "Cybertrain::Job.register(\"WelcomeJob\", concurrency: 1, concurrency_key: \"user_id\", max_attempts: 5) { |run| WelcomeJob.run_job(run) }\n"
  ])
  # The discard arm never hands Job.discard's answer to the hook.
  discard = out.index("Cybertrain::Job.discard(run, e)")
  refute out[discard, 80].to_s.include?("retries_exhausted")
end

test "Admin::ReportJob is reopened in its module, polynomially longer with 20 attempts, no key" do
  out = Cybertrain::Gen::JobsEmitter.emit(scan(FIXTURE))
  assert_in_order(out, [
    "module Admin\n  class ReportJob < ::Cybertrain::Job::Base\n",
    "    def self.job_kind\n      \"Admin::ReportJob\"\n    end\n",
    "      rescue ::StandardError => e\n" \
    "        if Cybertrain::Job.retry_later(run, e, 0, true, 20) == Cybertrain::Job::OUTCOME_FAILED\n",
    "      rescue ::ArgumentError => e\n        Cybertrain::Job.discard(run, e)\n"
  ])
  assert_includes out, "Cybertrain::Job.register(\"Admin::ReportJob\", concurrency: 0, concurrency_key: \"\", max_attempts: 20) " \
                       "{ |run| Admin::ReportJob.run_job(run) }\n"
  # The registrations follow every class reopening.
  assert out.index("Cybertrain::Job.register(") > out.rindex("  def self.run_job(run)\n")
end

test "perform_later raises for a non-Hash, then enqueues the class's kind with the JSON args" do
  out = Cybertrain::Gen::JobsEmitter.emit(scan(FIXTURE))
  assert_in_order(out, [
    "class WelcomeJob",
    "  def self.perform_later(args = {})\n" \
    "    unless args.is_a?(Hash)\n" \
    "      message = \"WelcomeJob.perform_later: args must be a Hash (a JSON object), not \#{args.class.name}\"\n" \
    "      raise ArgumentError, message\n" \
    "    end\n" \
    "    Cybertrain::Job.enqueue(job_kind, JSON.generate(args))\n" \
    "  end\n",
    "  def self.perform_at(time, args = {})\n",
    "    Cybertrain::Job.enqueue(job_kind, JSON.generate(args), run_at: time)\n",
    "  def self.perform_in(seconds, args = {})\n",
    "    Cybertrain::Job.enqueue(job_kind, JSON.generate(args), run_at: Time.current + seconds)\n",
    "  def self.perform_now(args = {})\n",
    "    new.perform(Cybertrain::Cast.hash(args))\n    nil\n  end\n"
  ])
end

test "the arms keep declaration order: discard_on written before retry_on comes first" do
  root = app_tree("app/jobs/sweep_job.rb" => job_source("SweepJob", "discard_on ArgumentError", "retry_on StandardError, attempts: 3"))
  out = emit(root)
  assert_in_order(out, [
    "    rescue ::ArgumentError => e\n      Cybertrain::Job.discard(run, e)\n",
    "    rescue ::StandardError => e\n      if Cybertrain::Job.retry_later(run, e, 3, false, 3) == Cybertrain::Job::OUTCOME_FAILED\n"
  ])
  # Unlimited, no key; the default wait is 3 seconds; no concurrency.
  assert_includes out, "Cybertrain::Job.register(\"SweepJob\", concurrency: 0, concurrency_key: \"\", max_attempts: 3)"
end

test "a job without policies runs perform with no rescue; max_attempts 0" do
  root = app_tree("app/jobs/plain_job.rb" => job_source("PlainJob"))
  out = emit(root)
  assert_includes out, "  def self.run_job(run)\n    job = new\n    job.perform(run.run_args)\n    nil\n  end\n"
  assert_includes out, "Cybertrain::Job.register(\"PlainJob\", concurrency: 0, concurrency_key: \"\", max_attempts: 0) { |run| PlainJob.run_job(run) }\n"
end

test "max_attempts is the largest attempts: of the retry lines" do
  root = app_tree("app/jobs/many_job.rb" => job_source("ManyJob", "retry_on ArgumentError, attempts: 9, wait: 1",
                                                       "retry_on(StandardError, wait: 2)", "limits_concurrency to: 3"))
  out = emit(root)
  assert_includes out, "retry_later(run, e, 1, false, 9)"
  assert_includes out, "retry_later(run, e, 2, false, 5)"
  assert_includes out, "Cybertrain::Job.register(\"ManyJob\", concurrency: 3, concurrency_key: \"\", max_attempts: 9)"
end

test "no job class: gen/jobs.rb is the header alone" do
  assert_equal "# Generated by `spin run gen` from app/jobs. Do not edit.\n", Cybertrain::Gen::JobsEmitter.emit([])
  root = app_tree("app/models/post.rb" => "class Post\nend\n")
  assert_equal 0, scan(root).size
end

test "a class in app/jobs that does not inherit Job::Base is skipped" do
  root = app_tree(
    "app/jobs/job_helpers.rb" => "module JobHelpers\n  def self.retry_on(x) = x\nend\n",
    "app/jobs/plain.rb" => "class Plain\n  retry_on Whatever, wait: 5.minutes\nend\n",
    "app/jobs/real_job.rb" => job_source("RealJob")
  )
  assert_equal ["RealJob"], scan(root).map { |i| i.class_name }
end

test "a macro it cannot read stops generation with the one-line message" do
  [
    "retry_on ArgumentError do |job, error|",
    "retry_on ArgumentError, wait: 5.minutes",
    "retry_on ArgumentError, :wait => 5",
    "retry_on ArgumentError, wait: 5 # five seconds",
    "retry_on ArgumentError,",
    "retry_on ArgumentError, wait: ->(n) { n }",
    "retry_on ArgumentError, StandardError",
    "retry_on ArgumentError, tries: 3",
    "retry_on ArgumentError, attempts: 0",
    "discard_on ArgumentError, wait: 1",
    "limits_concurrency to: 1, key: :user_id",
    "limits_concurrency to: n"
  ].each do |line|
    root = app_tree("app/jobs/x_job.rb" => job_source("XJob", line))
    assert_equal "#{root}/app/jobs/x_job.rb:2: #{line} -- write retry_on/discard_on/limits_concurrency on one line with literal values",
                 refusal(root)
  end
end

test "a macro inside a method is code, not a declaration" do
  source = "class CodeJob < Cybertrain::Job::Base\n  def perform(args)\n    retry_on = 3\n    discard_on(retry_on)\n  end\nend\n"
  infos = scan(app_tree("app/jobs/code_job.rb" => source))
  assert_equal 0, infos[0].policies.size
end

test "rule 89: a class the program does not define is refused" do
  root = app_tree("app/jobs/x_job.rb" => job_source("XJob", "retry_on Cybertrain::Mailer::Gone, attempts: 2"))
  assert_equal "#{root}/app/jobs/x_job.rb:2: Cybertrain::Mailer::Gone is not a class this program defines (spikes/NOTES.md rule 89)",
               refusal(root)
  root = app_tree("app/jobs/x_job.rb" => job_source("XJob", "discard_on MissingError"))
  assert_equal "#{root}/app/jobs/x_job.rb:2: MissingError is not a class this program defines (spikes/NOTES.md rule 89)",
               refusal(root)
end

test "rule 89: application classes from app/models, application_job.rb and above the macro are accepted" do
  root = app_tree(
    "app/models/billing.rb" => "module Billing\n  class Declined < StandardError\n  end\nend\n",
    "app/jobs/application_job.rb" => "class ApplicationJob < Cybertrain::Job::Base\nend\n\nclass Gone < StandardError; end\n",
    "app/jobs/charge_job.rb" => "class Late < StandardError\nend\n\n" +
      job_source("ChargeJob", "retry_on Billing::Declined, attempts: 2", "discard_on Gone", "discard_on Late"),
    "app/jobs/nested_job.rb" => "class NestedJob < ApplicationJob\n  class Stuck < StandardError; end\n  retry_on Stuck\n\n  def perform(args) = nil\nend\n"
  )
  infos = scan(root)
  # ApplicationJob is scanned first (JobsEmitter writes nothing for it).
  assert_equal ["ApplicationJob", "ChargeJob", "NestedJob"], infos.map { |i| i.class_name }
  assert_equal ["Billing::Declined", "Gone", "Late"], infos[1].policies.map { |p| p.exception_class }
  # Written as `Stuck` inside the class: the arm names it in full.
  assert_equal ["NestedJob::Stuck"], infos[2].policies.map { |p| p.exception_class }
  assert_equal "ApplicationJob", infos[2].superclass_name
end

test "rule 89: a class defined where it does not load before the job is refused, naming the file" do
  root = app_tree("app/services/errors.rb" => "class ServiceError < StandardError\nend\n",
                  "app/jobs/x_job.rb" => job_source("XJob", "retry_on ServiceError"))
  assert_equal "#{root}/app/jobs/x_job.rb:2: ServiceError is defined in #{root}/app/services/errors.rb, which does not load " \
               "before this job -- define it in app/models, app/jobs/application_job.rb or this file", refusal(root)
  # Another job file, and this file below the macro.
  root = app_tree("app/jobs/a_job.rb" => job_source("AJob") + "class AError < StandardError; end\n",
                  "app/jobs/b_job.rb" => job_source("BJob", "discard_on AError"))
  assert_includes refusal(root), "b_job.rb:2: AError is defined in #{root}/app/jobs/a_job.rb, which does not load before this job"
  root = app_tree("app/jobs/c_job.rb" => job_source("CJob", "discard_on CError") + "class CError < StandardError; end\n")
  assert_includes refusal(root), "c_job.rb:2: CError is defined in #{root}/app/jobs/c_job.rb, which does not load before this job"
  # ApplicationJob itself: only above its macro.
  root = app_tree("app/jobs/application_job.rb" => "class ApplicationJob < Cybertrain::Job::Base\n  discard_on BaseError\nend\n" \
                                                   "class BaseError < StandardError; end\n")
  assert_includes refusal(root), "application_job.rb:2: BaseError is defined in #{root}/app/jobs/application_job.rb, which does not load"
end

test "ApplicationJob is not a job; its policies and limit follow its subclasses' own" do
  root = app_tree(
    "app/jobs/application_job.rb" => "class ApplicationJob < Cybertrain::Job::Base\n  discard_on KeyError\n  limits_concurrency to: 2\nend\n",
    "app/jobs/own_job.rb" => "class OwnJob < ApplicationJob\n  retry_on IOError, attempts: 7\n\n  def perform(args) = nil\nend\n",
    "app/jobs/bare_job.rb" => "class BareJob < Cybertrain::Job::Base\n  def perform(args) = nil\nend\n"
  )
  out = emit(root)
  refute out.include?("class ApplicationJob")
  refute out.include?("\"ApplicationJob\"")
  assert_in_order(out, ["class OwnJob < ApplicationJob\n", "rescue ::IOError => e\n", "rescue ::KeyError => e\n"])
  assert_includes out, "register(\"OwnJob\", concurrency: 2, concurrency_key: \"\", max_attempts: 7)"
  # Not a subclass of ApplicationJob: none of it.
  assert_includes out, "register(\"BareJob\", concurrency: 0, concurrency_key: \"\", max_attempts: 0)"
end

test "a job class without perform, or redefining a generated class method, is refused" do
  root = app_tree("app/jobs/idle_job.rb" => "class IdleJob < Cybertrain::Job::Base\n  retry_on IOError\nend\n")
  assert_equal "#{root}/app/jobs/idle_job.rb: IdleJob defines no perform(args); a job class needs one " \
               "(Cybertrain::Job::Base#perform raises NotImplementedError)", refusal(root)
  root = app_tree("app/jobs/x_job.rb" => "class XJob < Cybertrain::Job::Base\n  def self.perform_later(args) = 1\n  def perform(args) = nil\nend\n")
  assert_equal "#{root}/app/jobs/x_job.rb:2: perform_later is generated into every job class (gen/jobs.rb); " \
               "give the method another name", refusal(root)
end

test "the manifest requires the mailer, then the job files, application_job first, then gen/jobs, before the controllers" do
  app = Cybertrain::Gen::Manifest.emit(FIXTURE)
  assert_in_order(app, [
    "require \"cybertrain/mailer\"\n",
    "require_relative \"../app/models/post\"\n",
    "require_relative \"../app/jobs/admin/report_job\"\n",
    "require_relative \"../app/jobs/digest_job\"\n",
    "require_relative \"../app/jobs/welcome_job\"\n",
    "require_relative \"jobs\"\n",
    "require_relative \"../app/controllers/application_controller\"\n"
  ])
  root = app_tree("app/jobs/application_job.rb" => "class ApplicationJob < Cybertrain::Job::Base\nend\n",
                  "app/jobs/admin/sync_job.rb" => "module Admin\n" + job_source("SyncJob", "retry_on Cybertrain::Net::TimeoutError") + "end\n")
  app = Cybertrain::Gen::Manifest.emit(root)
  assert_in_order(app, ["require \"cybertrain/net/socket\"\n", "require_relative \"../app/jobs/application_job\"\n",
                        "require_relative \"../app/jobs/admin/sync_job\"\n", "require_relative \"jobs\"\n"])
  refute app.include?("cybertrain/mailer")
end

test "every job class is scanned: two in one file, one nested in a class, and a grandchild" do
  root = app_tree(
    "app/jobs/application_job.rb" => "class ApplicationJob < Cybertrain::Job::Base\n  discard_on KeyError\nend\n",
    "app/jobs/a_mid_job.rb" => "class MidJob < ApplicationJob\n  retry_on IOError, attempts: 4\n  limits_concurrency to: 2, key: \"site\"\n\n" \
                               "  def perform(args) = nil\nend\n",
    "app/jobs/pair_jobs.rb" => job_source("FirstJob") + "\n" + job_source("SecondJob", "retry_on IOError, attempts: 2"),
    "app/jobs/outer.rb" => "class Outer\n  def helper = 1\n\n  class InnerJob < Cybertrain::Job::Base\n    discard_on ArgumentError\n\n" \
                           "    def perform(args) = nil\n  end\nend\n",
    "app/jobs/z_leaf_job.rb" => "class LeafJob < MidJob\n  discard_on ArgumentError\nend\n"
  )
  infos = scan(root)
  assert_equal ["ApplicationJob", "MidJob", "Outer::InnerJob", "FirstJob", "SecondJob", "LeafJob"], infos.map { |i| i.class_name }
  assert_equal ["ApplicationJob", "MidJob"], infos.map { |i| i.superclass_name }.values_at(1, 5)
  assert_equal ["class"], infos[2].scope_keywords
  out = Cybertrain::Gen::JobsEmitter.emit(infos)
  assert_includes out, "class SecondJob < Cybertrain::Job::Base\n"
  assert_includes out, "register(\"SecondJob\", concurrency: 0, concurrency_key: \"\", max_attempts: 2)"
  # Outer is a class: reopened as one, the arm anchored at the top level.
  assert_in_order(out, ["class Outer\n  class InnerJob < ::Cybertrain::Job::Base\n", "      rescue ::ArgumentError => e\n"])
  assert_includes out, "register(\"Outer::InnerJob\", concurrency: 0"
  # The grandchild: its own arm, then MidJob's, then ApplicationJob's; MidJob's limit.
  leaf = out[out.index("class LeafJob < MidJob\n"), out.size].to_s
  assert_in_order(leaf, ["rescue ::ArgumentError => e\n", "rescue ::IOError => e\n", "rescue ::KeyError => e\n"])
  assert_includes out, "Cybertrain::Job.register(\"LeafJob\", concurrency: 2, concurrency_key: \"site\", max_attempts: 4) { |run| LeafJob.run_job(run) }\n"
end

test "a job's superclass must load before it; < ApplicationJob needs application_job.rb" do
  root = app_tree("app/jobs/a_leaf_job.rb" => "class LeafJob < MidJob\nend\n",
                  "app/jobs/b_mid_job.rb" => job_source("MidJob"))
  assert_equal "#{root}/app/jobs/a_leaf_job.rb:1: MidJob is defined in #{root}/app/jobs/b_mid_job.rb, which does not load " \
               "before this job -- define it in app/jobs/application_job.rb, above it in this file, or in a file that sorts before this one",
               refusal(root)
  root = app_tree("app/jobs/x_job.rb" => "class XJob < ApplicationJob\n  def perform(args) = nil\nend\n")
  assert_equal "#{root}/app/jobs/x_job.rb:1: XJob inherits ApplicationJob, which app/jobs/application_job.rb does not define", refusal(root)
  # A class whose superclass is no job class is still not a job.
  root = app_tree("app/jobs/x.rb" => "class Thing < Struct\n  retry_on Whatever, wait: 5.minutes\nend\n")
  assert_equal 0, scan(root).size
end

test "framework errors: those require \"cybertrain\" loads need no require line, the mailer's do" do
  root = app_tree("app/jobs/db_job.rb" => job_source("DbJob", "retry_on Cybertrain::DB::Error, attempts: 3",
                                                     "discard_on Cybertrain::Template::SyntaxError"))
  assert_equal [], Cybertrain::Gen::JobScan.framework_files(scan(root))
  refute Cybertrain::Gen::Manifest.emit(root).include?("require \"cybertrain/")
  assert_includes emit(root), "rescue ::Cybertrain::DB::Error => e\n"
  assert_equal ["mailer"], Cybertrain::Gen::JobScan.framework_files(scan(FIXTURE))
end

test "FRAMEWORK_ERRORS names every Error class under cybertrain/, and the preloaded files are loaded by cybertrain/core.rb" do
  found = []
  Dir.glob("cybertrain/**/*.rb").sort.each do |path|
    next if path.start_with?("cybertrain/generator/") || path.start_with?("cybertrain/cli/")

    stack = []
    File.read(path, encoding: "UTF-8").each_line do |raw|
      indent = raw[/\A */].size
      stack.pop while !stack.empty? && raw.strip.start_with?("end") && indent <= stack.last[1] && (raw.strip == "end" || raw.strip.start_with?("end "))
      if (m = raw.chomp.match(/\A\s*(module|class)\s+([A-Z]\w*)(.*)\z/))
        one_line = m[3].include?("; end")
        if m[1] == "class" && (m[2] == "Error" || m[2].end_with?("Error")) && m[3].include?("<")
          found << [(stack.map(&:first) + [m[2]]).join("::"), path.delete_prefix("cybertrain/").delete_suffix(".rb")]
        end
        stack << [m[2], indent] unless one_line
      end
    end
  end
  assert_equal found.sort, Cybertrain::Gen::JobScan::FRAMEWORK_ERRORS.sort
  # The core: an application that requires only cybertrain/core loads them
  # too (cybertrain.rb requires the core first).
  top = File.read("cybertrain/core.rb")
  Cybertrain::Gen::JobScan::PRELOADED_FILES.each do |file|
    direct = top.include?("require \"cybertrain/#{file}\"\n")
    parent = file.split("/").first
    through = top.include?("require \"cybertrain/#{parent}\"\n") && File.read("cybertrain/#{parent}.rb").include?("require \"cybertrain/#{file}\"\n")
    assert(direct || through, "#{file} is not loaded by cybertrain/core.rb")
  end
end

Cybertrain::Test.run!
