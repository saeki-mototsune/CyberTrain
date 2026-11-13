require "tmpdir"
require "stringio"
# The subsystems required in another order than cybertrain.rb's (rate_limit
# first, jobs last): the features still run in their rank order
# (Feature#feature_rank), jobs, feeds, streams, cache, rate_limit.
require "cybertrain/core"
require "cybertrain/rate_limit"
require "cybertrain/streams"
require "cybertrain/feeds"
require "cybertrain/jobs"
require "cybertrain/test"

# The order the features run in does not follow the order of bin/NAME.rb's
# requires (docs/superpowers/specs/2026-11-13-optional-subsystems-design.md,
# section 3: "requires are order-insensitive"): `help`, `/up` and the
# server role's starts and stops follow the features' ranks. Probe
# features, ranked between the real ones, record what is running when
# Features calls them, in the sequence Roles::ServerRunner#run_server
# makes the calls (start_features_early, the listener, start_features, the
# TERM trap's request_stop_features, stop_features; the listener's place
# between the first two is the runner's own code, not a feature's), so the
# record pins: the stream poller starts first; then the Scheduler, the job
# threads and the Background services; they stop as Job, Scheduler,
# Background, poller. test/features_jobs.rb pins cybertrain.rb's order. It
# links SQLite through FFI, so its snapshot comes from the compiled binary
# (spikes/NOTES.md rule 23).

TMP = Dir.mktmpdir("cybertrain-features-order")

def rm_tree(path)
  if File.directory?(path)
    Dir.children(path).each { |child| rm_tree(File.join(path, child)) }
    Dir.rmdir(path)
  else
    File.delete(path)
  end
end

at_exit { rm_tree(TMP) }

LOG = StringIO.new
Cybertrain.logger = Cybertrain::Logger.new(LOG)

# What the probes saw, in order (a constant: NOTES rule 64).
EVENTS = Array.new(0) { "" }

# What is running now, and the record of it (module methods: the probes'
# hooks call them).
module Probe
  def self.running_text
    background = EVENTS.include?("background started") && !EVENTS.include?("background stopped")
    "poller=#{Cybertrain::Stream::Poller.running?} scheduler=#{Cybertrain::Scheduler.running?} " \
      "job=#{Cybertrain::Job.running?} background=#{background}"
  end

  def self.record(text)
    EVENTS << "#{text}: #{running_text}"
    nil
  end
end

# A feature that only records, at rank `rank`.
class ProbeFeature < Cybertrain::Feature
  def initialize(label, rank)
    @label = label
    @rank = rank
  end

  def feature_name
    @label
  end

  def feature_rank
    @rank
  end

  def start_feature_early(config)
    Probe.record("#{@label} early")
  end

  def start_feature(config)
    Probe.record("#{@label} start")
  end

  def request_stop_feature
    Probe.record("#{@label} request stop")
  end

  def stop_feature
    Probe.record("#{@label} stop")
  end
end

# A Background service that records its start and stop (FeedsFeature starts
# and stops the services).
class ProbeService < Cybertrain::Background::Service
  def service_name
    "probe"
  end

  def service_start(config)
    EVENTS << "background started"
    true
  end

  def service_stop
    EVENTS << "background stopped"
    nil
  end
end

# Each probe registers once (Features refuses a second instance of a
# class), so the probes are four classes.
class ProbeA < ProbeFeature; end
class ProbeB < ProbeFeature; end
class ProbeC < ProbeFeature; end
class ProbeD < ProbeFeature; end

Cybertrain::Job.handle("probe") { |payload| nil }
Cybertrain::Background.register(ProbeService.new)

test "the features run in rank order, not in the requires' order" do
  assert_equal "jobs,feeds,streams,cache,rate_limit", Cybertrain::Features.feature_names.join(",")
  usage = Cybertrain::Main.usage("blog")
  worker = usage.index("./blog worker") || -1
  feeds = usage.index("./blog feeds") || -1
  assert worker >= 0
  assert feeds > worker
end

test "a feature registered later takes its place by rank" do
  Cybertrain::Features.register_feature(ProbeD.new("probe-d", 35))
  Cybertrain::Features.register_feature(ProbeA.new("probe-a", 5))
  Cybertrain::Features.register_feature(ProbeC.new("probe-c", 25))
  Cybertrain::Features.register_feature(ProbeB.new("probe-b", 15))
  assert_equal "probe-a,jobs,probe-b,feeds,probe-c,streams,probe-d,cache,rate_limit",
               Cybertrain::Features.feature_names.join(",")
end

test "the server role's starts and stops: poller, Scheduler, Job, Background; then Job, Scheduler, Background, poller" do
  Cybertrain::DB.connect(File.join(TMP, "order.sqlite3"))
  config = Cybertrain::Config.new
  config.worker = true
  config.job_threads = 1
  config.job_poll_interval = 1
  config.job_drain_timeout = 1
  refute config.stream_path.empty?
  # Roles::ServerRunner#run_server's sequence.
  Cybertrain::Features.start_features_early(config)
  EVENTS << "listener"
  Cybertrain::Features.start_features(config)
  Cybertrain::Features.request_stop_features
  Cybertrain::Features.stop_features
  EVENTS.each { |line| puts line }
  assert_equal [
    "probe-a early: poller=false scheduler=false job=false background=false",
    "probe-b early: poller=false scheduler=false job=false background=false",
    "probe-c early: poller=false scheduler=false job=false background=false",
    "probe-d early: poller=true scheduler=false job=false background=false",
    "listener",
    "probe-a start: poller=true scheduler=false job=false background=false",
    "probe-b start: poller=true scheduler=true job=true background=false",
    "background started",
    "probe-c start: poller=true scheduler=true job=true background=true",
    "probe-d start: poller=true scheduler=true job=true background=true",
    "probe-a request stop: poller=true scheduler=true job=true background=true",
    # The jobs feature's request stops the job claims (Job.running? false).
    "probe-b request stop: poller=true scheduler=true job=false background=true",
    "probe-c request stop: poller=true scheduler=true job=false background=true",
    "probe-d request stop: poller=true scheduler=true job=false background=true",
    "probe-a stop: poller=true scheduler=true job=false background=true",
    "probe-b stop: poller=true scheduler=false job=false background=true",
    "background stopped",
    "probe-c stop: poller=true scheduler=false job=false background=false",
    "probe-d stop: poller=false scheduler=false job=false background=false"
  ].join("\n"), EVENTS.join("\n")
end

Cybertrain::Test.run!
