require "cybertrain/app_name"
require "cybertrain/config"
require "cybertrain/version"
require "cybertrain/logger"
require "cybertrain/middleware"
require "cybertrain/router"
require "cybertrain/middleware/request_logger"
require "cybertrain/middleware/static"
require "cybertrain/middleware/method_override"
require "cybertrain/middleware/session_store"
require "cybertrain/middleware/csrf_protection"
require "cybertrain/middleware/error_pages"
require "cybertrain/context_handler"
require "cybertrain/http/server"
require "cybertrain/db"
require "cybertrain/views"
require "cybertrain/dev"

module Cybertrain
  # The booted application: config, database, views and the middleware
  # stack in front of the generated router. bin/<name>.rb builds one and
  # hands it Cybertrain::Main's argv:
  #
  #   module Gen::Routes
  #     def self.url_resolver = ->(name, args) { path_for(name, args) }
  #   end
  #
  #   app = Cybertrain::Application.new(
  #     router: Gen::Routes.build(Cybertrain::Router.new),
  #     url_resolver: Gen::Routes.url_resolver,
  #     views: Gen::Views::SOURCES,
  #     name: "<name>"
  #   )
  #   app.run(argv)
  #
  # `views` is the table `spin run gen -- --embed-views` writes to
  # gen/views.rb; production refuses to boot when it is empty
  # (.embedded_views_missing?). `name` is the `spin build` target and the
  # binary (build/bin/<name>) the development loop rebuilds and execs.
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

    def initialize(router:, url_resolver:, views: Application.no_views, name: "server", config: Cybertrain.config)
      @router = router
      @url_resolver = url_resolver
      @views = views
      # Not checked here: only the development Rebuilder uses the name (it is
      # validated in Dev::Rebuilder#initialize), so a production boot neither
      # pays nor fails for it.
      @name = name
      @config = config
      @stack = nil
      @server = nil
      @rebuilder = nil
      @restart_requested = false
      @serving = false
    end

    # A typed empty table (spikes/NOTES.md rule 9): the default for a
    # binary built without `--embed-views`.
    def self.no_views
      none = { "" => "" }
      none.delete("")
      none
    end

    # Production renders only embedded views (gen/views.rb written by
    # `spin run gen -- --embed-views`); a plain build has an empty table.
    def self.embedded_views_missing?(config, views)
      config.production? && views.empty?
    end

    # ErrorPages (in production) -> RequestLogger (unless log_level :none) ->
    # Static (if static_files) -> MethodOverride -> SessionStore ->
    # CsrfProtection (if csrf) -> router. Built on first use, after boot has
    # resolved the session secret.
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
      if Application.embedded_views_missing?(c, @views)
        puts "error: views are not embedded in this binary; build with `cybertrain build` (or run with CYBERTRAIN_ENV=development)"
        STDOUT.flush
        exit(1)
      end
      # config/app.rb has run by now, so the environment variable and
      # `c.session_same_site = ...` are checked together.
      same_site_error = c.session_same_site_error
      unless same_site_error.empty?
        puts "error: #{same_site_error}"
        STDOUT.flush
        exit(1)
      end
      c.resolve_secret!
      DB.connect(c.database_path, size: c.pool_size) unless DB.connected?
      if c.production?
        Views.configure_embedded(@views, max_render_depth: c.max_render_depth)
      else
        Views.configure(c.views_root, cache: !c.development?, max_render_depth: c.max_render_depth)
      end
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
        built = Server.new(ContextHandler.new(front_app), host: @config.host, port: @config.port)
        @server = built
      end
      built
    end

    # Boots and serves until SIGTERM. argv: [] or ["<port>"] (Main passes
    # what follows the `server` word; the dev loop's execv passes the port).
    def run(argv)
      boot
      serve(argv)
    end

    # Starts the server and blocks until it is stopped. SPINEL_WORKERS must
    # be set before the first Thread.new starts the scheduler (NOTES rule 22).
    # A port given as the first argument wins over the config: that is how
    # the development loop hands its port to the binary it execs.
    # A port that cannot be bound (Server raises PortInUse, for a busy port or
    # a privileged one) is reported on STDOUT in place of the boot banner (the
    # listener is bound before it prints) and exits 1: without this the
    # process died with a misleading "Connection refused".
    def serve(argv)
      ENV["SPINEL_WORKERS"] = @config.workers.to_s
      port = Application.port_argument(argv)
      @config.port = port if port > 0
      # The rebuilder must exist before #server builds the stack (front_app
      # wraps it in Dev::ErrorPage only when one is set). Two layers on the
      # name: serve reports a bad one as a boot failure (the `error: ...`
      # line, exit 1, like a busy port), and Rebuilder.new refuses it for
      # direct callers (its contract: ArgumentError). The check here is a
      # plain call, not a `rescue ArgumentError` around the Rebuilder (NOTES
      # rule 32: no new rescue clause in a method that blocks and yields).
      if @config.development?
        problem = Application.name_problem(@name)
        fail_boot(problem) unless problem.empty?
        @rebuilder = Dev::Rebuilder.new(Dir.pwd, @name)
      end
      srv = server
      srv.start # bind first: a PortInUse error must not come after the banner
      print_boot_banner
      if @config.development?
        serve_development(srv)
      else
        trap("TERM") { srv.request_stop }
        srv.wait
      end
      nil
    rescue PortInUse => e
      fail_boot(e.message)
    end

    # "" when name works as the development build target, else the
    # `application name "<name>" <reason>` text serve prints after "error: ".
    # AppName.problem is the one predicate (Rebuilder.new and the CLI ask it
    # too); only a development boot builds, so only it asks. A String on every
    # path (NOTES rules 10/34).
    def self.name_problem(name)
      reason = AppName.problem(name)
      return "" if reason.empty?

      "application name #{name.inspect} #{reason}"
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
    # thread stops the server, and once Server#wait returns the main thread
    # execs the new binary.
    #
    # Known limitation: the exec'd process takes a fresh watcher baseline,
    # so a source edit saved during the successful build (after gen ran)
    # is only picked up by the next change.
    def serve_development(srv)
      rebuilder = @rebuilder
      trap("TERM") { srv.request_stop }
      trap("HUP") { request_restart }
      watcher = Dev::Watcher.new(Dev::WATCHED, 0.5, ["gen/"], Dev::IGNORED)
      watcher.start { |paths| rebuild_after_change(rebuilder, paths) }
      @serving = true
      spawn_restart_monitor(srv)
      srv.wait
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

    # A boot failure: the message on STDOUT in place of the banner, exit 1.
    def fail_boot(message)
      puts "error: #{message}"
      STDOUT.flush
      exit(1)
      nil
    end

    # Printed once, straight to STDOUT (not through Cybertrain.logger, which
    # a quiet log_level could silence): the same "is it up, and where"
    # message Rails/Puma print on boot. Flushed immediately since Spinel
    # block-buffers a redirected STDOUT until exit (spikes/NOTES.md).
    def print_boot_banner
      c = @config
      puts "=> Booting cybertrain #{Cybertrain::VERSION}"
      puts "=> #{c.env} environment (#{c.workers} worker#{c.workers == 1 ? "" : "s"})"
      puts "=> Watching app/, config/ and db/schema.rb for changes" if c.development?
      puts "* Listening on http://#{c.host}:#{c.port}"
      puts "Use Ctrl-C to stop"
      STDOUT.flush
      nil
    end

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
      Dev::Reexec.exec_self(binary, srv.port.to_s)
      Cybertrain.logger.error("could not exec #{binary}")
      exit(1)
    end

    def build_stack
      c = @config
      app = @router
      app = CsrfProtection.new(app) if c.csrf
      app = SessionStore.new(app, secret: c.resolve_secret!, cookie_name: c.session_cookie_name,
                                  max_age: c.session_max_age, secure: c.session_secure,
                                  same_site: c.session_same_site, partitioned: c.session_partitioned)
      app = MethodOverride.new(app)
      app = Static.new(app, c.public_root) if c.static_files
      app = RequestLogger.new(app) unless c.log_level == :none
      app = ErrorPages.new(app, c.public_root) if c.production?
      app
    end
  end
end
