# The checks of the feature-registry spike, one line each, run by every
# entry program after it has required the features in its own order. The
# output does not depend on that order: lists that follow registration
# order are printed sorted (the "order:" line, printed by the entry, is
# the one exception).

module Checks
  def self.yn(b)
    b ? "true" : "false"
  end

  def self.run
    puts "registered: #{Registry.size}"
    puts "labels: #{Registry.labels.sort.join(",")}"
    puts "classes: #{Registry.class_names.sort.join(",")}"

    # A second register of a class already there is refused by name.
    again = Registry.register(FeatureA.new)
    puts "register FeatureA again: #{yn(again)}, registered: #{Registry.size}"

    # Strings.
    puts "boot problems (ok): #{Registry.boot_problems("shop").size}"
    puts "boot problems (broken): #{Registry.boot_problems("broken").sort.join(" | ")}"
    puts "health problems: #{Registry.health_problems(Clock.now).join(" | ")}"
    each_health = Array.new(0) { "" }
    Registry::FEATURES.each { |f| each_health << "#{f.feature_label}=#{f.health_problem(Clock.now).inspect}" }
    puts "health per feature: #{each_health.sort.join(" ")}"

    # Bools.
    puts "any failed? (each/any?): #{yn(Registry.any_failed?)} (loop): #{yn(Registry.any_failed_loop?)}"
    FeatureB.broken = true
    puts "any failed? after b breaks (each/any?): #{yn(Registry.any_failed?)} (loop): #{yn(Registry.any_failed_loop?)}"
    puts "all reload ok?: #{yn(Registry.all_reload_ok?)}"
    each_reload = Array.new(0) { "" }
    Registry::FEATURES.each { |f| each_reload << "#{f.feature_label}=#{yn(f.reload_ok?)}/#{yn(f.failed?)}" }
    puts "reload_ok?/failed? per feature: #{each_reload.sort.join(" ")}"

    # Integers.
    puts "command alpha: #{Registry.command("alpha", ["x", "y", "z"])}"
    puts "command beta: #{Registry.command("beta", Array.new(0) { "" })}"
    puts "command gamma: #{Registry.command("gamma", ["x"])}"
    puts "command names: #{Registry.command_names.sort.join(",")}"

    # nil hooks, seen through the log.
    Registry.start_all("shop")
    Registry.stop_all

    # Response or nil.
    ["/a", "/b", "/c"].each do |path|
      r = Registry.first_response(Request.new(path))
      puts "call #{path}: #{r.nil? ? "nil" : r.describe}"
    end

    # A Response in, a Response out.
    puts "filter: #{Registry.filter_response(Response.new(200, "page")).describe}"

    # The periodic hook from stored blocks that only call
    # Registry.run_periodic(i, now).
    Registry.schedule_periodic
    puts "tasks: #{Sched::TASKS.map { |t| t.task_name }.join(",")}, blocks: #{Sched::BLOCKS.size}"
    Clock.now = 2000
    Sched.run_tasks
    Clock.now = 3000
    Sched.run_blocks

    # A core class reopened by feature A.
    c = Controller.new("posts")
    puts "reopened: #{c.controller_name} #{c.turbo_mark} #{Controller.rate_limit(5)}"

    Log::LINES.sort.each { |l| puts "log: #{l}" }
  end
end
