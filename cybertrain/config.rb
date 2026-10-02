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
  class Config
    SECRET_LENGTH = 64

    attr_accessor :env, :host, :port, :database_path, :secret_key_base, :views_root, :public_root, :layout,
                  :log_level, :session_cookie_name, :session_max_age, :session_secure, :pool_size, :static_files,
                  :csrf, :workers, :secret_key_path, :max_render_depth

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
      # Renders open at once (page, layout, partials) before a template error.
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

    def development?
      @env == "development"
    end

    def test?
      @env == "test"
    end

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

  def self.configure(&block)
    block.call(config)
    nil
  end

  def self.env
    config.env
  end
end
