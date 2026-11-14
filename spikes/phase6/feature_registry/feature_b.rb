# Feature B of the feature-registry spike: overrides a different subset of
# hooks, including the periodic one, and registers one instance at require
# time.
require_relative "core"

class FeatureB < Feature
  @broken = false

  def self.broken=(v)
    @broken = v
  end

  def self.broken
    @broken
  end

  def feature_label
    "b"
  end

  def boot_problem(app_name)
    app_name == "broken" ? "b: #{app_name} has no feed" : ""
  end

  def failed?
    FeatureB.broken
  end

  def command(name, argv)
    return -1 unless name == "beta"
    7
  end

  def command_names
    ["beta", "beta-list"]
  end

  def start(app_name)
    Log.add("b started for #{app_name}")
    nil
  end

  def stop
    Log.add("b stopped")
    nil
  end

  def call(request)
    return nil unless request.req_path == "/b"
    Response.new(201, "from b")
  end

  def filter_response(response)
    Response.new(response.status, "#{response.resp_body} [b]")
  end

  def periodic_name
    "b-prune"
  end

  def periodic_interval
    60
  end

  def periodic(now)
    Log.add("b periodic at #{now}")
    nil
  end
end

Registry.register(FeatureB.new)
