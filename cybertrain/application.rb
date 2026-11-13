require "cybertrain/app_name"
require "cybertrain/assets"
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
require "cybertrain/middleware/ssl_redirect"
require "cybertrain/middleware/content_security_policy_header"
require "cybertrain/context_handler"
require "cybertrain/i18n"
require "cybertrain/http/server"
require "cybertrain/db"
require "cybertrain/feature"
require "cybertrain/views"
require "cybertrain/runtime"
require "cybertrain/dev"

module Cybertrain
  # The booted application: config, database, views and the middleware
  # stack in front of the generated router. bin/<name>.rb builds one and
  # hands it Cybertrain::Main's argv:
  #
  #   module Gen::Routes
  #     def self.url_resolver = ->(name, args, options) { path_for(name, args, options) }
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
  # (`url_resolver: ->(name, args, options) { ... }`), nor pass a local holding one:
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
      @server_runner = nil
      @booted = false
      # True while #apply_boot_settings is writing the shared settings.
      @applying = false
      # The DB.generation of the pool this Application's boot connected,
      # or -1 when the database was connected already (the caller's pool).
      @database_generation = -1
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

    # HostAuthorization (Config#host_check?: development, or CYBERTRAIN_HOSTS
    # set; the health path exempt) -> SslRedirect (if force_ssl) ->
    # ErrorPages (in production) -> RequestLogger (unless log_level :none) ->
    # ContentSecurityPolicyHeader (when config/app.rb or a controller
    # declared a policy) ->
    # Stream::Endpoint (unless stream_path is "") -> HealthCheck (unless
    # health_path is "") -> Static (if static_files) -> MethodOverride -> SessionStore ->
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

    # Boots in three stages (docs/design.md D66): validate (reads only; a
    # problem is `error: ...` and exit 1), acquire (the secret, the
    # database pool), apply (the views, the process-shared settings). An
    # exception in the second or third stage propagates after #abandon_boot
    # has released what this call acquired, so a retry starts from a
    # defined state.
    # @return [Application] self
    # @api public
    def boot
      validate_boot
      before = @database_generation
      completed = false
      begin
        acquire_boot_resources
        apply_boot_settings
        completed = true
      ensure
        # A flag and an ensure, not a rescue: a rescue clause does not see
        # every exception class under Spinel (NOTES rules 33, 61).
        abandon_boot(before) unless completed
      end
      @booted = true
      self
    end

    # Stage 1: every check, before anything is acquired. Nothing here
    # touches the disk or the database (Config#validation_error, D65).
    def validate_boot
      c = @config
      if Application.embedded_views_missing?(c, @views)
        fail_boot("views are not embedded in this binary; build with `cybertrain build` (or run with CYBERTRAIN_ENV=development)")
      end
      # config/app.rb has run by now, so the environment variables and its
      # assignments are checked together.
      problem = c.validation_error
      fail_boot(problem) unless problem.empty?
      # What a loaded subsystem refuses (Feature#boot_problem): with jobs, a
      # cron task's job: kind no Job.handle registered (Scheduler.start!
      # raises the same message; here it is a boot error before the banner).
      feature_problem = Features.boot_problem(c)
      fail_boot(feature_problem) unless feature_problem.empty?
      nil
    end

    # Stage 2: the secret (the one step that may write a file:
    # tmp/secret_key, outside production) and the database pool. The pool
    # is the process's (DB.connect replaces it): a boot connects only when
    # nothing has, and remembers that the pool is then its own to close
    # (#shutdown, #abandon_boot). A pool the caller connected stays the
    # caller's.
    def acquire_boot_resources
      c = @config
      c.resolve_secret!
      unless DB.connected?
        DB.connect(c.database_path, size: c.pool_size)
        @database_generation = DB.generation
      end
      nil
    end

    # Stage 3: the views (production parses every embedded template here;
    # one that does not parse raises) and every other process-shared
    # setting, in one place (D64).
    def apply_boot_settings
      @applying = true
      Application.configure_views(@config, @views, @url_resolver)
      Runtime.apply(@config)
      @applying = false
      nil
    end

    # What a boot that raised leaves behind: no pool of its own (a pool
    # that was connected before this call, by the caller or by an earlier
    # boot of this Application, is not touched), the settings at their
    # defaults if stage 3 had begun writing them (never a half-applied
    # set), and an Application that is not booted.
    # @param before [Integer] @database_generation when #boot was called
    def abandon_boot(before)
      mine = @database_generation
      if mine != before
        DB.disconnect if DB.connected? && DB.generation == mine
        @database_generation = before
      end
      Runtime.reset! if @applying
      @applying = false
      @booted = false
      nil
    end

    # Whether #boot has completed (and #shutdown has not run since).
    # @return [Boolean]
    # @api public
    def booted?
      @booted
    end

    # Ends what #boot began: closes the database pool if this Application's
    # boot connected it (a pool the caller connected, or one connected
    # since, is left open) and marks the Application not booted. The
    # process-shared settings stay as the boot left them until the next
    # boot or Runtime.reset!. Call it after #serve, #run_worker or
    # #run_feeds has returned (they stop their own threads), never while
    # one runs. Scheduler.stop! asks the scheduler to stop without waiting
    # for a task in progress, so an in-process caller that shuts down right
    # after a role returned should let a running Scheduler task finish
    # first: it would find the pool closed (DB::Error). #boot may be called
    # again afterwards.
    # @return [nil]
    # @api public
    def shutdown
      DB.disconnect if @database_generation >= 0 && DB.connected? && DB.generation == @database_generation
      @database_generation = -1
      @booted = false
      # A later boot may serve on another port or with a changed config: the
      # runner (and the HTTP server it built) is this lifecycle's.
      @server_runner = nil
      nil
    end

    # Runs one request through the stack (what Test::Client calls).
    # Starts at the default locale (I18n.locale is the thread's, and a
    # keep-alive connection serves its requests on one thread), so a route
    # miss or an error page never sees the previous request's locale.
    def call(ctx)
      I18n.locale = nil
      stack.call(ctx)
      nil
    end

    # The HTTP server the `server` role runs (Roles::ServerRunner builds it
    # on first use, from this Application's config and stack).
    # @return [Cybertrain::Server]
    def server
      server_runner.http_server
    end

    # The object that operates the `server` role for this Application
    # (docs/design.md D67); built on first use, after which #stack is fixed.
    # @api private
    def server_runner
      built = @server_runner
      if built.nil?
        built = Roles::ServerRunner.new(@config, @name, stack)
        @server_runner = built
      end
      built
    end

    # Boots and serves until SIGTERM. argv: [] or ["<port>"] (Main passes
    # what follows the `server` word; the dev loop's execv passes the port).
    def run(argv)
      boot
      serve(argv)
    end

    # Serves until SIGTERM: Roles::ServerRunner#run_server (the listener,
    # the stream poller, the scheduler, the job threads, the background
    # services; in development the rebuild loop). Call #boot first, or use
    # #run. argv: [] or ["<port>"]; a port given there wins over the config.
    # A port that cannot be bound is `error: ...` on STDOUT and exit 1.
    # @param argv [Array<String>]
    # @return [nil]
    def serve(argv)
      server_runner.run_server(argv)
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
      Roles.request_stop
    end

    # The "now" (epoch seconds) `feeds status` measures ages from; 0, the
    # default, is the clock. A test sets it to make the output repeatable.
    # @api public
    def self.status_now = @status_now.to_i

    # @param value [Integer] epoch seconds; 0 for the clock
    # @return [nil]
    # @api public
    def self.status_now=(value)
      @status_now = value
      nil
    end

    def self.reset_roles_stop
      Roles.reset_stop
    end

    # Waits for a stop, or for a loaded subsystem failing for good
    # (Roles.wait_stop).
    def self.wait_roles_stop
      Roles.wait_stop
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

    # Views as a process renders them: the embedded templates in
    # production, the files under views_root otherwise (cached outside
    # development), the URL resolver and the layout. Boot calls it, and so
    # does Main.command's runner, so a command renders partials and
    # components (a mail body, a broadcast) as an action does.
    # `eager: false` leaves the embedded templates to be parsed when first
    # rendered: a registered command runs on one thread and may render
    # nothing, so a template that does not parse must not stop it (the
    # server parses them all at boot and fails there instead).
    def self.configure_views(c, views, url_resolver, eager: true)
      if c.production?
        Views.configure_embedded(views, max_render_depth: c.max_render_depth, eager: eager)
      else
        Views.configure(c.views_root, cache: !c.development?, max_render_depth: c.max_render_depth)
      end
      Views.url_resolver = url_resolver
      Views.layout_name = c.layout
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
      Roles.fail_boot(message)
    end

    def build_stack
      c = @config
      app = @router
      app = CsrfProtection.new(app, c.csrf_exempt_prefixes) if c.csrf
      app = SessionStore.new(app, secret: c.resolve_secret!, cookie_name: c.session_cookie_name,
                                  max_age: c.session_max_age, secure: c.secure_cookies?,
                                  same_site: c.session_same_site, partitioned: c.session_partitioned,
                                  absolute_max_age: c.session_absolute_max_age)
      app = MethodOverride.new(app)
      app = Static.new(app, c.public_root) if c.static_files
      # Before Static and the session: no public/ file shadows it, and it
      # sets no cookie. Inside RequestLogger, so polls are logged as usual.
      app = HealthCheck.new(app, c.health_path, c.health_worker_stale, c.health_feeds, c.health_feed_stale) unless c.health_path.empty?
      # A loaded subsystem's endpoint (Features.wrap_endpoints: with
      # cybertrain/streams, the realtime endpoint Stream::Endpoint unless
      # Config#stream_path is ""), also before the session: its
      # authorisation is the signed token, and it sets no cookie.
      app = Features.wrap_endpoints(app, c)
      # Only when a policy exists: an application without one keeps its
      # stack (and sends no CSP header, as in Rails).
      policy = c.content_security_policy_value
      if !policy.nil? || ContentSecurityPolicy.controller_policies?
        app = ContentSecurityPolicyHeader.new(app, policy, c.content_security_policy_report_only,
                                              c.content_security_policy_nonce_directives)
      end
      # The stream path's `s` tokens are logged as [FILTERED].
      app = RequestLogger.new(app, Cybertrain.logger, c.stream_path) unless c.log_level == :none
      app = ErrorPages.new(app, c.public_root) if c.production?
      # Outside ErrorPages, inside the host check: a refused Host is never
      # redirected, and the redirect's host is one the check accepted.
      app = SslRedirect.new(app, c.health_path) if c.force_ssl
      app = HostAuthorization.new(app, c.checked_hosts, c.health_path) if c.host_check?
      app
    end
  end
end

require "cybertrain/roles"
