# Cybertrain::Feature and Cybertrain::Features -- how the core reaches an
# optional subsystem without naming it (docs/superpowers/specs/
# 2026-11-13-optional-subsystems-design.md, section 4). Spinel compiles every
# method of every file a program requires, so a core file that named
# Scheduler or Job would pull jobs into every application. Instead the core
# calls hooks on the features that were required:
#
#   require "cybertrain/jobs"   # defines JobsFeature < Feature and, at the
#                               # end of the file, Features.register_feature(JobsFeature.new)
#
# Feature is a base class whose hooks do nothing and answer a fixed type;
# a subsystem's entry file defines a subclass that overrides the hooks it
# needs and registers one instance at require time. Features holds them in
# a module constant Array and calls each hook on each element, in
# registration order.
#
# The shape is the one spikes/NOTES.md rule 101 proved under the pinned
# Spinel (spikes/phase6/feature_registry/):
#   * one return type per hook name, in the base and every override, and
#     hook names no other class of the framework defines (rules 10, 34, 41):
#     hence `start_feature` rather than `start`, `run_feature_command`
#     rather than `command`, `feature_middleware` rather than `call` (rule 40);
#   * a feature file registers its instance at its end, outside the class
#     body, and never writes a block that calls a hook inside its class
#     body ahead of that hook's `def` (rule 101's narrowing of rule 88);
#   * a stored block (a scheduler task) calls Features.run_periodic(i, now),
#     which indexes the Array and calls the hook outside the block.
module Cybertrain
  # The base of every optional subsystem's feature. Each hook is a no-op
  # answering its type's "nothing": "" for a String, false, -1 for a
  # command, nil. Override only what the subsystem needs, with the same
  # parameters and the same return type.
  # @api private
  class Feature
    # The subsystem's name, as its require line has it ("jobs", "cache").
    # @return [String]
    def feature_name
      ""
    end

    # A reason the application must not boot (Application#validate_boot,
    # before anything is acquired); "" when there is none.
    # @param config [Config]
    # @return [String]
    def boot_problem(config)
      ""
    end

    # A reason the server role must not start (Roles::ServerRunner#run_server,
    # before the port is bound; the worker and feeds roles do not ask):
    # with cybertrain/feeds, a WebSocket subscription without on_message.
    # "" when there is none.
    # @param config [Config]
    # @return [String]
    def server_problem(config)
      ""
    end

    # Starts what must run before the server role binds its listener
    # (Roles::ServerRunner#run_server, before Server#start): with
    # cybertrain/streams, the stream poller, whose start position must come
    # before any subscription. #stop_feature stops it.
    # @param config [Config]
    # @return [nil]
    def start_feature_early(config)
      nil
    end

    # Starts the subsystem's threads in the server role, after the listener
    # is bound and the banner printed (Roles::ServerRunner#run_server).
    # @param config [Config]
    # @return [nil]
    def start_feature(config)
      nil
    end

    # Stops what #start_feature started; a no-op for what never started
    # (the server role's ensure calls it also when a start raised).
    # @return [nil]
    def stop_feature
      nil
    end

    # Asks the subsystem to start stopping: flags only, since the server
    # role's TERM trap calls it (Spinel runs a trap block inside its C
    # signal handler).
    # @return [nil]
    def request_stop_feature
      nil
    end

    # Whether the subsystem has failed for good, so a role waiting for a
    # stop should end (Roles.wait_stop).
    # @return [Boolean]
    def feature_failed?
      false
    end

    # The `/up` answer's text when the subsystem is unhealthy
    # (HealthCheck.problem, after the database check); "" when healthy.
    # The arguments are the health check's settings (Config#health_*).
    # @param now [Integer] epoch seconds
    # @param worker_stale [Integer] Config#health_worker_stale
    # @param feeds [Boolean] Config#health_feeds
    # @param feed_stale [Integer] Config#health_feed_stale
    # @return [String]
    def health_problem(now, worker_stale, feeds, feed_stale)
      ""
    end

    # The middleware of the subsystem's endpoint, wrapped around `app` at
    # its place in Application#build_stack (after HealthCheck, before the
    # session: with cybertrain/streams, Stream::Endpoint at
    # Config#stream_path); nil to add none.
    # @param app [Object] the stack so far (a Middleware or the router)
    # @param config [Config]
    # @return [Middleware, nil]
    def feature_middleware(app, config)
      nil
    end

    # Answers a controller's rate_limit callback (Controller#run_one, for
    # a callback whose limit_id is not -1): with cybertrain/rate_limit,
    # counts the request and answers for the action past the limit.
    # @param controller [Controller]
    # @param limit_id [Integer] the limit's index in RateLimit.all
    # @return [nil]
    def run_controller_limit(controller, limit_id)
      nil
    end

    # Runs a command word of the binary (Main.run, after the built-in
    # words): its exit status, or -1 when the word is not this subsystem's.
    # The other arguments are Main.run's, to build an Application.
    # @param word [String] argv[0]
    # @param args [Array<String>] the words after it
    # @param name [String] the binary's name
    # @param router [Router]
    # @param url_resolver [Proc]
    # @param views [Object] Main.run's views
    # @return [Integer]
    def run_feature_command(word, args, name, router, url_resolver, views)
      -1
    end

    # The `help` lines of the subsystem's commands for one place of the
    # usage text: "roles" (after the server line) or "commands" (after the
    # db lines). "" for none.
    # @param name [String] the binary's name
    # @param slot [String]
    # @return [String]
    def feature_usage(name, slot)
      ""
    end

    # Whether the template helper dispatch should hand the helper `name`
    # to #feature_helper (after its own arms).
    # @param name [String]
    # @return [Boolean]
    def feature_helper?(name)
      false
    end

    # A template helper of the subsystem, called with the template helper
    # dispatch's arguments (Template::Helpers#helper_call, after its own
    # arms) when #feature_helper? answered true. Its value is what a helper
    # arm answers: with cybertrain/streams a SafeString
    # (turbo_stream_from), a String (signed_stream_name,
    # stream_source_path) or a Template::TurboStreamBuilder (turbo_stream).
    # The base raises as an undefined helper does
    # (Helpers#app_helper_call), so it adds no type of its own.
    # @return [Object]
    def feature_helper(helpers, name, args, kwargs, block, interp, env)
      raise RuntimeError, "undefined helper '#{name}'"
    end

    # The scheduler task name of the subsystem's periodic work; "" for none.
    # @return [String]
    def periodic_name
      ""
    end

    # Seconds between two runs of #periodic; 0 for none.
    # @return [Integer]
    def periodic_interval
      0
    end

    # The periodic work, run by the scheduler (when a feature that runs
    # periodic work, jobs, is loaded) through Features.run_periodic.
    # @param now [Integer] epoch seconds (a feature with its own clock may
    #   read that instead)
    # @return [nil]
    def periodic(now)
      nil
    end

    # Whether this feature runs the periodic work of features (the jobs
    # feature: its scheduler). A feature with a #periodic does it itself
    # when no loaded feature answers true.
    # @return [Boolean]
    def schedules_periodic?
      false
    end

    # Takes on the periodic work of the feature at `index` in Features
    # (named `task_name`, every `interval` seconds); a no-op when it is
    # already taken on, so it may be called more than once.
    # @param index [Integer]
    # @param task_name [String]
    # @param interval [Integer] at least 1
    # @return [nil]
    def schedule_periodic(index, task_name, interval)
      nil
    end
  end

  # The registered features, and each hook called on each of them in
  # registration order.
  # @api private
  module Features
    # A constant, which Spinel roots for the collector (NOTES rule 64),
    # seeded with the element type and emptied (rule 9).
    ALL = Array.new(0) { Feature.new }

    # Adds `feature` unless one of its class is registered (a second
    # require of a feature file registers nothing), then lets the features
    # that run periodic work take on every feature's.
    # @param feature [Feature]
    # @return [Boolean] whether it was added
    def self.register_feature(feature)
      name = feature.class.name
      i = 0
      while i < ALL.size
        return false if ALL[i].class.name == name

        i += 1
      end
      ALL << feature
      schedule_all_periodic
      true
    end

    # @return [Integer]
    def self.feature_count
      ALL.size
    end

    # Each registered feature's name, in registration order.
    # @return [Array<String>]
    def self.feature_names
      out = Array.new(0) { "" }
      i = 0
      while i < ALL.size
        out << ALL[i].feature_name
        i += 1
      end
      out
    end

    # Whether a feature named `name` is registered.
    # @param name [String]
    # @return [Boolean]
    def self.feature_loaded?(name)
      i = 0
      while i < ALL.size
        return true if ALL[i].feature_name == name

        i += 1
      end
      false
    end

    # The first feature's boot problem; "" when none has one.
    # @param config [Config]
    # @return [String]
    def self.boot_problem(config)
      i = 0
      while i < ALL.size
        problem = ALL[i].boot_problem(config)
        return problem unless problem.empty?

        i += 1
      end
      ""
    end

    # @param config [Config]
    # @return [nil]
    def self.start_features(config)
      i = 0
      while i < ALL.size
        ALL[i].start_feature(config)
        i += 1
      end
      nil
    end

    # @return [nil]
    def self.stop_features
      i = 0
      while i < ALL.size
        ALL[i].stop_feature
        i += 1
      end
      nil
    end

    # Flags only: a signal handler calls it.
    # @return [nil]
    def self.request_stop_features
      i = 0
      while i < ALL.size
        ALL[i].request_stop_feature
        i += 1
      end
      nil
    end

    # @return [Boolean]
    def self.any_failed?
      i = 0
      while i < ALL.size
        return true if ALL[i].feature_failed?

        i += 1
      end
      false
    end

    # The first feature's health problem; "" when all are healthy.
    # @return [String]
    def self.health_problem(now, worker_stale, feeds, feed_stale)
      i = 0
      while i < ALL.size
        problem = ALL[i].health_problem(now, worker_stale, feeds, feed_stale)
        return problem unless problem.empty?

        i += 1
      end
      ""
    end

    # The first feature's server problem; "" when none has one.
    # @param config [Config]
    # @return [String]
    def self.server_problem(config)
      i = 0
      while i < ALL.size
        problem = ALL[i].server_problem(config)
        return problem unless problem.empty?

        i += 1
      end
      ""
    end

    # @param config [Config]
    # @return [nil]
    def self.start_features_early(config)
      i = 0
      while i < ALL.size
        ALL[i].start_feature_early(config)
        i += 1
      end
      nil
    end

    # `app` wrapped in each feature's endpoint middleware, in registration
    # order (the last registered outermost); `app` itself when none adds
    # one.
    # @param app [Object] a Middleware or the router
    # @param config [Config]
    # @return [Object]
    def self.wrap_endpoints(app, config)
      out = app
      i = 0
      while i < ALL.size
        wrapped = ALL[i].feature_middleware(out, config)
        out = wrapped unless wrapped.nil?
        i += 1
      end
      out
    end

    # A rate_limit callback of `controller` (Controller#run_one).
    # @param controller [Controller]
    # @param limit_id [Integer]
    # @return [nil]
    def self.run_controller_limit(controller, limit_id)
      i = 0
      while i < ALL.size
        ALL[i].run_controller_limit(controller, limit_id)
        i += 1
      end
      nil
    end

    # The exit status of the first feature that takes the command word;
    # -1 when none does.
    # @return [Integer]
    def self.command_status(word, args, name, router, url_resolver, views)
      i = 0
      while i < ALL.size
        code = ALL[i].run_feature_command(word, args, name, router, url_resolver, views)
        return code if code >= 0

        i += 1
      end
      -1
    end

    # Every feature's help lines for `slot`, in registration order.
    # @return [String]
    def self.usage_text(name, slot)
      out = +""
      i = 0
      while i < ALL.size
        out << ALL[i].feature_usage(name, slot)
        i += 1
      end
      out
    end

    # The index of the feature that takes the template helper `name`, -1
    # when none does (an Integer rather than a nullable Feature: NOTES
    # rules 11/56).
    # @return [Integer]
    def self.helper_index(name)
      i = 0
      while i < ALL.size
        return i if ALL[i].feature_helper?(name)

        i += 1
      end
      -1
    end

    # The template helper `name` of the feature at `index`
    # (Features.helper_index), with the helper dispatch's arguments.
    # @return [Object]
    def self.call_helper(index, helpers, name, args, kwargs, block, interp, env)
      ALL[index].feature_helper(helpers, name, args, kwargs, block, interp, env)
    end

    # Whether a loaded feature runs the periodic work of features.
    # @return [Boolean]
    def self.periodic_scheduler?
      i = 0
      while i < ALL.size
        return true if ALL[i].schedules_periodic?

        i += 1
      end
      false
    end

    # Offers the periodic work of every feature that has some to every
    # feature (each takes it on once, or ignores it). Features.register_feature
    # calls it, so the requires may come in any order.
    # @return [nil]
    def self.schedule_all_periodic
      i = 0
      while i < ALL.size
        interval = ALL[i].periodic_interval
        if interval > 0
          task_name = ALL[i].periodic_name
          j = 0
          while j < ALL.size
            ALL[j].schedule_periodic(i, task_name, interval)
            j += 1
          end
        end
        i += 1
      end
      nil
    end

    # What a stored scheduler block calls: the hook is called here, on the
    # Array element, not through a receiver the block captured (NOTES
    # rules 88 and 101).
    # @param index [Integer] the feature's place in Features
    # @param now [Integer] epoch seconds
    # @return [nil]
    def self.run_periodic(index, now)
      ALL[index].periodic(now)
      nil
    end
  end
end
