require "cybertrain/crypto"
require "cybertrain/template/limits"

module Cybertrain
  # The application's settings. Defaults come from the environment
  # (CYBERTRAIN_ENV, PORT, CYBERTRAIN_DATABASE, CYBERTRAIN_SECRET_KEY_BASE,
  # SPINEL_WORKERS, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
  # CYBERTRAIN_SESSION_PARTITIONED); config/app.rb then adjusts them:
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

    # The address the server binds, `"127.0.0.1"`, from `CYBERTRAIN_HOST`. Use
    # `"0.0.0.0"` to listen on every interface (in a container; behind a
    # reverse proxy, keep the default).
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

    # The session cookie's SameSite attribute, `"Lax"`, from
    # `CYBERTRAIN_SESSION_SAME_SITE`: `"Lax"`, `"Strict"` or `"None"`; any
    # other value stops the server at boot. `"None"` always adds `Secure`.
    # @return [String]
    # @api public
    attr_accessor :session_same_site

    # Whether the session cookie is `Partitioned`, `false`, from
    # `CYBERTRAIN_SESSION_PARTITIONED` (`1` or `true`); it adds `Secure` too.
    # With `"None"` it is for an app shown inside another site's frame,
    # such as an editor's preview.
    # @return [Boolean]
    # @api public
    attr_accessor :session_partitioned

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

    # Path prefixes whose non-GET requests skip the CSRF check, `[]`: for an
    # API that other programs call with a token of its own (a webhook
    # receiver, an SDK's ingest endpoint), where no browser session exists.
    # A prefix is compared with the request path as sent (not decoded) from
    # its first byte, so give it with both slashes: `"/api/"` exempts
    # `/api/notes` and `/api/1/events/`, not `/apix`. Anything not under a
    # listed prefix is checked as before. The exempt controller must
    # authenticate its callers itself (an API key in a header).
    # @example config/app.rb
    #   c.csrf_exempt_prefixes = ["/api/"]
    # @return [Array<String>]
    # @api public
    attr_accessor :csrf_exempt_prefixes

    # The largest request body the server accepts, in bytes, `10485760`
    # (10 MiB); a longer one is answered 413 before the body is read. Raise
    # it for an endpoint that receives large uploads or compressed payloads
    # (the limit is on the bytes on the wire; see {Request#decoded_body} for
    # the decoded size).
    # @return [Integer]
    # @api public
    attr_accessor :max_body_bytes

    # The largest single uploaded file in a `multipart/form-data` body, in
    # bytes, `5242880` (5 MiB); a bigger file part is answered 400. Boot
    # refuses a value over {#max_body_bytes}, which bounds the whole body
    # (raise both for bigger files). The server buffers the whole body, so
    # memory use is about three times the body per request in flight.
    # @return [Integer]
    # @api public
    attr_accessor :max_upload_bytes

    # The most parts (text fields plus files) in one multipart body, `128`
    # (1 to 4096); more is answered 400.
    # @return [Integer]
    # @api public
    attr_accessor :max_multipart_parts

    # The directory {BlobStore} keeps uploaded files in, `"storage/uploads"`
    # (relative to the working directory). It is created on the first write,
    # not at boot, and is never under `public/`: `storage/` is the persistent
    # volume of a deployment, `public/` is replaced on every build.
    # @return [String]
    # @api public
    attr_accessor :upload_root

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
      env_or("CYBERTRAIN_DATABASE", "storage/#{env}.sqlite3")
    end

    def self.default_env
      ENV["CYBERTRAIN_ENV"] || "development"
    end

    # CYBERTRAIN_HOST, or "127.0.0.1" when it is unset or empty. Not
    # validated: TCPServer.new gets it as it is ("0.0.0.0" listens on every
    # interface, which a container needs).
    def self.default_host
      env_or("CYBERTRAIN_HOST", "127.0.0.1")
    end

    # CYBERTRAIN_SESSION_SAME_SITE, or "Lax" when it is unset or empty.
    def self.default_session_same_site
      env_or("CYBERTRAIN_SESSION_SAME_SITE", "Lax")
    end

    # ENV[name], or default when it is unset or empty (an empty variable
    # counts as unset). A String either way (NOTES rules 10/34).
    def self.env_or(name, default)
      configured = ENV[name] || ""
      configured.empty? ? default : configured
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
      # An element-typed empty Array (spikes/NOTES.md rule 9): config/app.rb
      # assigns a literal, the stack reads it.
      @csrf_exempt_prefixes = Array.new(0) { "" }
      # The same number as Server.new's default (cybertrain/http/server.rb), kept
      # as a literal here: the HTTP layer must not be required by Config.
      @max_body_bytes = 10_485_760
      # The same literals as Multipart and BlobStore start with; Application#boot
      # hands the configured values to both.
      @max_upload_bytes = 5_242_880
      @max_multipart_parts = 128
      @upload_root = "storage/uploads"
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

    # The error Application#boot reports (and exits 1 on) when a
    # csrf_exempt_prefixes entry is not a usable prefix: each must start and
    # end with "/" (so "/api" cannot take "/apix" with it) and must not be
    # "/" alone (which would switch the check off for the whole app: that is
    # `c.csrf = false`, said plainly). "" when every entry is fine. A while
    # loop over the typed Array, no block (NOTES rules 32, 45).
    def csrf_exempt_prefixes_error
      prefixes = @csrf_exempt_prefixes
      i = 0
      while i < prefixes.size
        prefix = prefixes[i]
        unless prefix.size >= 2 && prefix.start_with?("/") && prefix.end_with?("/")
          return "csrf_exempt_prefixes entry #{prefix.inspect} must start and end with \"/\" and not be \"/\" alone"
        end
        i += 1
      end
      ""
    end

    # The error Application#boot reports when max_body_bytes is not a
    # positive Integer (nil would make every request with a body a
    # connection error in Server#serve); "" when it is one.
    def max_body_bytes_error
      value = @max_body_bytes
      case value
      when Integer
        return "" if value >= 1
      end
      "max_body_bytes must be an Integer of at least 1 (got #{value.inspect})"
    end

    # The error Application#boot reports (and exits 1 on) when the upload
    # settings are unusable; "" when they are fine. A file larger than the
    # body limit could never arrive, so max_upload_bytes over max_body_bytes
    # is a mistake worth saying (checked only when both are Integers: a bad
    # max_body_bytes has its own message).
    def upload_limits_error
      limit = @max_upload_bytes
      case limit
      when Integer
        return "max_upload_bytes must be an Integer of at least 1 (got #{limit})" if limit < 1

        body_limit = @max_body_bytes
        case body_limit
        when Integer
          return "max_upload_bytes (#{limit}) must not exceed max_body_bytes (#{body_limit})" if limit > body_limit
        end
      else
        return "max_upload_bytes must be an Integer of at least 1 (got #{limit.inspect})"
      end
      parts = @max_multipart_parts
      case parts
      when Integer
        return "max_multipart_parts must be an Integer from 1 to 4096 (got #{parts})" if parts < 1 || parts > 4096
      else
        return "max_multipart_parts must be an Integer from 1 to 4096 (got #{parts.inspect})"
      end
      root = @upload_root
      case root
      when String
        return "upload_root must be a non-empty String" if root.empty?
      else
        return "upload_root must be a non-empty String"
      end
      ""
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

      exists = File.exist?(@secret_key_path)
      secret = ""
      if exists
        # Restrict older keys before reading or replacing their contents.
        File.chmod(0o600, @secret_key_path)
        secret = File.read(@secret_key_path).strip
      end
      if secret.length != SECRET_LENGTH
        secret = Crypto.random_token(SECRET_LENGTH / 2)
        Config.make_directory(File.dirname(@secret_key_path), 0o700)
        flags = exists ? File::WRONLY | File::TRUNC : File::WRONLY | File::CREAT | File::EXCL
        File.open(@secret_key_path, flags, 0o600) do |file|
          file.write("#{secret}\n")
        end
      end
      @secret_key_base = secret
    end

    # mkdir -p.
    def self.make_directory(dir, mode = 0o777)
      return nil if dir == "" || dir == "." || File.directory?(dir)

      make_directory(File.dirname(dir), mode)
      Dir.mkdir(dir, mode)
      # Spinel ignores mkdir's mode argument. Only restrict directories we
      # created for secrets; other callers retain the default umask behavior.
      File.chmod(mode, dir) unless mode == 0o777
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
