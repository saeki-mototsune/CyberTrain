require "cybertrain/app_name"
require "cybertrain/version"
require "cybertrain/logger"
require "cybertrain/middleware"
require "cybertrain/middleware/host_authorization"
require "cybertrain/context_handler"
require "cybertrain/http/server"
require "cybertrain/job"
require "cybertrain/scheduler"
require "cybertrain/background"
require "cybertrain/stream/endpoint"
require "cybertrain/dev"

module Cybertrain
  module Roles
    # `./<app> server [PORT]`: the HTTP server and, with it, everything one
    # process runs by default. The Application has booted before #run is
    # called.
    #
    #   starts   Stream::Poller (when the endpoint is mounted), the
    #            listener, Scheduler, Job (when Config#worker), the
    #            Background services
    #   waits    Server#wait (TERM stops the listener and the job claims)
    #   stops    Job, Scheduler, Background, Stream::Poller
    #
    # In development it is also the whole of D12: the rebuilder, the
    # watcher, the HUP trap, the restart monitor and the execv of the new
    # binary. The rebuild is this role's and no other's, so it lives here.
    # @api private
    class ServerRunner
      # @param config [Config] the Application's
      # @param name [String] the build target the development loop rebuilds
      # @param stack [Middleware] the Application's middleware stack
      def initialize(config, name, stack)
        @config = config
        @name = name
        @stack = stack
        @server = nil
        @rebuilder = nil
        @restart_requested = false
        @serving = false
      end

      # The HTTP server, built on first use (Application#server).
      # @return [Cybertrain::Server]
      def http_server
        built = @server
        if built.nil?
          config = @config
          built = Server.new(ContextHandler.new(front_app), host: config.host, port: config.port,
                                                            max_body_bytes: config.max_body_bytes,
                                                            reuse_port: reuse_port?,
                                                            stream_write_timeout: config.stream_ping_interval)
          @server = built
        end
        built
      end

      # Starts the server and blocks until it is stopped. SPINEL_WORKERS
      # must be set before the first Thread.new starts the scheduler (NOTES
      # rule 22). A port given as the first argument wins over the config:
      # that is how the development loop hands its port to the binary it
      # execs. A port that cannot be bound (Server raises PortInUse, for a
      # busy port or a privileged one) is reported on STDOUT in place of
      # the boot banner (the listener is bound before it prints) and exits
      # 1: without this the process died with a misleading "Connection
      # refused".
      # @param argv [Array<String>] [] or ["<port>"]
      # @return [nil]
      def run_server(argv)
        config = @config
        ENV["SPINEL_WORKERS"] = Application.spinel_workers_for(config).to_s
        port = Application.port_argument(argv)
        config.port = port if port > 0
        # The rebuilder must exist before #http_server builds the stack
        # (front_app wraps it in Dev::ErrorPage only when one is set). Two
        # layers on the name: a bad one is a boot failure here (the
        # `error: ...` line, exit 1, like a busy port), and Rebuilder.new
        # refuses it for direct callers (its contract: ArgumentError). The
        # check here is a plain call, not a `rescue ArgumentError` around
        # the Rebuilder (NOTES rule 32: no new rescue clause in a method
        # that blocks and yields).
        if config.development?
          problem = Application.name_problem(@name)
          Roles.fail_boot(problem) unless problem.empty?
          @rebuilder = Dev::Rebuilder.new(Dir.pwd, @name)
        end
        # A service that would refuse to start (a WebSocket subscription
        # without on_message) fails the boot here, before the port is
        # bound, not with an exception after the banner.
        service_problem = Background.boot_problem(config)
        Roles.fail_boot(service_problem) unless service_problem.empty?
        busy = Runtime.enter_role("server")
        Roles.fail_boot(busy) unless busy.empty?
        srv = http_server
        begin
          # The stream poller before the listener: its start position
          # (MAX(id)) must come before any subscription. Only with the
          # endpoint mounted.
          Stream::Poller.start!(config) unless config.stream_path.empty?
          srv.start # bind first: a PortInUse error must not come after the banner
          print_boot_banner
          # After boot connected the database and SPINEL_WORKERS is set;
          # only here, so `migrate`, `db` and Main.command never start it.
          Scheduler.start!(config)
          Job.start!(config) if config.worker
          # Services files like cybertrain/websocket registered when required.
          Background.start_all(config)
          if config.development?
            serve_development(srv)
          else
            # Flags only (safe in a trap): the job threads stop claiming
            # while the requests drain, so Job.stop! waits out only what is
            # left of its job_drain_timeout, inside systemd's TimeoutStopSec.
            previous_term = trap("TERM") do
              srv.request_stop
              Job.request_stop
            end
            wait_for_stop(srv, previous_term)
          end
        ensure
          # Also when a start above raised (D66): each stop is a no-op for
          # what never started, so nothing this role began outlives it.
          Job.stop!
          Scheduler.stop!
          Background.stop_all
          Stream::Poller.stop!
          Runtime.leave_role
        end
        nil
      rescue PortInUse => e
        Roles.fail_boot(e.message)
      end

      private

      # The development loop (docs/design.md D12): requests go through
      # Dev::ErrorPage; a change under Dev::WATCHED rebuilds the server,
      # and a successful build stops serving and execs the new binary on
      # the same port with the same PID. A failed build keeps the old code
      # serving and shows the compiler output.
      #
      # The restart runs in ordinary thread context, never inside a signal
      # handler: Spinel calls a trap block straight from its C signal
      # handler (sp_sig_c_handler), where Thread#join, allocation, IO and
      # execv are not async-signal-safe. A successful rebuild (on the
      # watcher thread) and an external `kill -HUP` both only set a flag;
      # the restart monitor thread stops the server, and once Server#wait
      # returns the main thread execs the new binary.
      #
      # Known limitation: the exec'd process takes a fresh watcher
      # baseline, so a source edit saved during the successful build (after
      # gen ran) is only picked up by the next change.
      def serve_development(srv)
        rebuilder = @rebuilder
        previous_term = trap("TERM") do
          srv.request_stop
          Job.request_stop
        end
        previous_hup = trap("HUP") { request_restart }
        watcher = Dev::Watcher.new(Dev::WATCHED, 0.5, ["gen/"], Dev::IGNORED)
        watch_and_wait(srv, rebuilder, watcher, previous_term, previous_hup)
      end

      # The development server's lifetime. When it ends without an exec
      # (SIGTERM, or an in-process caller's Server#stop) the watcher is
      # stopped, so a later edit does not rebuild an application nobody
      # serves, and the TERM and HUP handlers the role replaced are given
      # back, as the other roles give theirs back.
      def watch_and_wait(srv, rebuilder, watcher, previous_term, previous_hup)
        watcher.start { |paths| rebuild_after_change(rebuilder, paths) }
        @serving = true
        spawn_restart_monitor(srv)
        srv.wait
        @serving = false
        exec_new_build(srv, rebuilder) if @restart_requested
        nil
      ensure
        @serving = false
        watcher.stop
        trap("TERM", previous_term)
        trap("HUP", previous_hup)
      end

      # The production wait: until the TERM trap (or Server#stop) ends it,
      # then the handler the role replaced is given back, so an in-process
      # caller's own TERM handler works again once the role has returned.
      # @param previous_term [Object] what trap("TERM") answered
      def wait_for_stop(srv, previous_term)
        srv.wait
        nil
      ensure
        trap("TERM", previous_term)
      end

      # What the SIGHUP handler does: nothing but set a flag.
      def request_restart
        @restart_requested = true
        nil
      end

      # Config#reuse_port, except in development: the dev server re-execs
      # itself, and a stray second process on the port would answer with
      # stale code. #http_server builds once, so this warns once.
      def reuse_port?
        return false unless @config.reuse_port
        return true unless @config.development?

        Cybertrain.logger.warn("reuse_port is ignored in development: a second process on the port would answer with stale code")
        false
      end

      # Printed once, straight to STDOUT (not through Cybertrain.logger,
      # which a quiet log_level could silence): the same "is it up, and
      # where" message Rails/Puma print on boot. Flushed immediately since
      # Spinel block-buffers a redirected STDOUT until exit (spikes/NOTES.md).
      def print_boot_banner
        c = @config
        puts "=> Booting cybertrain #{Cybertrain::VERSION}"
        puts Application.environment_banner(c)
        # Application settings (Config#setting_string ...), secrets filtered.
        settings = c.settings_summary
        puts "=> Settings: #{settings}" unless settings.empty?
        puts "=> Watching app/, config/ and db/schema.rb for changes" if c.development?
        puts "* Listening on http://#{c.host}:#{c.port}"
        puts "Use Ctrl-C to stop"
        STDOUT.flush
        nil
      end

      # The stack the server runs: diagnostics must stay inside hostname
      # authorization too, including when the stack was built before
      # serving.
      def front_app
        app = @stack
        rebuilder = @rebuilder
        unless rebuilder.nil?
          app = Dev::ErrorPage.new(app, rebuilder)
          app = HostAuthorization.new(app, @config.checked_hosts, @config.health_path) if @config.development?
        end
        app
      end

      # Runs on the watcher thread. A successful build requests the restart
      # (monitor_restart stops the server, serve_development execs).
      def rebuild_after_change(rebuilder, paths)
        return nil if @restart_requested # the new binary is about to take over

        logger = Cybertrain.logger
        logger.info("Changed #{paths.join(", ")}; rebuilding (log: #{rebuilder.log_path})")
        if rebuilder.rebuild
          logger.info("Build succeeded; restarting")
          request_restart
        elsif rebuilder.last_skipped
          logger.info(rebuilder.last_output)
        else
          logger.error("Build failed; still serving the previous build (see #{rebuilder.log_path})")
        end
        nil
      end

      def spawn_restart_monitor(srv)
        Thread.new { monitor_restart(srv) }
      end

      # The only place the development loop stops the server for a restart:
      # turns request_restart (a rebuild or SIGHUP) into Server#stop within
      # 0.2 s, and ends quietly when the server stops for another reason
      # (SIGTERM).
      def monitor_restart(srv)
        while @serving
          sleep 0.2
          break if @restart_requested
        end
        srv.stop if @serving && @restart_requested
        nil
      end

      # On the main thread, after Server#wait has returned: the listener is
      # closed, so the new process can bind the port again.
      def exec_new_build(srv, rebuilder)
        binary = rebuilder.binary_path
        STDOUT.flush # exec discards whatever the log has not written yet
        # The new process inherits the environment and reads SPINEL_WORKERS
        # as config.workers again: hand it the configured count, not the one
        # #run_server gave Spinel, or every rebuild would add a worker.
        ENV["SPINEL_WORKERS"] = @config.workers.to_s
        Dev::Reexec.exec_self(binary, srv.port.to_s)
        Cybertrain.logger.error("could not exec #{binary}")
        exit(1)
      end
    end
  end
end
