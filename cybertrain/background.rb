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

      # Asks the service to end. Called once at shutdown, also for a
      # service whose service_start returned false: then it does nothing.
      # @return [nil]
      # @api public
      def service_stop
        nil
      end
    end

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
