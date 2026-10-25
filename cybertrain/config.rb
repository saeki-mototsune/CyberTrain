require "cybertrain/crypto"
require "cybertrain/logger"
require "cybertrain/params"
require "cybertrain/template/limits"

module Cybertrain
  # The application's settings. Defaults come from the environment
  # (CYBERTRAIN_ENV, PORT, CYBERTRAIN_DATABASE, CYBERTRAIN_SECRET_KEY_BASE,
  # SPINEL_WORKERS, CYBERTRAIN_HOST, CYBERTRAIN_ALLOWED_HOSTS, CYBERTRAIN_SESSION_SAME_SITE,
  # CYBERTRAIN_SESSION_PARTITIONED, CYBERTRAIN_MAX_PAGE); config/app.rb then adjusts them:
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

    # Hostnames development requests may use, even when listening on
    # "0.0.0.0". Defaults to localhost, 127.0.0.1 and [::1]; the comma-separated
    # CYBERTRAIN_ALLOWED_HOSTS adds exact forwarding hostnames. No wildcards,
    # schemes or ports; IPv6 addresses include brackets. An empty list denies
    # every host. Production and test do not apply this development guard.
    # @return [Array<String>]
    # @api public
    attr_accessor :allowed_hosts

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
    # restarts whenever the session changes. Generated authentication also
    # uses this as an absolute lifetime from the Session row's created_at;
    # cookie changes do not extend that sign-in.
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

    # The largest page number {Params#page_number} gives and
    # {Relation#page} accepts, `10000`, from `CYBERTRAIN_MAX_PAGE` (an
    # optional `-` and at most 18 digits; anything else, or a value below 1,
    # is the default). It bounds the OFFSET a request can ask for, at
    # `(max_page - 1) * per` rows. At least 1 (boot refuses less).
    # @return [Integer]
    # @api public
    attr_accessor :max_page

    # CYBERTRAIN_MAX_PAGE read without to_i on unbounded text (NOTES rule
    # 25): 10000 when it is unset, not a number, or below 1.
    def self.default_max_page
      n = Params.parse_int(env_or("CYBERTRAIN_MAX_PAGE", ""), 10_000)
      n < 1 ? 10_000 : n
    end

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
      @allowed_hosts = ["localhost", "127.0.0.1", "[::1]"]
      extra_hosts = ENV["CYBERTRAIN_ALLOWED_HOSTS"] || ""
      extra_hosts.split(",").each do |entry|
        name = entry.strip
        @allowed_hosts << name unless name.empty?
      end
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
      # Application-defined settings (setting_string / setting_int /
      # setting_bool): one typed Hash per type, keyed by the setting's name
      # as a String and seeded with its element type (spikes/NOTES.md rule
      # 9), plus what `help` and the boot banner list, in declaration order.
      @setting_strings = { "" => "" }
      @setting_strings.delete("")
      @setting_ints = { "" => 0 }
      @setting_ints.delete("")
      @setting_bools = { "" => false }
      @setting_bools.delete("")
      @setting_names = Array.new(0) { "" }
      @setting_envs = { "" => "" }
      @setting_envs.delete("")
      @setting_descriptions = { "" => "" }
      @setting_descriptions.delete("")
      @setting_secrets = { "" => false }
      @setting_secrets.delete("")
      # Params.max_page's literal; Application#boot installs this there.
      @max_page = Config.default_max_page
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

    # The widest bounds an Integer setting may have: 18 digits either way,
    # the most {Config.int_setting_text?} lets through to `to_i` (which
    # raises RangeError past 2**63-1 under Spinel, spikes/NOTES.md rule 25).
    SETTING_INT_MIN = -999_999_999_999_999_999
    SETTING_INT_MAX = 999_999_999_999_999_999

    # Declares an application setting holding a String, read once from the
    # environment variable `env` (an empty or unset variable means
    # `default`). Read it with {#string_setting}. A name may be declared
    # once; give it as a Symbol. `secret: true` keeps the value out of the
    # boot banner and `help`, which then show only the variable's name.
    # @example config/app.rb
    #   Cybertrain.configure do |c|
    #     c.setting_string :base_url, env: "MYAPP_BASE_URL", default: ""
    #     c.setting_string :smtp_password, env: "MYAPP_SMTP_PASSWORD", default: "", secret: true
    #   end
    #   Cybertrain.config.string_setting(:base_url)
    # @param name [Symbol]
    # @param env [String] the environment variable
    # @param default [String]
    # @param secret [Boolean]
    # @return [nil]
    # @raise [ArgumentError] when the name is already declared or env is empty
    # @api public
    def setting_string(name, env:, default:, secret: false)
      key = declare_setting(name, env, secret)
      @setting_strings[key] = Config.env_or(env, default)
      @setting_descriptions[key] = secret ? "string, secret" : "string, default #{default.inspect}"
      nil
    end

    # Declares an application setting holding an Integer, read once from the
    # environment variable `env`: decimal digits with an optional leading
    # `-`, within `min..max`. An empty or unset variable means `default`;
    # anything else that does not parse, or a number out of bounds, also
    # gives `default`, with a `[WARN]` line through {Cybertrain.logger}.
    # Read it with {#int_setting}.
    # @example config/app.rb
    #   c.setting_int :prune_interval, env: "MYAPP_PRUNE_INTERVAL", default: 3600, min: 1, max: 9_999_999
    # @param name [Symbol]
    # @param env [String] the environment variable
    # @param default [Integer]
    # @param min [Integer] the smallest accepted value (no bound by default)
    # @param max [Integer] the largest accepted value (no bound by default)
    # @return [nil]
    # @raise [ArgumentError] when the name is already declared, env is
    #   empty, or default is outside min..max
    # @api public
    def setting_int(name, env:, default:, min: SETTING_INT_MIN, max: SETTING_INT_MAX)
      key = name.to_s
      bounds = Config.int_bounds(min, max)
      if min > max || default < min || default > max
        raise ArgumentError, "setting #{key}: default #{default} is out of range (#{bounds})"
      end

      declare_setting(name, env, false)
      @setting_ints[key] = Config.int_from_env(env, default, min, max)
      @setting_descriptions[key] = bounds.empty? ? "integer, default #{default}" : "integer #{bounds}, default #{default}"
      nil
    end

    # Declares an application setting holding true or false, read once from
    # the environment variable `env`: `1` or `true` is true, `0` or `false`
    # is false, an empty or unset variable means `default`, and any other
    # value gives `default` with a `[WARN]` line through {Cybertrain.logger}.
    # Read it with {#bool_setting}.
    # @example config/app.rb
    #   c.setting_bool :worker, env: "MYAPP_WORKER", default: true
    # @param name [Symbol]
    # @param env [String] the environment variable
    # @param default [Boolean]
    # @return [nil]
    # @raise [ArgumentError] when the name is already declared or env is empty
    # @api public
    def setting_bool(name, env:, default:)
      key = declare_setting(name, env, false)
      @setting_bools[key] = Config.bool_from_env(env, default)
      @setting_descriptions[key] = "boolean (1/true, 0/false), default #{default}"
      nil
    end

    # The value of the String setting `name` ({#setting_string}).
    # @param name [Symbol]
    # @return [String]
    # @raise [ArgumentError] when no String setting of that name is declared
    # @api public
    def string_setting(name)
      key = name.to_s
      raise ArgumentError, "no string setting #{key} (declare it with setting_string)" unless @setting_strings.key?(key)

      @setting_strings[key].to_s
    end

    # The value of the Integer setting `name` ({#setting_int}).
    # @param name [Symbol]
    # @return [Integer]
    # @raise [ArgumentError] when no Integer setting of that name is declared
    # @api public
    def int_setting(name)
      key = name.to_s
      raise ArgumentError, "no integer setting #{key} (declare it with setting_int)" unless @setting_ints.key?(key)

      @setting_ints[key].to_i
    end

    # The value of the boolean setting `name` ({#setting_bool}).
    # @param name [Symbol]
    # @return [Boolean]
    # @raise [ArgumentError] when no boolean setting of that name is declared
    # @api public
    def bool_setting(name)
      key = name.to_s
      raise ArgumentError, "no boolean setting #{key} (declare it with setting_bool)" unless @setting_bools.key?(key)

      @setting_bools[key] == true
    end

    # Replaces the value of a declared String setting, for tests.
    # @param name [Symbol]
    # @param value [String]
    # @return [nil]
    # @raise [ArgumentError] when no String setting of that name is declared
    # @api public
    def set_string_setting(name, value)
      string_setting(name)
      @setting_strings[name.to_s] = value
      nil
    end

    # Replaces the value of a declared Integer setting, for tests. The
    # declared bounds are not applied.
    # @param name [Symbol]
    # @param value [Integer]
    # @return [nil]
    # @raise [ArgumentError] when no Integer setting of that name is declared
    # @api public
    def set_int_setting(name, value)
      int_setting(name)
      @setting_ints[name.to_s] = value
      nil
    end

    # Replaces the value of a declared boolean setting, for tests.
    # @param name [Symbol]
    # @param value [Boolean]
    # @return [nil]
    # @raise [ArgumentError] when no boolean setting of that name is declared
    # @api public
    def set_bool_setting(name, value)
      bool_setting(name)
      @setting_bools[name.to_s] = value
      nil
    end

    # Records a declaration (what `help` and the boot banner list) and
    # returns the name as the String the typed Hashes are keyed by.
    def declare_setting(name, env, secret)
      key = name.to_s
      raise ArgumentError, "a setting needs a name" if key.empty?
      raise ArgumentError, "setting #{key}: env must name an environment variable" if env.empty?
      raise ArgumentError, "setting #{key} is declared twice" if @setting_envs.key?(key)

      @setting_names << key
      @setting_envs[key] = env
      @setting_secrets[key] = secret
      key
    end

    # "1..10", ">= 1", "<= 10", or "" when neither bound is set.
    def self.int_bounds(min, max)
      if min == SETTING_INT_MIN
        return "" if max == SETTING_INT_MAX

        return "<= #{max}"
      end
      return ">= #{min}" if max == SETTING_INT_MAX

      "#{min}..#{max}"
    end

    # True when text is an optional "-" and 1 to 18 significant decimal
    # digits (leading zeros aside): what `to_i` parses without the
    # RangeError it raises past 2**63-1 (spikes/NOTES.md rule 25).
    def self.int_setting_text?(text)
      s = text.to_s # NOTES rule 62
      n = s.bytesize
      start = 0
      start = 1 if n > 0 && s.getbyte(0) == 45
      return false if n == start

      i = start
      while i < n
        b = s.getbyte(i)
        return false if b < 48 || b > 57

        i += 1
      end
      first = start
      first += 1 while first < n - 1 && s.getbyte(first) == 48
      n - first <= 18
    end

    # The Integer in ENV[env], or default (with a warning when the variable
    # is set but unusable).
    def self.int_from_env(env, default, min, max)
      text = ENV[env] || ""
      return default if text.empty?

      unless Config.int_setting_text?(text)
        Cybertrain.logger.warn("#{env}=#{text.inspect} is not an integer; using the default #{default}")
        return default
      end
      value = text.to_i
      if value < min || value > max
        Cybertrain.logger.warn("#{env}=#{text} is out of range (#{Config.int_bounds(min, max)}); using the default #{default}")
        return default
      end
      value
    end

    # The boolean in ENV[env] ("1"/"true", "0"/"false"), or default (with a
    # warning when the variable is set to anything else).
    def self.bool_from_env(env, default)
      text = ENV[env] || ""
      return default if text.empty?
      return true if text == "1" || text == "true"
      return false if text == "0" || text == "false"

      Cybertrain.logger.warn("#{env}=#{text.inspect} is not a boolean (1/true or 0/false); using the default #{default}")
      default
    end

    # The declared settings as `help` lists them: one line per setting with
    # its environment variable, name, type and default (a secret one shows
    # neither its default nor its value). "" when none is declared.
    def settings_usage
      names = @setting_names
      return "" if names.empty?

      width = 0
      i = 0
      while i < names.size
        env = @setting_envs[names[i]].to_s
        width = env.size if env.size > width
        i += 1
      end
      out = +"Settings (environment variables):\n"
      i = 0
      while i < names.size
        key = names[i]
        env = @setting_envs[key].to_s
        out << "  "
        out << env
        pad = width - env.size + 2
        while pad > 0
          out << " "
          pad -= 1
        end
        out << key
        out << ": "
        out << @setting_descriptions[key].to_s
        out << "\n"
        i += 1
      end
      out
    end

    # The declared settings' current values on one line for the boot banner,
    # `name=value` separated by spaces, a secret one as `name=[FILTERED]`.
    # "" when none is declared.
    def settings_summary
      names = @setting_names
      out = +""
      i = 0
      while i < names.size
        key = names[i]
        out << " " unless out.empty?
        out << key
        out << "="
        out << setting_display_value(key)
        i += 1
      end
      out
    end

    def setting_display_value(key)
      return "[FILTERED]" if @setting_secrets[key] == true
      return @setting_strings[key].to_s.inspect if @setting_strings.key?(key)
      return @setting_ints[key].to_i.to_s if @setting_ints.key?(key)

      (@setting_bools[key] == true).to_s
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

    # The error Application#boot reports when max_page is not an Integer of
    # at least 1, or "" when it is fine.
    def max_page_error
      value = @max_page
      case value
      when Integer
        return "" if value >= 1
      end
      "max_page must be an Integer of at least 1 (got #{value.inspect})"
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
