require "cybertrain/crypto"

module Cybertrain
  # The application's settings. Defaults come from the environment
  # (CYBERTRAIN_ENV, PORT, CYBERTRAIN_DATABASE, CYBERTRAIN_SECRET_KEY_BASE,
  # SPINEL_WORKERS, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
  # CYBERTRAIN_SESSION_PARTITIONED); config/app.rb then adjusts them:
  #
  #   Cybertrain.configure do |c|
  #     c.port = 3000
  #   end
  class Config
    SECRET_LENGTH = 64

    attr_accessor :env, :host, :port, :database_path, :secret_key_base, :views_root, :public_root, :layout,
                  :log_level, :session_cookie_name, :session_max_age, :session_secure, :session_same_site,
                  :session_partitioned, :pool_size, :static_files, :csrf, :workers, :secret_key_path

    # "storage/<env>.sqlite3" unless CYBERTRAIN_DATABASE names a path (an
    # empty one counts as unset). Shared with DB::CLI.
    def self.default_database_path(env)
      configured = ENV["CYBERTRAIN_DATABASE"] || ""
      configured.empty? ? "storage/#{env}.sqlite3" : configured
    end

    def self.default_env
      ENV["CYBERTRAIN_ENV"] || "development"
    end

    # CYBERTRAIN_HOST, or "127.0.0.1" when it is unset or empty. Not
    # validated: TCPServer.new gets it as it is ("0.0.0.0" listens on every
    # interface, which a container needs).
    def self.default_host
      configured = ENV["CYBERTRAIN_HOST"] || ""
      configured.empty? ? "127.0.0.1" : configured
    end

    # CYBERTRAIN_SESSION_SAME_SITE, or "Lax" when it is unset or empty.
    def self.default_session_same_site
      configured = ENV["CYBERTRAIN_SESSION_SAME_SITE"] || ""
      configured.empty? ? "Lax" : configured
    end

    # True only for CYBERTRAIN_SESSION_PARTITIONED=1 or =true; any other
    # value is false, not an error.
    def self.default_session_partitioned
      configured = ENV["CYBERTRAIN_SESSION_PARTITIONED"] || ""
      configured == "1" || configured == "true"
    end

    def initialize
      @env = Config.default_env
      @host = Config.default_host
      @port = (ENV["PORT"] || "3000").to_i
      @database_path = Config.default_database_path(@env)
      @secret_key_base = ENV["CYBERTRAIN_SECRET_KEY_BASE"] || ""
      @secret_key_path = "tmp/secret_key"
      @views_root = "app/views"
      @public_root = "public"
      @layout = "layouts/application"
      @log_level = :info
      @session_cookie_name = "_cybertrain_session"
      @session_max_age = 1209600
      # The session cookie's Secure attribute: on in production, which is
      # expected to sit behind a TLS-terminating proxy; off elsewhere, where
      # the server is reached over plain http://. SameSite=None and
      # Partitioned add Secure whatever this says (Cookies.serialize).
      @session_secure = production?
      # SameSite of the session cookie: "Lax", "Strict" or "None" (boot checks
      # it). "None" is for an app shown inside another site's frame, such as an
      # editor's preview; it always adds Secure (Cookies.serialize).
      @session_same_site = Config.default_session_same_site
      # Partitioned (CHIPS): with None, the cookie survives third-party cookie
      # blocking inside such a frame. Adds Secure too.
      @session_partitioned = Config.default_session_partitioned
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

    # The error Application#boot reports (and exits 1 on) when
    # session_same_site is not a value browsers accept; "" when it is one.
    # Case-sensitive, since the value goes into the header as it is; a chain
    # of ==, not include? (spikes/NOTES.md rules 14 and 29).
    def session_same_site_error
      value = @session_same_site
      return "" if value == "Lax" || value == "Strict" || value == "None"

      "CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got \"#{value}\")"
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
