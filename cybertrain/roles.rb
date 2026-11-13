# Cybertrain::Roles -- how a process is operated, apart from what the
# application is made of (docs/design.md D67). Application assembles the
# configuration and the middleware stack and is the entry for a request;
# one object per role owns the starts, the wait, the stops and the signal
# handlers of that role:
#
#   Roles::ServerRunner   ./<app> server [PORT]   cybertrain/roles/server.rb
#   Roles::WorkerRunner   ./<app> worker          cybertrain/roles/worker.rb
#                         (loaded by cybertrain/jobs, not by the core)
#   Roles::FeedsRunner    ./<app> feeds [NAME...] cybertrain/roles/feeds.rb
#
# This module holds only what the three really share: the stop flag of the
# roles without a port, their banner, and the `error:` line. There is no
# runner base class: the roles share a shape, not code, and a base method
# that calls subclass hooks is what NOTES rules 3 and 88 warn about.
require "cybertrain/config"
require "cybertrain/runtime"
require "cybertrain/background"

module Cybertrain
  # @api private
  module Roles
    # The flag that ends `./<app> worker` and `./<app> feeds`. A
    # module-level ivar, not a class variable (NOTES rules 18/64).
    @stop_requested = false

    # Asks the running worker or feeds role to stop: sets a flag the
    # waiting main thread sees within 0.1 s, and nothing else, so a signal
    # handler may call it (Spinel runs a trap block inside its C handler).
    # @return [nil]
    def self.request_stop
      @stop_requested = true
      nil
    end

    # Before a role boots: a stop asked for while booting is then kept.
    # @return [nil]
    def self.reset_stop
      @stop_requested = false
      nil
    end

    # @return [Boolean]
    def self.stop_requested?
      @stop_requested
    end

    # Waits for a stop, or for a feeds process's supervisor giving up on a
    # feed (Background.feeds_failed?).
    # @return [nil]
    def self.wait_stop
      sleep 0.1 until @stop_requested || Background.feeds_failed?
      nil
    end

    # The banner of a role without a port (worker, feeds): the environment
    # and what the process runs. Straight to STDOUT and flushed (a quiet
    # log_level must not silence it, and Spinel block-buffers a redirected
    # STDOUT until exit).
    # @param config [Config]
    # @param what [String]
    # @return [nil]
    def self.print_banner(config, what)
      puts "=> #{config.env} environment"
      settings = config.settings_summary
      puts "=> Settings: #{settings}" unless settings.empty?
      puts "=> #{what}"
      STDOUT.flush
      nil
    end

    # A role's refusal to start: `error: MESSAGE`, exit status 1 (returned,
    # not exit(1): Main.run's caller exits with it).
    # @param message [String]
    # @return [Integer] 1
    def self.refuse(message)
      puts "error: #{message}"
      STDOUT.flush
      1
    end

    # A boot failure: the message on STDOUT in place of the banner, exit 1.
    # @param message [String]
    # @return [nil]
    def self.fail_boot(message)
      puts "error: #{message}"
      STDOUT.flush
      exit(1)
      nil
    end
  end
end

require "cybertrain/roles/server"
require "cybertrain/roles/feeds"
