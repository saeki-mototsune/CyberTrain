# The "core" of the feature-registry spike (spikes/phase6/feature_registry.rb):
# what cybertrain/feature.rb and the core files would hold. It names no
# feature class. Every hook name is used by no other class in the program,
# and every override returns the base's type (spikes/NOTES.md rules 10, 34,
# 41).

# The framework's kind of object: a class with ivars.
class Response
  attr_reader :status, :resp_body

  def initialize(status, resp_body)
    @status = status
    @resp_body = resp_body
  end

  def describe
    "#{@status} #{@resp_body}"
  end
end

class Request
  attr_reader :req_path

  def initialize(req_path)
    @req_path = req_path
  end
end

# A core class a feature file reopens.
class Controller
  def initialize(controller_name)
    @controller_name = controller_name
  end

  def controller_name
    @controller_name
  end
end

# A fixed clock, so the output does not depend on the time.
module Clock
  @now = 1000

  def self.now
    @now
  end

  def self.now=(t)
    @now = t
  end
end

# What every hook call leaves behind, in order.
module Log
  LINES = Array.new(0) { "" }

  def self.add(line)
    LINES << line
    nil
  end
end

# The base: no-op hooks with a fixed return type each.
class Feature
  # String
  def feature_label
    "base"
  end

  # String, "" for none
  def boot_problem(app_name)
    ""
  end

  # String, "" for none; overridden by FeatureA only
  def health_problem(now)
    ""
  end

  # Bool, base false
  def failed?
    false
  end

  # Bool, base true
  def reload_ok?
    true
  end

  # Integer, -1: not mine
  def command(name, argv)
    -1
  end

  # Array of String, typed empty
  def command_names
    Array.new(0) { "" }
  end

  # nil
  def start(app_name)
    nil
  end

  # nil
  def stop
    nil
  end

  # Response or nil (the stream endpoint's position in the middleware stack)
  def call(request)
    nil
  end

  # Receives and returns a Response
  def filter_response(response)
    response
  end

  # The periodic hook: "" / 0 for none
  def periodic_name
    ""
  end

  def periodic_interval
    0
  end

  def periodic(now)
    Log.add("base periodic stub ran (#{feature_label}) at #{now}")
    nil
  end
end

# The registry: a module-level Array of base-class instances, each hook
# iterated.
module Registry
  FEATURES = Array.new(0) { Feature.new }

  # Registers once by class name; answers whether it was added.
  def self.register(feature)
    name = feature.class.name
    i = 0
    while i < FEATURES.size
      return false if FEATURES[i].class.name == name
      i += 1
    end
    FEATURES << feature
    true
  end

  def self.size
    FEATURES.size
  end

  def self.labels
    FEATURES.map { |f| f.feature_label }
  end

  def self.class_names
    FEATURES.map { |f| f.class.name.to_s }
  end

  # Collect Strings (while loop).
  def self.boot_problems(app_name)
    out = Array.new(0) { "" }
    i = 0
    while i < FEATURES.size
      p = FEATURES[i].boot_problem(app_name)
      out << p unless p.empty?
      i += 1
    end
    out
  end

  # Collect Strings (each with a block).
  def self.health_problems(now)
    out = Array.new(0) { "" }
    FEATURES.each do |f|
      p = f.health_problem(now)
      out << p unless p.empty?
    end
    out
  end

  def self.any_failed?
    FEATURES.any? { |f| f.failed? }
  end

  def self.any_failed_loop?
    i = 0
    while i < FEATURES.size
      return true if FEATURES[i].failed?
      i += 1
    end
    false
  end

  def self.all_reload_ok?
    FEATURES.all? { |f| f.reload_ok? }
  end

  # First answer that is not -1.
  def self.command(name, argv)
    i = 0
    while i < FEATURES.size
      code = FEATURES[i].command(name, argv)
      return code if code != -1
      i += 1
    end
    -1
  end

  def self.command_names
    out = Array.new(0) { "" }
    FEATURES.each { |f| f.command_names.each { |n| out << n } }
    out
  end

  def self.start_all(app_name)
    FEATURES.each { |f| f.start(app_name) }
    nil
  end

  def self.stop_all
    i = 0
    while i < FEATURES.size
      FEATURES[i].stop
      i += 1
    end
    nil
  end

  # First non-nil Response.
  def self.first_response(request)
    i = 0
    while i < FEATURES.size
      r = FEATURES[i].call(request)
      return r unless r.nil?
      i += 1
    end
    nil
  end

  # Each feature's filter in turn, a Response in and out.
  def self.filter_response(response)
    r = response
    FEATURES.each { |f| r = f.filter_response(r) }
    r
  end

  # What a scheduler task's block calls: the hook is called here, outside
  # the block, on the Array element.
  def self.run_periodic(i, now)
    FEATURES[i].periodic(now)
  end

  # One scheduler task per feature that declares a periodic hook. The index
  # is a parameter of this method, so each block has its own; the block
  # captures only that Integer.
  def self.schedule_one(i)
    Sched.every(FEATURES[i].periodic_name) { Registry.run_periodic(i, Clock.now) }
    Sched.add_block { Registry.run_periodic(i, Clock.now) }
    nil
  end

  def self.schedule_periodic
    i = 0
    while i < FEATURES.size
      schedule_one(i) if FEATURES[i].periodic_interval > 0
      i += 1
    end
    nil
  end
end

# A scheduler's storage: Task objects holding a block (as
# Cybertrain::Scheduler::TASKS does), and for comparison a bare Array of
# blocks. Both are called with no argument, as the scheduler calls a task.
module Sched
  class Task
    attr_reader :task_name, :task_block

    def initialize(task_name, task_block)
      @task_name = task_name
      @task_block = task_block
    end
  end

  TASKS = Array.new(0) { Task.new("", nil) }
  BLOCKS = []

  def self.every(name, &block)
    TASKS << Task.new(name, block)
    nil
  end

  def self.add_block(&block)
    BLOCKS << block
    nil
  end

  def self.run_tasks
    i = 0
    while i < TASKS.size
      TASKS[i].task_block.call
      i += 1
    end
    nil
  end

  def self.run_blocks
    i = 0
    while i < BLOCKS.size
      BLOCKS[i].call
      i += 1
    end
    nil
  end
end
