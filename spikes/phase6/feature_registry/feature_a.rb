# Feature A of the feature-registry spike: overrides some hooks, reopens
# the core's Controller, and registers one instance at require time.
require_relative "core"

class FeatureA < Feature
  def feature_label
    "a"
  end

  def boot_problem(app_name)
    app_name == "broken" ? "a: #{app_name} has no worker" : ""
  end

  # The only override of health_problem: FeatureB runs the base stub.
  def health_problem(now)
    "a: stale since #{now - 30}"
  end

  def reload_ok?
    false
  end

  def command(name, argv)
    return -1 unless name == "alpha"
    argv.size
  end

  def command_names
    ["alpha"]
  end

  def stop
    Log.add("a stopped")
    nil
  end

  def call(request)
    return nil unless request.req_path == "/a"
    Response.new(200, "from a")
  end
end

# Reopening a core class: an instance method and a class method.
class Controller
  def turbo_mark
    "turbo:#{@controller_name}"
  end

  def self.rate_limit(n)
    "limit #{n} per minute"
  end
end

Registry.register(FeatureA.new)
