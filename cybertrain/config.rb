require "cybertrain/crypto"
require "cybertrain/logger"
require "cybertrain/params"
require "cybertrain/http/ip_address"
require "cybertrain/template/limits"
require "cybertrain/time_zone"
require "cybertrain/content_security_policy"
require "cybertrain/config/files"

module Cybertrain
  # The application's settings. Defaults come from the environment
  # (CYBERTRAIN_ENV, PORT, CYBERTRAIN_DATABASE, CYBERTRAIN_SECRET_KEY_BASE,
  # SPINEL_WORKERS, CYBERTRAIN_HOST, CYBERTRAIN_ALLOWED_HOSTS, CYBERTRAIN_SESSION_SAME_SITE,
  # CYBERTRAIN_SESSION_PARTITIONED, CYBERTRAIN_MAX_PAGE, CYBERTRAIN_HTTP_ALLOW_PRIVATE,
  # CYBERTRAIN_WORKER, CYBERTRAIN_I18N_DEFAULT_LOCALE, CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS,
  # CYBERTRAIN_AUTH_LOCKOUT_PERIOD, CYBERTRAIN_AUTH_REMEMBER_FOR,
  # CYBERTRAIN_AUTH_IDLE_TIMEOUT); config/app.rb then adjusts them:
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
    # every host. `CYBERTRAIN_HOSTS` entries ({#hosts_from_env}) are appended
    # too, and turn the same check on in production and test
    # ({#host_check?}); without them those environments do not check.
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

    # The secret the session and cookie keys are derived from, from
    # `CYBERTRAIN_SECRET_KEY_BASE`. Required in production (boot fails without
    # it; `openssl rand -hex 32` makes one); development and test create one
    # in `tmp/secret_key`. Changing it ends every session.
    # @return [String]
    # @api public
    attr_accessor :secret_key_base

    # The key encrypted columns (`encrypts :api_key` in a model) are
    # encrypted with: 64 hex characters (32 bytes) from
    # `CYBERTRAIN_ENCRYPTION_KEY`, "" when unset. `cybertrain secret --hex`
    # makes one. It is not derived from {#secret_key_base}, so rotating the
    # session secret leaves stored data readable. Boot fails on a malformed
    # key, and on an empty one when a model declares `encrypts`
    # ({#encryption_error}).
    # @return [String]
    # @api public
    attr_accessor :encryption_key

    # Earlier encryption keys, tried in order after {#encryption_key} when a
    # stored value does not decrypt with it, and never used to encrypt:
    # `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS`, a comma-separated list of 64-hex
    # keys. To rotate, make a new key, move the old one here, and re-save
    # the records (each save encrypts with the current key).
    # @return [Array<String>]
    # @api public
    attr_accessor :encryption_keys_previous

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
    # standard output as `[INFO] ...`. `cybertrain test` sets `:none` for
    # its tests unless config/app.rb assigns it (the request log would
    # print between the test lines).
    # @return [Symbol]
    # @api public
    attr_reader :log_level

    # Sets {#log_level}, and records that it was given ({#log_level_given?}).
    # @param value [Symbol]
    # @api public
    def log_level=(value)
      @log_level = value
      @log_level_given = true
    end

    # Whether {#log_level} was assigned (by config/app.rb or later), rather
    # than left at its default: what `cybertrain test`'s boot asks.
    # @return [Boolean]
    # @api private
    def log_level_given? = @log_level_given

    # Sets {#log_level} to `value` unless it was given, without counting as
    # given: `cybertrain test`'s default (`:none`, no request log between
    # the test lines).
    # @param value [Symbol]
    # @return [nil]
    # @api private
    def log_level_unless_given(value)
      @log_level = value unless @log_level_given
      nil
    end

    # The session cookie's name, `"_cybertrain_session"`.
    # @return [String]
    # @api public
    attr_accessor :session_cookie_name

    # The session cookie's Max-Age in seconds, two weeks (`1209600`). It
    # restarts whenever the session changes; {#session_absolute_max_age}
    # bounds the session's whole life.
    # @return [Integer]
    # @api public
    attr_accessor :session_max_age

    # The longest a session lives in seconds, however often it is used, two
    # weeks (`1209600`); `0` turns the limit off. The session cookie records
    # when it was first written, signed with the rest, and a cookie older
    # than this loads as an empty session, so a copied cookie cannot be
    # replayed past it. {Session#restart_lifetime!} starts the count again
    # (generated authentication calls it at sign-in, and also ends a
    # sign-in this long after its Session row's created_at).
    # @return [Integer]
    # @api public
    attr_accessor :session_absolute_max_age

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

    # Whether a reverse proxy on this host may name the client, `false`,
    # from `CYBERTRAIN_TRUSTED_PROXY` (`1` or `true`). When true, a request
    # whose connection comes from loopback (127.0.0.0/8, `::1`) takes its
    # {Request#client_ip} from the last hop of `X-Forwarded-For`, the one
    # the proxy appended; any other connection keeps its peer address. Turn
    # it on when the server listens on 127.0.0.1 behind nginx, Caddy or
    # kamal-proxy on the same machine, so that {Controller.rate_limit}
    # counts each visitor rather than the proxy. Nothing changes for a
    # client that connects directly from another machine: its header is
    # ignored.
    # The shorthand for `trusted_proxies` of `127.0.0.0/8,::1` (the
    # IPv4-mapped `::ffff:127.x.x.x` included); see {#trusted_proxies} for a
    # proxy in another container or on another machine.
    # @return [Boolean]
    # @api public
    attr_accessor :trusted_proxy

