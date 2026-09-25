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
        built = Server.new(stack, host: @config.host, port: @config.port)
        @server = built
      end
      built
    end

    # Boots and serves until SIGTERM. Task 16's development loop wraps
    # `serve`; production stays boot + serve.
    def run
      boot
      serve
    end

    # Starts the server and blocks until it is stopped. SPINEL_WORKERS must
    # be set before the first Thread.new starts the scheduler (NOTES rule 22).
    def serve
      ENV["SPINEL_WORKERS"] = @config.workers.to_s
      srv = server
      trap("TERM") { srv.stop }
      srv.run
      nil
    end

    private

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
