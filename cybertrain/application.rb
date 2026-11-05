require "cybertrain/app_name"
require "cybertrain/config"
require "cybertrain/cast"
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
require "cybertrain/middleware/host_authorization"
require "cybertrain/middleware/health_check"
require "cybertrain/context_handler"
require "cybertrain/http/server"
require "cybertrain/db"
require "cybertrain/scheduler"
require "cybertrain/background"
require "cybertrain/views"
require "cybertrain/dev"

module Cybertrain
  # The flag that ends `./<app> worker` and `./<app> feeds`
  # (Application.request_stop_roles sets it; the TERM trap calls that).
  # A module-level ivar, not a class variable (NOTES rules 18/64).
  # @api private
  module RoleStop
    @requested = false

    def self.stop_roles!
      @requested = true
      nil
    end

    def self.resume_roles!
      @requested = false
      nil
    end

    def self.roles_stopped?
      @requested
    end
  end

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
  # positional argument, a block argument or a double-splatted Hash all compile correctly.
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

    # HostAuthorization (in development) -> ErrorPages (in production) ->
    # RequestLogger (unless log_level :none) ->
    # HealthCheck (unless health_path is "") -> Static (if static_files) -> MethodOverride -> SessionStore ->
    # CsrfProtection (if csrf; paths under csrf_exempt_prefixes pass it) ->
    # router. Built on first use, after boot has resolved the session secret.
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
        fail_boot("views are not embedded in this binary; build with `cybertrain build` (or run with CYBERTRAIN_ENV=development)")
      end
      # config/app.rb has run by now, so the environment variable and
      # `c.session_same_site = ...` are checked together.
      same_site_error = c.session_same_site_error
      fail_boot(same_site_error) unless same_site_error.empty?
      prefixes_error = c.csrf_exempt_prefixes_error
      fail_boot(prefixes_error) unless prefixes_error.empty?
      body_bytes_error = c.max_body_bytes_error
      fail_boot(body_bytes_error) unless body_bytes_error.empty?
      upload_error = c.upload_limits_error
      fail_boot(upload_error) unless upload_error.empty?
      scheduler_error = c.scheduler_error
      fail_boot(scheduler_error) unless scheduler_error.empty?
      max_page_error = c.max_page_error
      fail_boot(max_page_error) unless max_page_error.empty?
      proxies_error = c.trusted_proxies_error
      fail_boot(proxies_error) unless proxies_error.empty?
      health_error = c.health_error
      fail_boot(health_error) unless health_error.empty?
      c.resolve_secret!
      DB.connect(c.database_path, size: c.pool_size) unless DB.connected?
      if c.production?
        Views.configure_embedded(@views, max_render_depth: c.max_render_depth)
      else
        Views.configure(c.views_root, cache: !c.development?, max_render_depth: c.max_render_depth)
      end
      Views.url_resolver = @url_resolver
      Views.layout_name = c.layout
      # Module-level settings, like Views': the parser and the blob store are
      # reached from places that have no Config. The upload directory is made
      # by the first write, not here, so a read-only deploy still boots.
      Multipart.configure(c.max_upload_bytes, c.max_multipart_parts)
      BlobStore.root = c.upload_root
      Params.max_page = c.max_page
      Request.trusted_proxy = c.trusted_proxy
      Request.trusted_proxies = c.trusted_proxies
      ParameterFilter.names = c.filter_parameters
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
        built = Server.new(ContextHandler.new(front_app), host: @config.host, port: @config.port,
                                                          max_body_bytes: @config.max_body_bytes)
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
      ENV["SPINEL_WORKERS"] = Application.spinel_workers_for(@config).to_s
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
      # A service that would refuse to start (a WebSocket subscription
      # without on_message) fails the boot here, before the port is bound,
      # not with an exception after the banner.
      service_problem = Background.boot_problem(@config)
      fail_boot(service_problem) unless service_problem.empty?
      srv = server
      srv.start # bind first: a PortInUse error must not come after the banner
      print_boot_banner
      # After boot connected the database and SPINEL_WORKERS is set; only
      # here, so `migrate`, `db` and Main.command never start it.
      Scheduler.start!(@config)
      Job.start!(@config) if @config.worker
      # Services files like cybertrain/websocket registered when required.
      Background.start_all(@config)
      if @config.development?
        serve_development(srv)
      else
        # Flags only (safe in a trap): the job threads stop claiming while
        # the requests drain, so Job.stop! waits out only what is left of
        # its job_drain_timeout, inside systemd's TimeoutStopSec.
        trap("TERM") do
          srv.request_stop
          Job.request_stop
        end
        srv.wait
      end
      Job.stop!
      Scheduler.stop!
      Background.stop_all
      nil
    rescue PortInUse => e
      fail_boot(e.message)
    end

    # `./<app> worker` (Main.run): boots (the config checks, the database),
    # prints a banner, starts the scheduler (lease-gated: several workers
    # may share the database) and the job threads, and runs until SIGTERM
    # (or Application.request_stop_roles), then stops the job threads (they
    # finish their jobs, for at most Config#job_drain_timeout seconds) and
    # the scheduler. No port, no HTTP. Config#worker is set: in this role
    # it is what the process is for.
    # @param argv [Array<String>] what follows `worker`; must be empty
    # @return [Integer] the exit status
    # @api public
    def run_worker(argv)
      unless argv.empty?
        puts "error: worker takes no arguments (got #{argv.join(" ")})"
        STDOUT.flush
        return 1
      end
      # Before boot: a stop asked for while booting is kept.
      Application.reset_roles_stop
      @config.worker = true
      boot
      ENV["SPINEL_WORKERS"] = @config.workers.to_s
      threads = @config.job_threads
      tasks = Scheduler::TASKS.size
      jobs = Job.handlers? ? "#{threads} job thread#{threads == 1 ? "" : "s"}" : "no job handler"
      print_role_banner("worker: #{jobs}, #{tasks} scheduled task#{tasks == 1 ? "" : "s"}")
      trap("TERM") { Application.request_stop_roles }
      Scheduler.start!(@config)
      Job.start!(@config)
      Application.wait_roles_stop
      Job.stop!
      Scheduler.stop!
      0
    end

    # `./<app> feeds [NAME...]` (Main.run): boots, checks the names against
    # the registered feeds (an unknown one is an error that lists them),
    # starts the WebSocket subscriptions (all of them, or the named ones:
    # Background.start_only) and runs until SIGTERM, then stops them. No
    # port, no jobs, no scheduler. With no subscription registered it says
    # so and returns 0.
    # @param names [Array<String>] the feeds to run; empty for all
    # @return [Integer] the exit status
    # @api public
    def run_feeds(names)
      Application.reset_roles_stop
      @config.worker = true
      boot
      unknown = Background.unknown_feed(names)
      return role_error(unknown) unless unknown.empty?

      problem = Background.boot_problem(@config)
      return role_error(problem) unless problem.empty?

      known = Background.feed_names
      ENV["SPINEL_WORKERS"] = @config.workers.to_s
      if known.empty?
        print_role_banner("feeds: no WebSocket subscription is registered; nothing to run")
        return 0
      end
      print_role_banner("feeds: #{(names.empty? ? known : names).join(", ")}")
      trap("TERM") { Application.request_stop_roles }
      Background.start_only(@config, names)
      Application.wait_roles_stop
      Background.stop_all
      0
    end

    # Ends a run_worker or run_feeds: sets a flag the waiting main thread
    # sees within 0.1 s (and nothing else, so the TERM trap can call it:
    # see serve_development). Also callable from another thread, as tests
    # do.
    # @return [nil]
    # @api public
    def request_stop_roles
      Application.request_stop_roles
    end

    # The same as {#request_stop_roles}, for code (a test, a trap) that
    # does not hold the Application instance Main.run made.
    # @return [nil]
    # @api public
    def self.request_stop_roles
      RoleStop.stop_roles!
    end

    def self.reset_roles_stop
      RoleStop.resume_roles!
    end

    def self.wait_roles_stop
      sleep 0.1 until RoleStop.roles_stopped?
      nil
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
      trap("TERM") do
        srv.request_stop
        Job.request_stop
      end
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

    # What SPINEL_WORKERS must say for `workers` threads to serve requests in
    # parallel. Spinel counts main among its N workers and runs the other
    # threads on N-1 helpers, and main only waits in #serve, so N = workers
    # leaves workers - 1 for the requests (2 gave one core's worth on two:
    # spikes/NOTES.md rule 22). 1 stays 1: main runs every thread itself.
    def self.spinel_workers(workers)
      workers > 1 ? workers + 1 : 1
    end

    # How many request workers #serve runs: config.workers, except that
    # development always serves on one. Its engine (cache: false) re-parses
    # an edited template on the request that renders it and writes the
    # parsed-template cache there; two workers could write it at once
    # (Spinel has no GVL), and a lock on every render stalls requests for
    # seconds (spikes/NOTES.md rule 57). Production and test engines are
    # only read once booted. config.workers keeps the requested count, which
    # the banner reports and #exec_new_build hands the next process.
    def self.serving_workers(config)
      config.development? ? 1 : config.workers
    end

    # What #serve sets SPINEL_WORKERS to before the first thread starts.
    def self.spinel_workers_for(config)
      Application.spinel_workers(Application.serving_workers(config))
    end

    # The banner's environment line, naming the worker count #serve uses
    # and, in development, a configured count above 1 that it ignored
    # (named as `workers`: it may come from SPINEL_WORKERS or from
    # config/app.rb).
    def self.environment_banner(config)
      n = Application.serving_workers(config)
      line = "=> #{config.env} environment (#{n} worker#{n == 1 ? "" : "s"}"
      line += "; workers = #{config.workers} is ignored in development" if n != config.workers && config.workers > 1
      "#{line})"
    end

    # The port number in argv[0], or 0 when there is none.
    def self.port_argument(argv)
      return 0 if argv.empty?

      arg = argv[0]
      # Cast.digits? is true for "", hence the empty check before it.
      return 0 if arg.empty? || arg.size > 5 || !Cast.digits?(arg)

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

    # The banner of a role without a port (worker, feeds): the environment
    # and what the process runs.
    def print_role_banner(what)
      c = @config
      puts "=> #{c.env} environment"
      settings = c.settings_summary
      puts "=> Settings: #{settings}" unless settings.empty?
      puts "=> #{what}"
      STDOUT.flush
      nil
    end

    # A role's refusal to start: `error: MESSAGE`, exit status 1 (returned,
    # not exit(1): Main.run's caller exits with it).
    def role_error(message)
      puts "error: #{message}"
      STDOUT.flush
      1
    end

    # The stack the server runs: diagnostics must stay inside hostname
    # authorization too, including when #stack was built before serving.
    def front_app
      app = stack
      rebuilder = @rebuilder
      unless rebuilder.nil?
        app = Dev::ErrorPage.new(app, rebuilder)
        app = HostAuthorization.new(app, @config.allowed_hosts) if @config.development?
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
      # #serve gave Spinel, or every rebuild would add a worker.
      ENV["SPINEL_WORKERS"] = @config.workers.to_s
      Dev::Reexec.exec_self(binary, srv.port.to_s)
      Cybertrain.logger.error("could not exec #{binary}")
      exit(1)
    end

    def build_stack
      c = @config
      app = @router
      app = CsrfProtection.new(app, c.csrf_exempt_prefixes) if c.csrf
      app = SessionStore.new(app, secret: c.resolve_secret!, cookie_name: c.session_cookie_name,
                                  max_age: c.session_max_age, secure: c.session_secure,
                                  same_site: c.session_same_site, partitioned: c.session_partitioned,
                                  absolute_max_age: c.session_absolute_max_age)
      app = MethodOverride.new(app)
      app = Static.new(app, c.public_root) if c.static_files
      # Before Static and the session: no public/ file shadows it, and it
      # sets no cookie. Inside RequestLogger, so polls are logged as usual.
      app = HealthCheck.new(app, c.health_path, c.health_worker_stale) unless c.health_path.empty?
      app = RequestLogger.new(app) unless c.log_level == :none
      app = ErrorPages.new(app, c.public_root) if c.production?
      app = HostAuthorization.new(app, c.allowed_hosts) if c.development?
      app
    end
  end
end