# The proxies that may name the client besides loopback, `[]`, from
# `CYBERTRAIN_TRUSTED_PROXIES`: comma-separated IPv4 or IPv6 addresses
# or CIDRs (`172.16.0.0/12,10.0.0.0/8`, or one `172.18.0.2`). A request
# whose connection comes from inside one of them takes its
# {Request#client_ip} from the last hop of `X-Forwarded-For`. For a
# proxy that reaches the app over a network rather than loopback:
# kamal-proxy, which runs in its own Docker container and connects from
# the bridge network's address (Docker hands those out of 172.16.0.0/12
# by default). List only addresses no client can connect from: anyone
# inside a listed network can choose the address a rate limit counts.
# `trusted_proxy` is the shorthand for `127.0.0.0/8,::1`; the two add
# up. An entry that is not an address or CIDR (or a prefix past /32 or
# /128) stops the server at boot.
# @return [Array<String>]
# @api public
attr_accessor :trusted_proxies

    # Whether http requests are redirected to https and https responses
    # carry `Strict-Transport-Security: max-age=63072000; includeSubDomains`
    # ({SslRedirect}), `false`, from `CYBERTRAIN_FORCE_SSL` (`1` or `true`;
    # `0`, `false` or empty is off, anything else stops the server at boot).
    # Behind a TLS-terminating proxy the request counts as https when it
    # says `X-Forwarded-Proto: https` (the first element of a list).
    # Request#base_url believes that header only from a trusted proxy, so
    # also set {#trusted_proxy} or {#trusted_proxies}, or URLs the app
    # builds (a `turbo_stream_from ws: true` URL) say http and ws. The
    # health path is never redirected.
    # On, the session and cookie jar cookies are `Secure` whatever
    # {#session_secure} says ({#secure_cookies?}).
    # @return [Boolean]
    # @api public
    attr_accessor :force_ssl

    # The `Host` names from `CYBERTRAIN_HOSTS` (comma-separated, `[]` when
    # unset), also appended to {#allowed_hosts}, after its loopback names:
    # with the check on, `localhost`, `127.0.0.1` and `[::1]` are accepted
    # too (a browser sends those only to its own machine). Set, they turn the host
    # check on outside development ({#host_check?}): a request whose Host
    # is not in {#allowed_hosts} or this list answers 403. Exact names (an
    # IPv6 address in brackets); no scheme, path, port or wildcard (boot
    # refuses one).
    # @return [Array<String>]
    # @api public
    attr_accessor :hosts_from_env

    # The `Permissions-Policy` every response carries unless it sets its
    # own, `"camera=(), microphone=(), geolocation=()"`; `""` sends none.
    # A CR or LF stops the server at boot.
    # @example config/app.rb
    #   c.permissions_policy = "camera=(), microphone=(), geolocation=(self)"
    # @return [String]
    # @api public
    attr_accessor :permissions_policy

    # Whether the Content Security Policy is sent as
    # `Content-Security-Policy-Report-Only` (the browser reports
    # violations and blocks nothing), `false`.
    # @return [Boolean]
    # @api public
    attr_accessor :content_security_policy_report_only

    # The directives that get this request's nonce (`'nonce-...'`), `[]`:
    # with `%w[script-src style-src]`, a `<script>` written with
    # `javascript_tag(nonce: true)` runs under `script-src 'self'`. A name
    # that is not a directive stops the server at boot.
    # @return [Array<String>]
    # @api public
    attr_accessor :content_security_policy_nonce_directives

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
    # without it gets 403. `cybertrain test` turns it off for its tests
    # unless config/app.rb assigns it (Rails' test environment has
    # forgery protection off).
    # @return [Boolean]
    # @api public
    attr_reader :csrf

    # Sets {#csrf}, and records that it was given ({#csrf_given?}).
    # @param value [Boolean]
    # @api public
    def csrf=(value)
      @csrf = value
      @csrf_given = true
    end

    # Whether {#csrf} was assigned (by config/app.rb or later), rather than
    # left at its default: what `cybertrain test`'s boot asks.
    # @return [Boolean]
    # @api private
    def csrf_given? = @csrf_given

    # Sets {#csrf} to `value` unless it was given, without counting as
    # given: `cybertrain test`'s default (forgery protection off).
    # @param value [Boolean]
    # @return [nil]
    # @api private
    def csrf_unless_given(value)
      @csrf = value unless @csrf_given
      nil
    end

    # Puts {#csrf} and whether it was given back as a test found them
    # (ActionDispatch::IntegrationTest#with_forgery_protection).
    # @param value [Boolean]
    # @param given [Boolean]
    # @return [nil]
    # @api private
    def restore_csrf(value, given)
      @csrf = value
      @csrf_given = given
      nil
    end

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

    # Whether {HttpClient} may connect to addresses that are not public
    # (loopback, private, link-local, CGNAT, multicast, ...; see
    # Net::Address), `false`, from `CYBERTRAIN_HTTP_ALLOW_PRIVATE` (`1` or
    # `true`). Off, a URL whose host resolves to such an address raises
    # HttpClient::BlockedAddressError before anything is sent, which keeps a
    # user-supplied webhook URL from reaching the server's own network. Turn
    # it on for a test against a local server, or for an internal service
    # the application is meant to call.
    # @return [Boolean]
    # @api public
    attr_accessor :http_allow_private

    # ---- {Mailer} (cybertrain/mailer.rb), from CYBERTRAIN_SMTP_* ----------

    # The SMTP server {Mailer} sends through, `""` (unset: Mailer.new raises
    # until it is set), from `CYBERTRAIN_SMTP_HOST`.
    # @return [String]
    # @api public
    attr_accessor :smtp_host

    # Its port, `0`, from `CYBERTRAIN_SMTP_PORT`: 0 means the mode's port,
    # 587 for `"starttls"`, 465 for `"tls"`, 25 for `"none"`
    # ({Mailer.default_port}). A value that is not a number from 1 to 65535
    # is 0.
    # @return [Integer]
    # @api public
    attr_accessor :smtp_port

    # The AUTH PLAIN user, `""` (no AUTH), from `CYBERTRAIN_SMTP_USER`.
    # @return [String]
    # @api public
    attr_accessor :smtp_user

    # The AUTH PLAIN password, `""`, from `CYBERTRAIN_SMTP_PASSWORD`. A
    # secret: the boot banner, `help`, logs and Mailer's error messages
    # never show it.
    # @return [String]
    # @api public
    attr_accessor :smtp_password

    # The default sender address, `""`, from `CYBERTRAIN_SMTP_FROM`.
    # @return [String]
    # @api public
    attr_accessor :smtp_from

    # How the connection is protected, `"starttls"`, from
    # `CYBERTRAIN_SMTP_TLS`: `"starttls"` (upgrade a plain connection, port
    # 587), `"tls"` (TLS from the first byte, port 465) or `"none"` (plain
    # text, which sends credentials only to a loopback address). Both TLS
    # modes need `require "cybertrain/net/tls"`.
    # @return [String]
    # @api public
    attr_accessor :smtp_tls

    # CYBERTRAIN_SMTP_PORT: 0 (the mode's port) unless it is 1..65535.
    def self.default_smtp_port
      n = Params.parse_int(env_or("CYBERTRAIN_SMTP_PORT", ""), 0)
      n < 1 || n > 65_535 ? 0 : n
    end

    # ---- end of the Mailer settings ----------------------------------------

    # Spinel worker threads that serve requests, `1`, from `SPINEL_WORKERS`:
    # the core count on a server with more than one. Above 1 the server
    # hands Spinel one more, since Spinel counts the main thread, which
    # only waits ({Application.spinel_workers}). Development always serves
    # on one and ignores this ({Application.serving_workers}).
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

    # Whether a `server` process also runs the background work (the
    # {Scheduler}'s tasks, the {Job} threads, the Background services such
    # as WebSocket subscriptions), `true`; `false` from
    # `CYBERTRAIN_WORKER=0` (or `false`), when `./<app> worker` and
    # `./<app> feeds` processes do that work instead. Those two roles set it
    # to true themselves: running it is what they are for.
    # @return [Boolean]
    # @api public
    attr_accessor :worker

    # Whether the server binds with `SO_REUSEPORT`, `false`; `true` from
    # `CYBERTRAIN_REUSE_PORT=1` (or `true`). Several processes then listen on
    # one port and, on Linux, the kernel splits connections between them
    # (docs/deploy.md); macOS binds but does not distribute. A process left
    # running keeps taking traffic without any bind error. Ignored, with a
    # warning, in development.
    # @return [Boolean]
    # @api public
    attr_accessor :reuse_port

    # Seconds the scheduler thread sleeps between ticks, `1`: a task runs
    # at most this late. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :scheduler_interval

    # Seconds an idle job thread waits before it looks at `cybertrain_jobs`
    # again, `1`: a job enqueued to run now starts within about this long.
    # At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :job_poll_interval

    # How many job threads a process that runs jobs starts, `3`, from
    # `CYBERTRAIN_JOB_THREADS`: that many jobs run at once in it (green
    # threads; a SQLite call still holds an OS worker while it runs). At
    # least 1.
    # @return [Integer]
    # @api public
    attr_accessor :job_threads

    # Seconds between the writes that mark this process's running jobs as
    # alive (`heartbeat_at`), `30`. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :job_heartbeat_interval

    # Seconds without a heartbeat after which a `running` job counts as
    # abandoned (its process died) and {Job.recover!} queues it again,
    # `300`. More than {#job_heartbeat_interval}.
    # @return [Integer]
    # @api public
    attr_accessor :job_heartbeat_stale

    # Seconds {Job.stop!} waits at shutdown for the jobs that are running
    # to finish, `10`; the rows of jobs still running then are left to
    # heartbeat recovery. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :job_drain_timeout

    # Seconds the scheduler's lease lasts unless renewed, `30`: of several
    # processes sharing a database, the one holding the lease runs the
    # scheduled tasks, and another takes over at most this long after it
    # stops ticking. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :scheduler_lease_ttl

    # The application's time zone, `"UTC"`, from `CYBERTRAIN_TIME_ZONE`:
    # an IANA name such as `"Asia/Tokyo"` ({TimeZone.find}; Rails'
    # `config.time_zone` takes Rails' own names, here IANA names only).
    # Boot refuses a name the system zoneinfo does not have
    # ({#time_zone_error}) and installs the zone as `Time.zone`
    # ({Clock.zone}): the boundaries of `beginning_of_day` and the other
    # calendar methods, `Date.current`, `l` and `time_tag` follow it, and
    # {#scheduler_tz} defaults to it. Values stay UTC instants.
    # @example config/app.rb
    #   c.time_zone = "Asia/Tokyo"
    # @return [String]
    # @api public
    attr_accessor :time_zone

    # The zone a `Scheduler.cron` task's expression is read in when it
    # names none (`tz:`), from `CYBERTRAIN_SCHEDULER_TZ`: an IANA name such
    # as `"Asia/Tokyo"` ({TimeZone.find}). While neither the variable nor
    # an assignment set it, it is {#time_zone} (read each time, so a later
    # `c.time_zone =` moves it too). Boot refuses a name the system
    # zoneinfo does not have.
    # @return [String]
    # @api public
    def scheduler_tz
      own = @scheduler_tz
      own.empty? ? @time_zone : own
    end

    # Sets {#scheduler_tz}; `""` makes it follow {#time_zone} again.
    # @param value [String]
    # @return [String]
    # @api public
    attr_writer :scheduler_tz

    # How many rows each list of the jobs page (`jobs_page` in
    # config/routes.rb, {JobsPage}) shows on one page, `50`, from
    # `CYBERTRAIN_JOBS_PAGE_PER_PAGE`; `?page=N` reaches the others. At
    # least 1.
    # @return [Integer]
    # @api public
    attr_accessor :jobs_page_per_page

    # Seconds between the runs of the scheduled task `"cybertrain cache
    # prune"`, which deletes expired {Cache} rows, `300`, from
    # `CYBERTRAIN_CACHE_PRUNE_INTERVAL`. Read once, when
    # `cybertrain/cache` is required (the task is registered then). At
    # least 1.
    # @return [Integer]
    # @api public
    attr_accessor :cache_prune_interval

    # Seconds between the writes of the feeds' status rows
    # (`cybertrain_feeds`, {WebSocket.publish_status}) by the supervisor
    # of a process that runs feeds, `10`, from
    # `CYBERTRAIN_FEED_STATUS_INTERVAL`. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :feed_status_interval

    # How many times the supervisor may restart one feed's thread within
    # {#feed_restart_window}: a feed that dies again after that many
    # restarts makes a `feeds` process exit with status 1 (`[FATAL] feed
    # NAME restarted N times in W s; exiting`), `10`, from
    # `CYBERTRAIN_FEED_RESTART_LIMIT`. A `server` process that runs feeds
    # keeps restarting them. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :feed_restart_limit

    # The window {#feed_restart_limit} counts in, in seconds, `600`, from
    # `CYBERTRAIN_FEED_RESTART_WINDOW`. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :feed_restart_window

    # How many attempts a {Job} gets before it is left `failed`, `5` (the
    # first run and four retries, 1, 5, 15 and 60 minutes apart).
    # @return [Integer]
    # @api public
    attr_accessor :job_max_attempts

    # The path of the built-in health check, `"/up"`, from
    # `CYBERTRAIN_HEALTH_PATH` (set to an empty value, or `c.health_path =
    # ""`, to turn it off; unset is the default). A GET or HEAD of exactly
    # this path is answered before the static files, the session, CSRF and
    # the router (so no controller and no login `before_action` sees it):
    # `200 ok` when a query reading the database's schema succeeds, `503
    # database unavailable` when it fails, and `503 worker stale` when the
    # {Scheduler} runs and has not ticked for {#health_worker_stale}
    # seconds; `text/plain`, `Cache-Control: no-store`, no cookie. Must
    # start with "/" (boot refuses anything else).
    # @return [String]
    # @api public
    attr_accessor :health_path

    # Seconds after the {Scheduler}'s last tick at which the health check
    # answers `503 worker stale`, `300`: a task that runs longer (or a
    # stuck one) shows up there. Only while the scheduler runs. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :health_worker_stale

    # Whether the health check also reads the feed status rows
    # (WebSocket::FeedTable) and answers `503 feed stale` when a feed's
    # publisher or the feed itself has been silent for {#health_feed_stale}
    # seconds. `true`; `CYBERTRAIN_HEALTH_FEEDS=0` (or `false`) turns it off,
    # for a `server` whose feeds run in another process that is watched on
    # its own.
    # @return [Boolean]
    # @api public
    attr_accessor :health_feeds

    # Seconds after which a feed row's `updated_at` (the publishing
    # process) or `COALESCE(last_activity_at, started_at)` (the feed)
    # makes the health check answer `503 feed stale`, `180`, from
    # `CYBERTRAIN_HEALTH_FEED_STALE` (a bad value is the default, one below
    # 1 is refused at boot). At least 1, and while {#health_feeds} is on
    # more than {#feed_status_interval} (boot refuses it otherwise: every
    # row would be stale between two writes). A row whose feed no
    # registered subscription names is not counted.
    # @return [Integer]
    # @api public
    attr_accessor :health_feed_stale

    # The path of the realtime endpoint (Stream::Endpoint: Server-Sent
    # Events and WebSocket), `"/cybertrain/stream"`, from
    # `CYBERTRAIN_STREAM_PATH` (an empty value, or `c.stream_path = ""`,
    # turns the endpoint off). Must start with "/".
    # @return [String]
    # @api public
    attr_accessor :stream_path

    # Milliseconds between the stream poller's looks at
    # `cybertrain_messages`, `100`: a broadcast reaches the browsers within
    # about this long. At least 10.
    # @return [Integer]
    # @api public
    attr_accessor :stream_poll_ms

    # Seconds a broadcast stays in `cybertrain_messages`, `60`: what a
    # reconnecting client can still ask for (`Last-Event-ID`). At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :stream_retention

    # Seconds of silence after which the endpoint sends a keep-alive (an SSE
    # `: ping` comment, a WebSocket ping), `15`. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :stream_ping_interval

    # The most stream connections one process serves at once, `1000`; past
    # it the endpoint answers 503 (SSE) or closes with 1013 (WebSocket).
    # @return [Integer]
    # @api public
    attr_accessor :stream_max_connections

    # The largest WebSocket message the endpoint accepts from a client, in
    # bytes, `65536`; a larger one closes the connection with 1009.
    # @return [Integer]
    # @api public
    attr_accessor :stream_max_message

    # The most undelivered messages one connection may have waiting,
    # `1000`; past it the connection is closed and the client reconnects.
    # @return [Integer]
    # @api public
    attr_accessor :stream_max_backlog

    # The locale a request and a thread start in, `:en`, from
    # `CYBERTRAIN_I18N_DEFAULT_LOCALE` (a name such as `en` or `pt-BR`).
    # Boot refuses a name that is not one, or a default outside
    # {#i18n_available_locales} when that is not empty.
    # @return [Symbol]
    # @api public
    attr_accessor :i18n_default_locale

    # The locales `I18n.locale=` and `Request#preferred_locale` accept.
    # Empty (the default) means just {#i18n_default_locale}; read the
    # effective list with {#i18n_locales}.
    # @example config/app.rb
    #   config.i18n_available_locales = [:en, :ja]
    # @return [Array<Symbol>]
    # @api public
    attr_accessor :i18n_available_locales

    # Whether a missing translation raises `I18n::MissingTranslationData`
    # instead of answering a marker or the humanised key, `false`.
    # @return [Boolean]
    # @api public
    attr_accessor :i18n_raise_on_missing

    # Failed sign-ins before an account is locked, `10`, from
    # `CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS`. `0` turns lockout off.
    # @return [Integer]
    # @api public
    attr_accessor :auth_lockout_attempts

    # How long a lockout lasts, in seconds, `3600`, from
    # `CYBERTRAIN_AUTH_LOCKOUT_PERIOD`. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :auth_lockout_period

    # How long a "remember me" sign-in lasts, in seconds, `2592000` (30
    # days), from `CYBERTRAIN_AUTH_REMEMBER_FOR`. At least 1.
    # @return [Integer]
    # @api public
    attr_accessor :auth_remember_for

    # Seconds without a request after which a session ends, `604800` (7
    # days), from `CYBERTRAIN_AUTH_IDLE_TIMEOUT`. `0` turns it off.
    # @return [Integer]
    # @api public
    attr_accessor :auth_idle_timeout

    # The locales in effect: {#i18n_available_locales}, or just
    # {#i18n_default_locale} when that is empty.
    # @return [Array<Symbol>]
    # @api public
    def i18n_locales
      list = @i18n_available_locales
      return [@i18n_default_locale] if list.empty?

      list
    end

    # CYBERTRAIN_I18N_DEFAULT_LOCALE as a Symbol (`:en` when unset or
    # empty). A name boot refuses (i18n_error) is kept as written. This is
    # the one place environment text becomes a Symbol, once at startup;
    # request input never does.
    def self.default_i18n_locale
      env_or("CYBERTRAIN_I18N_DEFAULT_LOCALE", "en").to_sym
    end

    # An authentication setting's variable read as default_job_threads
    # reads its own: the default when unset or not a number, any number
    # kept for boot to refuse (auth_error).
    def self.default_auth_setting(name, default)
      Params.parse_int(env_or(name, ""), default)
    end

    # Whether text is a locale name: a 2-3 letter language, then any number
    # of `-` or `_` separated parts of 2-8 letters or digits (`en`, `ja`,
    # `pt-BR`, `zh-Hant-TW`), at most 35 bytes. A byte scan through a fresh
    # local (NOTES rule 62).
    # @param text [String]
    # @return [Boolean]
    # @api private
    def self.locale_name?(text)
      s = text.to_s
      len = s.bytesize
      return false if len < 2 || len > 35

      part = 0 # 0-based index of the part being read
      part_len = 0
      i = 0
      while i < len
        b = s.getbyte(i)
        if b == 45 || b == 95 # "-" "_"
          return false if part_len < 2
          return false if part == 0 && part_len > 3

          part += 1
          part_len = 0
        else
          letter = (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
          digit = b >= 48 && b <= 57
          return false unless letter || (digit && part > 0)

          part_len += 1
          return false if part_len > 8
        end
        i += 1
      end
      return false if part_len < 2
      return false if part == 0 && part_len > 3

      true
    end

    # CYBERTRAIN_MAX_PAGE read without to_i on unbounded text (NOTES rule
    # 25): 10000 when it is unset, not a number, or below 1.
    def self.default_max_page
      n = Params.parse_int(env_or("CYBERTRAIN_MAX_PAGE", ""), 10_000)
      n < 1 ? 10_000 : n
    end

    # CYBERTRAIN_JOB_THREADS read without to_i on unbounded text (NOTES
    # rule 25): 3 when it is unset or not a number. A number below 1 is
    # kept, so that boot reports it (scheduler_error) rather than starting
    # a different count than asked for.
    def self.default_job_threads
      Params.parse_int(env_or("CYBERTRAIN_JOB_THREADS", ""), 3)
    end

    # CYBERTRAIN_JOBS_PAGE_PER_PAGE as default_job_threads reads its
    # variable: 50 when it is unset or not a number, a number below 1 kept
    # for boot to refuse (scheduler_error).
    def self.default_jobs_page_per_page
      Params.parse_int(env_or("CYBERTRAIN_JOBS_PAGE_PER_PAGE", ""), 50)
    end

    # CYBERTRAIN_CACHE_PRUNE_INTERVAL as default_job_threads reads its
    # variable: 300 when it is unset or not a number, a number below 1
    # kept for boot to refuse (scheduler_error).
    def self.default_cache_prune_interval
      Params.parse_int(env_or("CYBERTRAIN_CACHE_PRUNE_INTERVAL", ""), 300)
    end

    # CYBERTRAIN_FEED_STATUS_INTERVAL, CYBERTRAIN_FEED_RESTART_LIMIT,
    # CYBERTRAIN_FEED_RESTART_WINDOW and CYBERTRAIN_HEALTH_FEED_STALE as default_job_threads reads its
    # variable: the default when unset or not a number, a number below 1
    # kept for boot to refuse (feeds_error).
    def self.default_feed_setting(name, default)
      Params.parse_int(env_or(name, ""), default)
    end

    # False only for CYBERTRAIN_HEALTH_FEEDS=0 or =false; anything else
    # (unset, empty, "1") is true.
    def self.default_health_feeds
      configured = ENV["CYBERTRAIN_HEALTH_FEEDS"] || ""
      !(configured == "0" || configured == "false")
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
    # validated: the server gets it as it is ("0.0.0.0" listens on every
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

    # True only for CYBERTRAIN_HTTP_ALLOW_PRIVATE=1 or =true.
    def self.default_http_allow_private
      configured = ENV["CYBERTRAIN_HTTP_ALLOW_PRIVATE"] || ""
      configured == "1" || configured == "true"
    end

    # True only for CYBERTRAIN_TRUSTED_PROXY=1 or =true, like
    # default_session_partitioned.
    def self.default_trusted_proxy
      configured = ENV["CYBERTRAIN_TRUSTED_PROXY"] || ""
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
      # Stripped, like the previous keys: a .env line's newline is not part of it.
      @encryption_key = (ENV["CYBERTRAIN_ENCRYPTION_KEY"] || "").strip
      # Typed seed (rule 9); empty entries of the comma list are dropped.
      @encryption_keys_previous = Array.new(0) { "" }
      (ENV["CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS"] || "").split(",").each do |entry|
        previous_key = entry.strip
        @encryption_keys_previous << previous_key unless previous_key.empty?
      end
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
      @log_level_given = false
      @session_cookie_name = "_cybertrain_session"
      @session_max_age = 1209600
      # Absolute session lifetime, enforced by SessionStore: the two weeks
      # generated authentication already enforced on its Session rows.
      @session_absolute_max_age = 1209600
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
      # Request.trusted_proxy's default; Application#boot installs it there
      # (the HTTP layer cannot read the Config).
      @trusted_proxy = Config.default_trusted_proxy
# Request.trusted_proxies' list, the same way: split here, checked by
# trusted_proxies_error at boot. Typed seed (rule 9), assigned in
# initialize (rule 73).
@trusted_proxies = Array.new(0) { "" }
(ENV["CYBERTRAIN_TRUSTED_PROXIES"] || "").split(",").each do |entry|
  proxy = entry.strip
  @trusted_proxies << proxy unless proxy.empty?
end
      # CYBERTRAIN_FORCE_SSL, kept as written for security_error.
      @force_ssl_text = Config.env_or("CYBERTRAIN_FORCE_SSL", "")
      @force_ssl = @force_ssl_text == "1" || @force_ssl_text == "true"
      # CYBERTRAIN_HOSTS: checked by security_error, appended to
      # allowed_hosts (typed seed, rule 9).
      @hosts_from_env = Array.new(0) { "" }
      (ENV["CYBERTRAIN_HOSTS"] || "").split(",").each do |entry|
        env_host = entry.strip
        next if env_host.empty?

        @hosts_from_env << env_host
        @allowed_hosts << env_host
      end
      @permissions_policy = "camera=(), microphone=(), geolocation=()"
      # Off until config/app.rb declares one (as in Rails).
      @content_security_policy = nil
      @content_security_policy_report_only = false
      @content_security_policy_nonce_directives = Array.new(0) { "" }
      @pool_size = 4
      @static_files = true
      @csrf = true
      @csrf_given = false
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
      @http_allow_private = Config.default_http_allow_private
      # Mailer's settings (CYBERTRAIN_SMTP_*). Assigned here, not in a
      # helper: an ivar first set outside initialize is boxed.
      @smtp_host = Config.env_or("CYBERTRAIN_SMTP_HOST", "")
      @smtp_port = Config.default_smtp_port
      @smtp_user = Config.env_or("CYBERTRAIN_SMTP_USER", "")
      @smtp_password = Config.env_or("CYBERTRAIN_SMTP_PASSWORD", "")
      @smtp_from = Config.env_or("CYBERTRAIN_SMTP_FROM", "")
      @smtp_tls = Config.env_or("CYBERTRAIN_SMTP_TLS", "starttls").downcase
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
      # The background thread (Scheduler, Job).
      @worker = Config.bool_from_env("CYBERTRAIN_WORKER", true)
      @reuse_port = Config.bool_from_env("CYBERTRAIN_REUSE_PORT", false)
      @scheduler_interval = 1
      @job_poll_interval = 1
      @job_max_attempts = 5
      @job_threads = Config.default_job_threads
      @job_heartbeat_interval = 30
      @job_heartbeat_stale = 300
      @job_drain_timeout = 10
      @jobs_page_per_page = Config.default_jobs_page_per_page
      @cache_prune_interval = Config.default_cache_prune_interval
      @feed_status_interval = Config.default_feed_setting("CYBERTRAIN_FEED_STATUS_INTERVAL", 10)
      @feed_restart_limit = Config.default_feed_setting("CYBERTRAIN_FEED_RESTART_LIMIT", 10)
      @feed_restart_window = Config.default_feed_setting("CYBERTRAIN_FEED_RESTART_WINDOW", 600)
      @scheduler_lease_ttl = 30
      @time_zone = Config.env_or("CYBERTRAIN_TIME_ZONE", "UTC")
      # "" (unset): scheduler_tz answers time_zone.
      @scheduler_tz = Config.env_or("CYBERTRAIN_SCHEDULER_TZ", "")
      # ParameterFilter.names' list; Application#boot installs it there.
      @filter_parameters = Config.default_filter_parameters
      # The health check (HealthCheck). An empty variable turns it off,
      # unlike Config.env_or's "empty counts as unset": there is no other
      # way to switch off a default-on path from the environment.
      @health_path = ENV["CYBERTRAIN_HEALTH_PATH"] || "/up"
      @health_worker_stale = 300
      @health_feeds = Config.default_health_feeds
      @health_feed_stale = Config.default_feed_setting("CYBERTRAIN_HEALTH_FEED_STALE", 180)
      # The realtime endpoint (Stream, Stream::Endpoint); an empty variable
      # turns it off, as for health_path.
      @stream_path = ENV["CYBERTRAIN_STREAM_PATH"] || "/cybertrain/stream"
      @stream_poll_ms = 100
      @stream_retention = 60
      @stream_ping_interval = 15
      @stream_max_connections = 1000
      @stream_max_message = 65536
      @stream_max_backlog = 1000
      @i18n_default_locale = Config.default_i18n_locale
      @i18n_available_locales = []
      @i18n_raise_on_missing = false
      @auth_lockout_attempts = Config.default_auth_setting("CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS", 10)
      @auth_lockout_period = Config.default_auth_setting("CYBERTRAIN_AUTH_LOCKOUT_PERIOD", 3600)
      @auth_remember_for = Config.default_auth_setting("CYBERTRAIN_AUTH_REMEMBER_FOR", 2_592_000)
      @auth_idle_timeout = Config.default_auth_setting("CYBERTRAIN_AUTH_IDLE_TIMEOUT", 604_800)
    end

    # The parameter names whose values are replaced with `[FILTERED]` in the
    # request log's `Started` line and on the development error page
    # (Rails' `filter_parameters`): `password`, `password_confirmation`,
    # `token`, `secret`, `secret_key_base`, `session_key`, `api_key` and
    # `authorization`, or the comma-separated names in
    # `CYBERTRAIN_FILTER_PARAMETERS` instead. A parameter is filtered when
    # its name contains one of them, ASCII case-insensitively (`password`
    # filters `user[password]`). `[]` turns filtering off.
    # @example config/app.rb
    #   config.filter_parameters = config.filter_parameters + ["otp", "ssn"]
    # @return [Array<String>]
    # @api public
    attr_accessor :filter_parameters

    # ParameterFilter::DEFAULT_NAMES, kept as a literal here (the HTTP layer
    # is not required by Config), or CYBERTRAIN_FILTER_PARAMETERS split on
    # commas, blanks dropped, when it is set and not empty. Typed seed
    # (spikes/NOTES.md rule 9).
    def self.default_filter_parameters
      names = Array.new(0) { "" }
      configured = env_or("CYBERTRAIN_FILTER_PARAMETERS", "")
      if configured.empty?
        ["password", "password_confirmation", "token", "secret", "secret_key_base",
         "session_key", "api_key", "authorization"].each { |n| names << n }
      else
        configured.split(",").each do |entry|
          name = entry.strip
          names << name unless name.empty?
        end
      end
      names
    end

    # Declares the application's Content Security Policy (spec section 5,
    # C-5): yields it to the block, made on the first call. Off by
    # default; {ContentSecurityPolicyHeader} writes it on every response,
    # and a controller adjusts its own copy with
    # {Controller.content_security_policy}.
    # @example config/app.rb
    #   c.content_security_policy do |p|
    #     p.default_src :self
    #     p.script_src :self, "https://cdn.jsdelivr.net"
    #     p.style_src :self
    #   end
    #   c.content_security_policy_nonce_directives = %w[script-src style-src]
    # @yieldparam policy [ContentSecurityPolicy]
    # @return [nil]
    # @api public
    def content_security_policy(&block)
      policy = @content_security_policy
      if policy.nil?
        policy = ContentSecurityPolicy.new
        @content_security_policy = policy
      end
      block.call(policy)
      nil
    end

    # The policy {#content_security_policy} declared, nil when none was.
    # @return [ContentSecurityPolicy, nil]
    # @api public
    def content_security_policy_value
      @content_security_policy
    end

    # Whether HostAuthorization checks the Host header: always in
    # development, elsewhere only when `CYBERTRAIN_HOSTS` named hosts
    # (spec C-11; empty means no check, as Rails' production default).
    # @return [Boolean]
    # @api public
    def host_check?
      development? || !@hosts_from_env.empty?
    end

    # The Host names HostAuthorization accepts: {#allowed_hosts} and any
    # {#hosts_from_env} entry not already among them (config/app.rb may
    # assign either).
    # @return [Array<String>]
    # @api public
    def checked_hosts
      names = Array.new(0) { "" }
      @allowed_hosts.each { |h| names << h }
      @hosts_from_env.each { |h| names << h unless names.include?(h) }
      names
    end

    # Whether cookies are written `Secure`: {#session_secure}, or
    # {#force_ssl} (every request is https then).
    # @return [Boolean]
    # @api public
    def secure_cookies?
      @session_secure || @force_ssl
    end

    # Whether `text` is a host name as a Host header carries it, without
    # the port: letters, digits, `-` and `.` (neither first nor last), or
    # an IPv6 address in brackets. No scheme, path, port, userinfo or
    # wildcard. Reads its parameter through a fresh local (NOTES rule 62).
    # @param text [String]
    # @return [Boolean]
    # @api private
    def self.host_name?(text)
      s = text.to_s
      n = s.bytesize
      return false if n == 0 || n > 255

      if s.getbyte(0) == 0x5b # "["
        return false if n < 3 || s.getbyte(n - 1) != 0x5d # "]"

        i = 1
        while i < n - 1
          b = s.getbyte(i)
          ok = (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46) || b == 0x3a || b == 0x2e
          return false unless ok

          i += 1
        end
        return true
      end
      first = s.getbyte(0)
      last = s.getbyte(n - 1)
      return false if first == 0x2e || first == 0x2d || last == 0x2e || last == 0x2d

      i = 0
      while i < n
        b = s.getbyte(i)
        ok = (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7a) || (b >= 0x41 && b <= 0x5a) || b == 0x2d || b == 0x2e
        return false unless ok

        i += 1
      end
      true
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

    # Whether boot requires {#encryption_key}: gen/app.rb sets it when a
    # model declares `encrypts` (it is the application's, not one Config's,
    # so a test that replaces Cybertrain.config keeps it).
    @encryption_required = false

    # @return [Boolean] whether a model declares `encrypts`
    def self.encryption_required
      @encryption_required
    end

    # Set by gen/app.rb (true when a model declares `encrypts`).
    # @param value [Boolean]
    def self.encryption_required=(value)
      @encryption_required = value
    end

    # Whether `text` is 64 hex digits, either case: an encryption key.
    def self.encryption_key_text?(text)
      s = text.to_s
      return false unless s.bytesize == 64

      i = 0
      while i < 64
        b = s.getbyte(i).to_i
        hex = (b >= 48 && b <= 57) || (b >= 97 && b <= 102) || (b >= 65 && b <= 70)
        return false unless hex

        i += 1
      end
      true
    end

    # The secret the session and cookie keys are derived from. Production must set it
    # (CYBERTRAIN_SECRET_KEY_BASE); other environments read secret_key_path,
    # creating it with a random 64-hex-digit key the first time. This is
    # the one Config method that touches the file system
    # (ConfigFiles.load_or_create_secret): the checks ({#validation_error})
    # never call it, Application#boot does once they have passed.
    def resolve_secret!
      return @secret_key_base unless @secret_key_base.empty?
      raise "CYBERTRAIN_SECRET_KEY_BASE is not set" if production?

      @secret_key_base = ConfigFiles.load_or_create_secret(@secret_key_path, SECRET_LENGTH)
    end

    # mkdir -p (ConfigFiles.make_directory; kept here for its callers).
    def self.make_directory(dir, mode = 0o777)
      ConfigFiles.make_directory(dir, mode)
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

require "cybertrain/config/validation"
