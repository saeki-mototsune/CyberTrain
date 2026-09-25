require "cybertrain/config"
require "cybertrain/logger"
require "cybertrain/middleware"
require "cybertrain/router"
require "cybertrain/middleware/request_logger"
require "cybertrain/middleware/static"
require "cybertrain/middleware/method_override"
require "cybertrain/middleware/session_store"
require "cybertrain/middleware/csrf_protection"
require "cybertrain/http/server"
require "cybertrain/db"
require "cybertrain/views"
require "cybertrain/dev"

module Cybertrain
  # The booted application: config, database, views and the middleware
  # stack in front of the generated router. bin/server.rb builds one:
  #
  #   module Gen::Routes
  #     def self.url_resolver = ->(name, args) { path_for(name, args) }
  #   end
  #
  #   app = Cybertrain::Application.new(
  #     router: Gen::Routes.build(Cybertrain::Router.new),
  #     url_resolver: Gen::Routes.url_resolver
  #   )
  #   app.run
  #
  # Do NOT write the resolver as a lambda literal in the keyword position
  # (`url_resolver: ->(name, args) { ... }`), nor pass a local holding one:
  # Spinel 2026.09.12 does not mark a lambda passed as a keyword argument as
  # escaping, so its parameters keep the Integer default and every path
  # helper receives a garbage route name (e.g. 4295868465 instead of
  # "notes_path") while CRuby works. A method-returned lambda (as above), a
  # positional argument, &block or **{...} all compile correctly.
  class Application
    attr_reader :config, :router

    def initialize(router:, url_resolver:, config: Cybertrain.config)
      @router = router
      @url_resolver = url_resolver
      @config = config
      @stack = nil
      @server = nil
      @rebuilder = nil
      @restart_requested = false
      @serving = false
    end

    # RequestLogger (unless log_level :none) -> Static (if static_files) ->
    # MethodOverride -> SessionStore -> CsrfProtection (if csrf) -> router.
    # Built on first use, after boot has resolved the session secret.
    def stack
      built = @stack
      if built.nil?
        built = build_stack
        @stack = built
      end
      built
    end

    def boot
      c = @config
      c.resolve_secret!
      DB.connect(c.database_path, size: c.pool_size) unless DB.connected?
      Views.configure(c.views_root, cache: !c.development?)
      Views.url_resolver = @url_resolver
      Views.layout_name = c.layout
      Cybertrain.logger.level = c.log_level == :none ? :error : c.log_level
      self
    end

    # Runs one request through the stack (what Test::Client calls).
    def call(ctx)
      stack.call(ctx)
      nil
    end

    def server
      built = @server
      if built.nil?
        built = Server.new(front_app, host: @config.host, port: @config.port)
        @server = built
      end
      built
    end

    # Boots and serves until SIGTERM.
    def run
      boot
      serve
    end

    # Starts the server and blocks until it is stopped. SPINEL_WORKERS must
    # be set before the first Thread.new starts the scheduler (NOTES rule 22).
    # A port given as the first argument wins over the config: that is how
    # the development loop hands its port to the binary it execs.
    def serve
      ENV["SPINEL_WORKERS"] = @config.workers.to_s
      port = Application.port_argument(ARGV)
      @config.port = port if port > 0
      if @config.development?
        serve_development(Dev::Rebuilder.new(Dir.pwd))
      else
        srv = server
        trap("TERM") { srv.stop }
        srv.run
      end
      nil
    end

    # The development loop (docs/design.md D12): requests go through
    # Dev::ErrorPage; a change under Dev::WATCHED rebuilds the server, and
    # a successful build stops serving and execs the new binary on the same
    # port with the same PID. A failed build keeps the old code serving and
    # shows the compiler output.
    #
    # The restart runs in ordinary thread context, never inside a signal
    # handler: Spinel calls a trap block straight from its C signal handler
    # (sp_sig_c_handler), where Thread#join, allocation, IO and execv are
    # not async-signal-safe. A successful rebuild (on the watcher thread)
    # and an external `kill -HUP` both only set a flag; the restart monitor
    # thread stops the server, and once Server#run returns the main thread
    # execs the new binary.
    #
    # Known limitation: the exec'd process takes a fresh watcher baseline,
    # so a source edit saved during the successful build (after gen ran)
    # is only picked up by the next change.
    def serve_development(rebuilder)
      @rebuilder = rebuilder
      srv = server
      trap("TERM") { srv.stop }
      trap("HUP") { request_restart }
      watcher = Dev::Watcher.new(Dev::WATCHED, 0.5, ["gen/"])
      watcher.start { |paths| rebuild_after_change(rebuilder, paths) }
      @serving = true
      spawn_restart_monitor(srv)
      srv.run
      @serving = false
      exec_new_build(srv, rebuilder) if @restart_requested
      nil
    end

    # What the SIGHUP handler does: nothing but set a flag.
    def request_restart
      @restart_requested = true
      nil
    end

    # The port number in argv[0], or 0 when there is none.
    def self.port_argument(argv)
      return 0 if argv.empty?

      arg = argv[0]
      return 0 if arg.empty? || arg.size > 5 || !arg.bytes.all? { |b| b >= 48 && b <= 57 }

      port = arg.to_i
      port <= 65535 ? port : 0
    end

    private

    # The stack the server runs: wrapped in Dev::ErrorPage in development.
    def front_app
      app = stack
      rebuilder = @rebuilder
      app = Dev::ErrorPage.new(app, rebuilder) unless rebuilder.nil?
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
    # (SIGTERM). It sleeps before its first check so that Server#run has
    # started the accept thread by the time it calls Server#stop.
    def monitor_restart(srv)
      while @serving
        sleep 0.2
        break if @restart_requested
      end
      srv.stop if @serving && @restart_requested
      nil
    end

    # On the main thread, after Server#run has returned: the listener is
    # closed, so the new process can bind the port again.
    def exec_new_build(srv, rebuilder)
      binary = rebuilder.binary_path
      STDOUT.flush # exec discards whatever the log has not written yet
      Dev::Reexec.exec_self(binary, srv.port.to_s)
      Cybertrain.logger.error("could not exec #{binary}")
      exit(1)
    end

    def build_stack
      c = @config
      app = @router
      app = CsrfProtection.new(app) if c.csrf
      app = SessionStore.new(app, secret: c.resolve_secret!, cookie_name: c.session_cookie_name,
                                  max_age: c.session_max_age)
      app = MethodOverride.new(app)
      app = Static.new(app, c.public_root) if c.static_files
      app = RequestLogger.new(app) unless c.log_level == :none
      app
    end
  end
end
