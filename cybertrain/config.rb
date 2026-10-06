require "cybertrain/crypto"
require "cybertrain/template/limits"

module Cybertrain
  # The application's settings. Defaults come from the environment
  # (CYBERTRAIN_ENV, PORT, CYBERTRAIN_DATABASE, CYBERTRAIN_SECRET_KEY_BASE,
  # SPINEL_WORKERS); config/app.rb then adjusts them:
  #
  #   Cybertrain.configure do |c|
  #     c.port = 3000
  #   end
  #
  # Read it anywhere as `Cybertrain.config`.
  # @example config/app.rb
  #   Cybertrain.configure do |c|
  #     c.log_level = :none if c.test?
  #     c.max_render_depth = 20
  #   end
  #   Cybertrain.url_root = "https://example.com" if Cybertrain.config.production?
  # @api public
  class Config
    SECRET_LENGTH = 64

    # The environment: `"development"` (the default), `"test"` or
    # `"production"` (the default in a binary from `cybertrain build`). From
    # `CYBERTRAIN_ENV`. Set the variable rather than this attribute:
    # `database_path` and `session_secure` are derived from it before
    # `config/app.rb` runs.
    # @return [String]
    # @api public
    attr_accessor :env

    # The address the server binds, `"127.0.0.1"`. Use `"0.0.0.0"` to listen
    # on every interface (behind a reverse proxy, keep the default).
    # @return [String]
    # @api public
    attr_accessor :host

    # The port, `3000`, from `PORT`. A port given on the command line (`./blog
    # 8080`, `cybertrain server 8080`) wins.
    # @return [Integer]
    # @api public
    attr_accessor :port

    # The SQLite file, `"storage/<env>.sqlite3"`, from `CYBERTRAIN_DATABASE`.
    # Relative to the working directory.
    # @return [String]
    # @api public
    attr_accessor :database_path

    # The secret the session cookie is signed with, from
    # `CYBERTRAIN_SECRET_KEY_BASE`. Required in production (boot fails without
    # it; `openssl rand -hex 32` makes one); development and test create one
    # in `tmp/secret_key`. Changing it ends every session.
    # @return [String]
    # @api public
    attr_accessor :secret_key_base

    # Where templates are read from in development and test, `"app/views"`. A
    # production binary uses the templates embedded by `cybertrain build`.
    # @return [String]
    # @api public
    attr_accessor :views_root

    # The static files directory, `"public"`, served before routing, and where
    # `public/<status>.html` error pages are found in production.
    # @return [String]
    # @api public
    attr_accessor :public_root

    # The layout every template renders in, `"layouts/application"`
    # (`app/views/layouts/application.html.erb`); ignored when that file does
    # not exist.
    # @return [String]
    # @api public
    attr_accessor :layout

    # `:info` (the default), `:debug`, `:warn`, `:error`, or `:none`, which
    # also turns off the request log but still prints errors. Lines go to
    # standard output as `[INFO] ...`.
    # @return [Symbol]
    # @api public
    attr_accessor :log_level

    # The session cookie's name, `"_cybertrain_session"`.
    # @return [String]
    # @api public
    attr_accessor :session_cookie_name

    # The session cookie's Max-Age in seconds, two weeks (`1209600`). It
    # restarts whenever the session changes.
    # @return [Integer]
    # @api public
    attr_accessor :session_max_age

    # Whether the session cookie is `Secure` (HTTPS only): true in production,
    # false elsewhere.
    # @return [Boolean]
    # @api public
    attr_accessor :session_secure

    # SQLite connections in the pool, `4`.
    # @return [Integer]
    # @api public
    attr_accessor :pool_size

    # Whether `public/` is served, `true`. Turn it off when the reverse proxy
    # serves it.
    # @return [Boolean]
    # @api public
    attr_accessor :static_files

    # Whether non-GET requests must carry the CSRF token, `true`. A request
    # without it gets 403.
    # @return [Boolean]
    # @api public
    attr_accessor :csrf

    # Spinel worker threads, `1`, from `SPINEL_WORKERS`.
    # @return [Integer]
    # @api public
    attr_accessor :workers

    # Where development and test keep their generated secret,
    # `"tmp/secret_key"`.
    # @return [String]
    # @api public
    attr_accessor :secret_key_path

    # How many renders may be open at once (the page and its nested partials),
    # `12`. Raise it for partials that recurse deeper, such as threaded
    # comments; it must be at least 1.
    # @return [Integer]
    # @api public
    attr_accessor :max_render_depth

    # "storage/<env>.sqlite3" unless CYBERTRAIN_DATABASE names a path (an
    # empty one counts as unset). Shared with DB::CLI.
    def self.default_database_path(env)
      configured = ENV["CYBERTRAIN_DATABASE"] || ""
      configured.empty? ? "storage/#{env}.sqlite3" : configured
    end

    def self.default_env
      ENV["CYBERTRAIN_ENV"] || "development"
    end

    def initialize
      @env = Config.default_env
      @host = "127.0.0.1"
      @port = (ENV["PORT"] || "3000").to_i
      @database_path = Config.default_database_path(@env)
      @secret_key_base = ENV["CYBERTRAIN_SECRET_KEY_BASE"] || ""
      @secret_key_path = "tmp/secret_key"
      @views_root = "app/views"
      # Renders open at once (the page and its partials; the layout renders after
      # the page and does not nest) before a template error.
      # The constant itself, not a copy of its value: Views.configure always
      # receives this, so a literal here would override a changed
      # Template::MAX_RENDER_DEPTH for every real app. Raise it
      # for partials that legitimately recurse deeper (threaded comments, a
      # tree menu). Must be an Integer of at least 1: Views.configure (and configure_embedded)
      # refuse anything else at boot, since a ceiling of 0 or less would make
      # every render fail.
      @max_render_depth = Template::MAX_RENDER_DEPTH
      @public_root = "public"
      @layout = "layouts/application"
      @log_level = :info
      @session_cookie_name = "_cybertrain_session"
      @session_max_age = 1209600
      # The session cookie's Secure attribute: on in production, which is
      # expected to sit behind a TLS-terminating proxy; off elsewhere, where
      # the server is reached over plain http://.
      @session_secure = production?
      @pool_size = 4
      @static_files = true
      @csrf = true
      @workers = (ENV["SPINEL_WORKERS"] || "1").to_i
    end

    # @return [Boolean]
    # @api public
    def development?
      @env == "development"
    end

    # @return [Boolean]
    # @api public
    def test?
      @env == "test"
    end

    # @return [Boolean]
    # @api public
    def production?
      @env == "production"
    end

    # The secret sessions are signed with. Production must set it
    # (CYBERTRAIN_SECRET_KEY_BASE); other environments read secret_key_path,
    # creating it with a random 64-hex-digit key the first time.
    def resolve_secret!
      return @secret_key_base unless @secret_key_base.empty?
      raise "CYBERTRAIN_SECRET_KEY_BASE is not set" if production?

      secret = File.exist?(@secret_key_path) ? File.read(@secret_key_path).strip : ""
      if secret.length != SECRET_LENGTH
        secret = Crypto.random_token(SECRET_LENGTH / 2)
        Config.make_directory(File.dirname(@secret_key_path))
        File.write(@secret_key_path, "#{secret}\n")
      end
      @secret_key_base = secret
    end

    # mkdir -p.
    def self.make_directory(dir)
      return nil if dir == "" || dir == "." || File.directory?(dir)

      make_directory(File.dirname(dir))
      Dir.mkdir(dir)
      nil
    end
  end

  # Module-level ivar, not @@config: spikes/NOTES.md rule 18. Created on
  # first use so it reads the environment of the running process.
  @config = nil

  # The application's {Config}.
  # @return [Config]
  # @api public
  def self.config
    current = @config
    if current.nil?
      current = Config.new
      @config = current
    end
    current
  end

  def self.config=(config)
    @config = config
  end

  # True once something has created or assigned the process-wide config.
  def self.config_loaded?
    !@config.nil?
  end

  # Yields {.config} for `config/app.rb` to change.
  # @yieldparam config [Config]
  # @return [nil]
  # @api public
  def self.configure(&block)
    block.call(config)
    nil
  end

  # @return [String] `Cybertrain.config.env`
  # @api public
  def self.env
    config.env
  end
end
