# Phase 3 spike, check 2 (spec section 14): rescue arms naming classes the
# application defines, in the shape the generated run_job will have, in a
# program that requires the whole framework. A record, not a test.
#
# `require "cybertrain"` does not load cybertrain/mailer; without the second
# require below, the Mailer::TimeoutError arm names a class the program does
# not define and Spinel turns the whole begin/rescue into a catch-all that
# runs no arm (every raising mode printed an empty log): NOTES rule 89.
#
# Run (Spinel 2026.11.04.7026, from spikes/phase3/; the whole framework
# links SQLite and zlib through FFI, so compiled only):
#   spinel $(spin flags) rescue_arms.rb -o /tmp/rescue_arms && /tmp/rescue_arms
# Output, identical to CRuby 3.3.6's for the same program with the two
# requires replaced by stub classes Cybertrain::RecordNotFound and
# Cybertrain::Mailer::TimeoutError:
#   ok: done
#   sub: arm Sub (Sub: raised sub)
#   app: arm AppError (AppError: raised app)
#     retries_exhausted(Leaf)
#   leaf: arm Sub (Leaf: raised leaf)
#   timeout: arm Mailer::TimeoutError (raised timeout)
#   arg: arm ArgumentError (raised arg)
#   unlisted: caller got StandardError Unlisted: raised unlisted
#   control: arm Sub (Sub: raised control); caller got Cybertrain::RecordNotFound: control from the Sub arm
#   parent first: arm AppError (Sub); arm AppError (AppError)
#   Leaf ancestors: Leaf Sub AppError StandardError Exception Object Kernel BasicObject
#   AppError in names: true
#   Sub.ancestors: Sub AppError StandardError Exception Object Kernel BasicObject
#   Leaf < AppError: true
require "cybertrain"
require "cybertrain/mailer"

class AppError < StandardError; end
class Sub < AppError; end
class Leaf < Sub; end
class Unlisted < StandardError; end

class SpikeJob
  def perform(args)
    mode = args["mode"].to_s
    msg = "raised #{mode}"
    case mode
    when "sub" then raise Sub, msg
    when "app" then raise AppError, msg
    when "leaf" then raise Leaf, msg
    when "timeout" then raise Cybertrain::Mailer::TimeoutError, msg
    when "arg" then raise ArgumentError, msg
    when "unlisted" then raise Unlisted, msg
    when "control" then raise Sub, msg
    end
    nil
  end

  def retries_exhausted(error)
    puts "  retries_exhausted(#{error.class.name})"
    nil
  end

  # Subclass first, as a class file would list `retry_on Sub` above
  # `retry_on AppError`: the first arm that matches wins.
  def self.run_job(args, log)
    job = new
    begin
      job.perform(args)
      log << "done"
    rescue Cybertrain::Mailer::TimeoutError => e
      log << "arm Mailer::TimeoutError (#{e.message})"
    rescue Sub => e
      log << "arm Sub (#{e.class.name}: #{e.message})"
      if args["mode"].to_s == "control"
        # A framework control exception raised from inside an arm; the
        # caller (Job.finish in the real worker) sees it.
        text = "control from the Sub arm"
        raise Cybertrain::RecordNotFound, text
      end
      job.retries_exhausted(e) if args["mode"].to_s == "leaf"
    rescue AppError => e
      log << "arm AppError (#{e.class.name}: #{e.message})"
    rescue ArgumentError => e
      log << "arm ArgumentError (#{e.message})"
    end
    nil
  end

  # Parent first: a Sub never reaches the second arm.
  def self.run_job_parent_first(args, log)
    begin
      new.perform(args)
      log << "done"
    rescue AppError => e
      log << "arm AppError (#{e.class.name})"
    rescue Sub => e
      log << "arm Sub (#{e.class.name})"
    end
    nil
  end
end

# The worker's side: a stored block per kind, as Job.register will hold,
# and the outer rescue Job.finish has.
RUNNERS = [->(args, log) { SpikeJob.run_job(args, log) }]

def drive(mode)
  log = [""]
  log.clear
  begin
    RUNNERS[0].call({ "mode" => mode }, log)
  rescue Cybertrain::RecordNotFound => e
    log << "caller got #{e.class.name}: #{e.message}"
  rescue StandardError => e
    log << "caller got StandardError #{e.class.name}: #{e.message}"
  end
  puts "#{mode}: #{log.join("; ")}"
end

%w[ok sub app leaf timeout arg unlisted control].each { |m| drive(m) }

log = [""]
log.clear
SpikeJob.run_job_parent_first({ "mode" => "sub" }, log)
SpikeJob.run_job_parent_first({ "mode" => "app" }, log)
puts "parent first: #{log.join("; ")}"

begin
  raise Leaf, "x"
rescue StandardError => e
  puts "Leaf ancestors: #{e.class.ancestors.map(&:to_s).join(" ")}"
  names = e.class.ancestors.map(&:name)
  puts "AppError in names: #{names.include?("AppError")}"
end
puts "Sub.ancestors: #{Sub.ancestors.map(&:to_s).join(" ")}"
puts "Leaf < AppError: #{Leaf <= AppError}"
