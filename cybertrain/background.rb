require "cybertrain/config"

module Cybertrain
  # Cybertrain::Background -- services Application#serve starts and stops
  # without application.rb requiring them.
  #
  # A file that runs something long-lived beside the server (the WebSocket
  # client's subscriptions, cybertrain/websocket.rb) subclasses {Service}
  # and registers an instance when it is required:
  #
  #   class FeedService < Cybertrain::Background::Service
  #     def service_name = "feeds"
  #     def service_start(config) = Feeds.start!(config)
  #     def service_stop = Feeds.stop!
  #   end
  #   Cybertrain::Background.register(FeedService.new)
  #
  # Application#serve calls {Background.start_all} right after
  # Scheduler.start! (the database is connected, the port bound and
  # `SPINEL_WORKERS` set: spikes/NOTES.md rule 22) and {Background.stop_all}
  # right after Scheduler.stop!. `./<app> migrate`, `db ...`, Main.command
  # and Test::Client never start them. The same pattern as
  # Net.tls_connector: a do-nothing default here, the real one in the file
  # that is required only by the programs that use it (so a program that
  # never opens a WebSocket does not link it, nor libssl).
  # @api public
  module Background
    # A background service: the default does nothing. Subclasses override
    # all three methods. Distinctive names (`service_start`, not `start`):
    # NOTES rules 10/34/62.
    # @api public
    class Service
      # @return [String] for the log and for {Background.register}'s
      #   uniqueness check; non-empty in a subclass
      # @api public
      def service_name
        ""
      end

      # Starts the service (its thread, usually). Called once per serve;
      # it must not block and should not raise.
      # @param config [Config]
      # @return [Boolean] true when it started something
      # @api public
      def service_start(config)
        false
      end

      # Starts only the parts of the service named in `names` (`./<app>
      # feeds NAME...`); all of it when `names` is empty. The default, for a
      # service without named parts, calls {#service_start} when `names` is
      # empty and starts nothing otherwise: `./<app> feeds trades` runs that
      # one feed and nothing else, while a bare `./<app> feeds` runs every
      # service (judgement call).
      # @param config [Config]
      # @param names [Array<String>]
      # @return [Boolean] true when it started something
      # @api public
      def service_start_only(config, names)
        return false unless names.empty?

        service_start(config)
      end

      # The names {#service_start_only} accepts (a feed service's feeds),
      # for `./<app> feeds NAME...` to check its arguments against. The
      # default has none.
      # @return [Array<String>]
      # @api public
      def service_feed_names
        Background::NO_NAMES
      end

      # Asks the service to end. Called once at shutdown, also for a
      # service whose service_start returned false: then it does nothing.
      # @return [nil]
      # @api public
      def service_stop
        nil
      end

      # What would make service_start refuse to start, found before the
      # server binds its port ({Background.boot_problem}), so serve reports
      # it as a boot failure rather than raising after the banner.
      # @return [String] "" when nothing is wrong
      # @api public
      def service_problem
        ""
      end
    end

    # A typed empty list of names (NOTES rule 9), shared and never added to.
    NO_NAMES = Array.new(0) { "" }

    # The registry: a constant, which Spinel roots for the collector (NOTES
    # rule 64), seeded with the base class and emptied (rule 9), so a
    # subclass instance is held and dispatched as a Service.
    SERVICES = Array.new(0) { Service.new }

    # Adds a service for {Background.start_all} to start. Register before
    # the server starts (when the file defining it is required).
    # @param service [Service]
    # @return [nil]
    # @raise [ArgumentError] when a service of the same name is registered
    # @api public
    def self.register(service)
      name = service.service_name
      raise ArgumentError, "Background.register #{name.inspect}: already registered" if service_index(name) >= 0

      SERVICES << service
      nil
    end

    # The index of the service named name, -1 when none (NOTES rules 11/56).
    def self.service_index(name)
      i = 0
      while i < SERVICES.size
        return i if SERVICES[i].service_name == name
        i += 1
      end
      -1
    end

    # The first registered service's {Service#service_problem}, "" when
    # none has one, or when {Config#worker} is off (nothing starts then).
    # Application#serve calls it before binding the port and fails the
    # boot with it.
    # @param config [Config]
    # @return [String]
    # @api public
    def self.boot_problem(config)
      return "" unless config.worker

      i = 0
      while i < SERVICES.size
        problem = SERVICES[i].service_problem
        return problem unless problem.empty?

        i += 1
      end
      ""
    end

    # Starts every registered service, in registration order, unless
    # {Config#worker} is off (`CYBERTRAIN_WORKER=0`: the process that runs
    # the background work is another one).
    # @param config [Config]
    # @return [Integer] how many services' service_start returned true
    # @api public
    def self.start_all(config)
      return 0 unless config.worker

      started = 0
      i = 0
      while i < SERVICES.size
        started += 1 if SERVICES[i].service_start(config)
        i += 1
      end
      started
    end

    # Starts every registered service with {Service#service_start_only}, in
    # registration order: what `./<app> feeds [NAME...]` runs. Unlike
    # {Background.start_all} it ignores {Config#worker}: the role was asked
    # for by name.
    # @param config [Config]
    # @param names [Array<String>] empty for everything
    # @return [Integer] how many services started something
    # @api public
    def self.start_only(config, names)
      started = 0
      i = 0
      while i < SERVICES.size
        started += 1 if SERVICES[i].service_start_only(config, names)
        i += 1
      end
      started
    end

    # Every registered service's {Service#service_feed_names}, in order.
    # @return [Array<String>]
    # @api public
    def self.feed_names
      out = Array.new(0) { "" }
      i = 0
      while i < SERVICES.size
        SERVICES[i].service_feed_names.each { |name| out << name }
        i += 1
      end
      out
    end

    # `unknown feed "NAME" (registered: a, b)` for the first of `names`
    # that no service lists in {Service#service_feed_names}, "" when every
    # one is known.
    # @param names [Array<String>]
    # @return [String]
    # @api public
    def self.unknown_feed(names)
      Background.unknown_name_in(names, feed_names)
    end

    # The unknown_feed text for `names` checked against `known` (shared
    # with WebSocket.unknown_feed).
    # @param names [Array<String>]
    # @param known [Array<String>]
    # @return [String]
    # @api private
    def self.unknown_name_in(names, known)
      i = 0
      while i < names.size
        name = names[i]
        unless known.include?(name)
          listed = known.empty? ? "none" : known.join(", ")
          return "unknown feed #{name.inspect} (registered: #{listed})"
        end
        i += 1
      end
      ""
    end

    # Asks every registered service to end, in registration order.
    # @return [nil]
    # @api public
    def self.stop_all
      i = 0
      while i < SERVICES.size
        SERVICES[i].service_stop
        i += 1
      end
      nil
    end
  end
end
