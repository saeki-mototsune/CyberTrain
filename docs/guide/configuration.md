# Configuration

## Configuration and environment variables

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

`Cybertrain::Config` reads the environment first; `config/app.rb` overrides:

| Variable | Attribute | Default |
| --- | --- | --- |
| `CYBERTRAIN_ENV` | `env` | `"development"`; `"production"` in a binary from `cybertrain build` (also `"test"`). Set the variable, not `c.env`: `database_path`, `session_secure` and the default `mail_delivery_method` are derived from it before `config/app.rb` runs |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `DATABASE_URL` | `database_url` | `""`; MySQL only: the database an application built with `cybertrain/mysql` connects to, `mysql://USER:PASSWORD@HOST:3306/NAME` (see [MySQL](#mysql)); boot fails when it is empty or malformed |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | required in production; dev/test auto-generate one into `tmp/secret_key` |
| `CYBERTRAIN_ENCRYPTION_KEY` | `encryption_key` | `""`; 64 hex characters (`cybertrain secret --hex`), the key of the columns a model `encrypts`. Boot fails when it is malformed, or empty once a model declares `encrypts` (see [Encrypted columns](models.md#encrypted-columns)) |
| `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS` | `encryption_keys_previous` | `[]`; comma-separated earlier keys, tried for decryption only, so a key can be rotated by saving the records again; a malformed entry stops the boot |
| `SPINEL_WORKERS` | `workers` | `1`; the development server always serves with one and ignores this ([why](template-language.md#file-resolution-enginerb)) |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`; `0.0.0.0` listens on every interface (containers) |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | Development accepts `localhost`, `127.0.0.1`, `[::1]`; comma-separated exact hostnames extend this list (no scheme, port or wildcard). Other hosts get 403 before static files, sessions, routing or diagnostics. This is separate from the listening address; production and test apply this list only once `CYBERTRAIN_HOSTS` turns the check on there |
| `CYBERTRAIN_HOSTS` | `hosts_from_env` (appended to `allowed_hosts`) | `[]`; comma-separated exact host names (an IPv6 address in brackets; no scheme, path, port or wildcard, or boot fails), appended after the loopback names in every environment. Set, they turn the host check on in production and test too: another `Host` answers 403 `Blocked host` and is logged. A GET or HEAD of the health path passes whatever the Host (see [Hosts](requests.md#content-security-policy-force_ssl-and-hosts)) |
| `CYBERTRAIN_FORCE_SSL` | `force_ssl` | `false`; `1` or `true` redirects http to https (301 for GET and HEAD, 307 otherwise; by `X-Forwarded-Proto` behind a proxy), sends `Strict-Transport-Security: max-age=63072000; includeSubDomains` and writes every cookie `Secure`; the health path is never redirected. Anything but `1`, `true`, `0`, `false` or empty stops the boot. Behind a proxy, also set `CYBERTRAIN_TRUSTED_PROXY` or `CYBERTRAIN_TRUSTED_PROXIES`, or the URLs the app builds stay http |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`; also `Strict` or `None` (`None` always adds `Secure`); anything else stops the server at boot |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`; `1` or `true` adds `Partitioned` (and `Secure`) |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`; `1` or `true` makes `request.client_ip` (what `rate_limit` counts) the last `X-Forwarded-For` address of a connection from loopback, for a reverse proxy on the same host (see [Rate limiting](requests.md#rate-limiting-and-the-client-address)); shorthand for `CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`; comma-separated IPv4/IPv6 addresses or CIDRs (`172.16.0.0/12,10.0.0.0/8`) whose connections have `request.client_ip` taken from the last `X-Forwarded-For` address, for a proxy reached over a network, such as kamal-proxy in its container; a bad entry stops the server at boot |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`: the largest page `params.page_number` gives and `Relation#page` accepts (see [Pagination](models.md#pagination)); a value that is not a number of at most 18 digits, or below 1, is the default |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`; comma-separated names replace the list. A parameter whose name contains one of them (ASCII case-insensitively: `password` also matches `user[password]`) has its value written as `[FILTERED]` in the request log and on the development error page; `[]` in `config/app.rb` turns this off |
| `CYBERTRAIN_LOG_LEVEL` | `log_level` | `:info`: the least important level written, `debug`, `info`, `warn`, `error`, `fatal` or `none` (in any case; `none` turns the request log off and still writes error lines); anything else stops the boot (see [Logs](logs-and-errors.md#logs)). `cybertrain test` uses `:none` unless `config/app.rb` sets it |
| `CYBERTRAIN_LOG_FORMAT` | `log_format` | `:text`; `json` writes one JSON object per line, for a log collector; anything else stops the boot. `cybertrain test` keeps text lines unless `config/app.rb` sets it, whatever the variable says |
| `CYBERTRAIN_SENTRY_DSN` | `sentry_dsn` | `""`: nothing is sent. A Sentry or GlitchTip DSN sends each error report there (see [Error reporting](logs-and-errors.md#error-reporting)); it needs `require "cybertrain/error_reporter/sentry"` (or `require "cybertrain"`) in `bin/<app>.rb`, or the boot is refused. One that does not parse stops the boot, naming the part and never the key. `cybertrain test` empties it unless `config/app.rb` assigns it |
| `CYBERTRAIN_ERROR_SAMPLE_RATE` | `error_sample_rate` | `1.0`: the share of error reports sent to Sentry, from 0.0 to 1.0, written as digits with an optional `.digits`; subscribers see every report; anything else stops the boot |
| `CYBERTRAIN_RELEASE` | `release` | `""`: the version or commit sent with each error report |
| `CYBERTRAIN_WORKER` | `worker` | `true`; `0` or `false` keeps a `server` process from running scheduled tasks, jobs and WebSocket feeds (see [Process roles](background-and-operations.md#process-roles)); `./<app> worker` and `feeds` ignore it |
| `CYBERTRAIN_JOB_THREADS` | `job_threads` | `3`: how many jobs one process runs at once (see [Background work](background-and-operations.md#background-work)); at least 1 |
| `CYBERTRAIN_TIME_ZONE` | `time_zone` | `"UTC"`: the application's zone, an IANA name such as `Asia/Tokyo`, for `Time.zone`, the day and month boundaries, `Date.current`, `l` and `time_tag` (see [Time zones](#time-zones)); one the system's zoneinfo does not have stops the boot |
| `CYBERTRAIN_SCHEDULER_TZ` | `scheduler_tz` | `time_zone` when unset: the zone a `Scheduler.cron` task without `tz:` is read in, an IANA name (see [Time zones](#time-zones)); one the system's zoneinfo does not have stops the boot |
| `CYBERTRAIN_JOBS_PAGE_PER_PAGE` | `jobs_page_per_page` | `50`: rows per list on the [jobs page](background-and-operations.md#the-jobs-page-and-the-jobs-command); at least 1 |
| `CYBERTRAIN_CACHE_PRUNE_INTERVAL` | `cache_prune_interval` | `300`: seconds between the prunes of expired [cache](background-and-operations.md#the-cache-store) rows, at least 1. With `cybertrain/jobs` it is read once, when the scheduled prune is registered as the two are required, before `config/app.rb` runs, so set the variable; without jobs it is read at each cache write, so `c.cache_prune_interval` works too |
| `CYBERTRAIN_FEED_STATUS_INTERVAL` | `feed_status_interval` | `10`: seconds between the writes of each WebSocket feed's status row (see [Feed health](realtime.md#feed-health)); at least 1 |
| `CYBERTRAIN_FEED_RESTART_LIMIT` | `feed_restart_limit` | `10`: restarts of one feed's thread within the window after which a `feeds` process exits with status 1 when it dies again (see [Consuming WebSocket feeds](external-services.md#consuming-websocket-feeds)); at least 1 |
| `CYBERTRAIN_FEED_RESTART_WINDOW` | `feed_restart_window` | `600`: that window, in seconds; at least 1 |
| `CYBERTRAIN_STREAM_PATH` | `stream_path` | `"/cybertrain/stream"`: the realtime endpoint (see [Realtime](realtime.md#limits-and-settings)); an empty value turns streams off; it must start with `/` and differ from `health_path` |
| `CYBERTRAIN_REUSE_PORT` | `reuse_port` | `false`; `1` or `true` binds with `SO_REUSEPORT`, so several processes can listen on one port and, on Linux, the kernel splits connections between them (ignored in development; see [Running several processes](../deploy.en.md#running-several-processes)). Run `CYBERTRAIN_WORKER=0` on all but one |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`; the built-in health check's path (see [Operations](background-and-operations.md#operations-backups-vacuum-health-check)); an empty value turns it off; one without a leading `/` stops the server at boot. `health_worker_stale` (300 s) is set in `config/app.rb` |
| `CYBERTRAIN_HEALTH_FEEDS` | `health_feeds` | `true`: the health check also answers `503 feed stale` for a WebSocket feed that stopped reporting or went silent (see [Feed health](realtime.md#feed-health)); `0` or `false` turns that part off |
| `CYBERTRAIN_HEALTH_FEED_STALE` | `health_feed_stale` | `180`: seconds of a feed's silence, or of its process not writing its status, before `503 feed stale`; at least 1, and more than `feed_status_interval` while `health_feeds` is on (boot refuses it otherwise) |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`; `1` or `true` lets `Cybertrain::HttpClient` connect to loopback, private and other non-public addresses (see [Outbound HTTP](external-services.md#outbound-http)) |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`; the SMTP server `Cybertrain::Mailer` sends through (see [Sending e-mail](external-services.md#sending-e-mail)) |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`: the mode's port, 587 for `starttls`, 465 for `tls`, 25 for `none`; anything but 1 to 65535 is 0 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`: no AUTH; set, the mailer authenticates with AUTH PLAIN |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`; a secret, never logged, never in the boot banner or an error message |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`: the sender `Mailer.deliver` uses when it is not given `from:` |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`; also `tls` (implicit TLS) or `none` (plain text, credentials to loopback only); both TLS modes need `require "cybertrain/net/tls"` in `bin/<app>.rb`: `require "cybertrain"` loads it, `cybertrain/core` and `cybertrain/mailer` do not ([Subsystems](how-it-works.md#subsystems)) |
| `CYBERTRAIN_MAIL_DELIVERY_METHOD` | `mail_delivery_method` | `:test` in the test environment, `:smtp` in every other: `:test` keeps each mail in `Cybertrain::Mailer.deliveries` instead of sending it ([Testing mail](testing.md#testing-mail)); outside the test environment it boots with a warning and sends nothing; anything else stops the boot. `cybertrain test` uses `:test` unless `config/app.rb` sets it, whatever the variable says |
| `CYBERTRAIN_TEST_DATABASE` | — | `""`: the file `cybertrain test` deletes, migrates and runs the tests on, instead of `storage/test.sqlite3`; a file path (not `:memory:` or a `file:` URI). An existing file is deleted only when `cybertrain test` created it (it marks its databases), is this application's own `storage/test.sqlite3` or is empty; any other, and the development or production database, is refused with exit status 2 and nothing deleted ([Running the tests](testing.md#running-the-tests)) |
| `CYBERTRAIN_I18N_DEFAULT_LOCALE` | `i18n_default_locale` | `:en`: the locale every request starts in, a name such as `ja` or `pt-BR` (see [Locales](#locales)); anything else stops the boot |
| `CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS` | `auth_lockout_attempts` | `10`: wrong passwords before an account is locked; `0` turns lockout off (see [Authentication settings](#authentication-settings)) |
| `CYBERTRAIN_AUTH_LOCKOUT_PERIOD` | `auth_lockout_period` | `3600`: seconds a lockout lasts; at least 1 |
| `CYBERTRAIN_AUTH_REMEMBER_FOR` | `auth_remember_for` | `2592000` (30 days): seconds a "keep me signed in" sign-in lasts; at least 1 |
| `CYBERTRAIN_AUTH_IDLE_TIMEOUT` | `auth_idle_timeout` | `604800` (7 days): seconds without a request after which a sign-in ends; `0` turns it off |

`cybertrain test` gives its tests values of its own for some of these, unless
`config/app.rb` assigns them. Besides the four rows that say so, `force_ssl`
is off and `CYBERTRAIN_HOSTS` is emptied whatever the variables say, `csrf` is
off, `upload_root` is `tmp/test_uploads`, and `smtp_from` is
`"from@example.com"` unless `CYBERTRAIN_SMTP_FROM` is set
([Running the tests](testing.md#running-the-tests)).

Use `None` (with `CYBERTRAIN_SESSION_PARTITIONED=1`) only for an app shown
inside another site's frame; the browser must reach the app over HTTPS.

Other attributes have no variable; `config/app.rb` sets them:

| Attribute | Default | Meaning |
| --- | --- | --- |
| `views_root` | `"app/views"` | Where templates are read from in development and test; a built binary uses the ones embedded in it |
| `public_root` | `"public"` | The static files' directory, and where the `public/<status>.html` error pages are found |
| `layout` | `"layouts/application"` | The layout every page renders in; ignored when the file does not exist |
| `secret_key_path` | `"tmp/secret_key"` | Where development and test keep their generated secret |
| `log_tags` | `[:request_id]` | The request's tags on each log line: `:remote_ip` adds the client's address, `[]` shows none, anything else stops the boot ([Request ids](logs-and-errors.md#request-ids)) |
| `session_cookie_name` | `"_cybertrain_session"` | The session cookie's name |
| `session_max_age` | `1209600` (2 weeks) | The session cookie's `Max-Age` in seconds; it restarts whenever the session changes |
| `session_absolute_max_age` | `1209600` (2 weeks) | The longest a session lives in seconds, however often it is used: an older cookie loads as an empty session. `0` turns the limit off |
| `session_secure` | `true` in production, `false` elsewhere | Marks the session cookie `Secure`; `SameSite=None` and `Partitioned` add `Secure` anyway |
| `pool_size` | `4` | SQLite connections in the pool |
| `static_files` | `true` | Whether `public/` is served; turn it off when a reverse proxy serves it |
| `csrf` | `true` | Whether a non-GET request must carry the CSRF token (403 without it) |
| `csrf_exempt_prefixes` | `[]` | Path prefixes whose non-GET requests skip the CSRF check (see below) |
| `max_body_bytes` | `10485760` (10 MiB) | A longer request body, as sent, is answered 413 before it is read; raise it for large uploads. A gzip body's inflated size is bounded separately, by `request.decoded_body(limit)` |
| `body_timeout` | `120` | Seconds the whole request body may take, from the end of the head; past it the request is answered 408 and the connection closes, however steadily the client sends (slowloris). Raise it for large uploads over slow links |
| `max_connections` | `1024` | Connections open at once, stream connections included; one more is answered 503 and closed. Each connection holds a file descriptor, so keep it well below the process's limit (`ulimit -n`), leaving room for the listener, logs, the database and other open files: past the limit the server cannot accept a connection even to answer 503 |
| `max_render_depth` | `12` | Renders open at once, the page and its partials: the page is depth 1, so partials nest 11 levels (the layout renders after the page and does not nest). Deeper is a template error; at least 1, or boot fails |
| `max_upload_bytes` | `5242880` (5 MiB) | The largest single uploaded file; it must not exceed `max_body_bytes` |
| `max_multipart_parts` | `128` | The most parts in one multipart body, text fields included; at most 4096 |
| `upload_root` | `"storage/uploads"` | Where `Cybertrain::BlobStore` writes; created on the first upload, not at boot |

**CSRF-exempt prefixes:** `csrf_exempt_prefixes` is for an endpoint that
programs call with a credential of their own, such as `"/api/"`. Each prefix
must start and end with `/` and not be `/` alone, or boot fails. It is matched
on the path as sent, so a percent-encoded spelling is still checked. No other
route may match a path under the prefix, and the exempt controller must not
rely on the session for authentication, since the session is still loaded
there.

**Jobs and streams:** besides the variables above, `config/app.rb` sets
`scheduler_interval` (1 s, the scheduler's tick), `job_poll_interval` (1 s,
how long an idle job thread waits),
`job_max_attempts` (5), `job_heartbeat_interval` (30 s),
`job_heartbeat_stale` (300 s, more than the interval),
`job_drain_timeout` (10 s, how long `SIGTERM` waits for running jobs) and
`scheduler_lease_ttl` (30 s, at least twice `scheduler_interval`), and the
stream settings `stream_poll_ms`, `stream_retention`,
`stream_ping_interval`, `stream_max_connections`, `stream_max_message` and
`stream_max_backlog` ([Limits and settings](realtime.md#limits-and-settings)).
A value out of range stops the boot with a message naming it.

**Security headers:** every response the server writes (actions, the
static-file middleware, error pages and the development diagnostics page,
the server's own 400/411/413/500, and HEAD) carries
`X-Content-Type-Options: nosniff`, `X-Frame-Options: SAMEORIGIN` and
`Permissions-Policy: camera=(), microphone=(), geolocation=()`, unless
the response already sets a header of that name (any case): `Response#to_http`
adds them after the response's own headers and only when missing, so
`response.set_header("X-Frame-Options", "DENY")` in an action sends exactly
your value, once. `c.permissions_policy` replaces the third one's value
(`"camera=(), microphone=(), geolocation=(self)"`), `""` sends none, and a
CR or LF in it stops the boot. There is deliberately no `Config`
switch to turn the first two off app-wide; an embeddable widget overrides the header
on its own responses (a `Content-Security-Policy: frame-ancestors ...` header
takes precedence over `X-Frame-Options` in current browsers). Because of
`nosniff`, browsers take `Content-Type` literally: the static-file middleware
knows the usual `public/` extensions (html, css, js/mjs, images including
webp and avif, fonts, wasm, pdf, audio and video, json, csv, xml), and
anything else is served as `application/octet-stream`, a download; add the
extension to `Cybertrain::Static::EXTENSIONS` if an app needs another one
inline. A reverse proxy that serves `public/` itself bypasses these headers
(see [docs/deploy.en.md](../deploy.en.md)). `Cybertrain::Test::Client` calls the
app in-process and never serializes the response, so it does not show these
defaults; assert them on `response.to_http`.

**Content Security Policy:** off by default, as in Rails; `cybertrain new`
writes the block below commented out in `config/app.rb`.
`c.content_security_policy do |p| ... end` declares the policy (one method
per directive, `p.script_src :self, "https://cdn.jsdelivr.net"`; a second
call adds to the same policy), `c.content_security_policy_nonce_directives`
(`[]`) names the directives that get the request's nonce (a name that is not
a directive stops the boot), and `c.content_security_policy_report_only`
(`false`) sends the header as `Content-Security-Policy-Report-Only`. A
controller declares its own copy with `content_security_policy do |p|`; see
[Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts).

**Filtered parameters:** the request log's `Started GET "/login?..."` line
and the development error page (its request line, and its dump of the
params and of a JSON body) show the value of every parameter named in
`config.filter_parameters` as `[FILTERED]`, as Rails' `filter_parameters`
does, so a `?token=` in a URL or a password posted to a form that fails
does not appear in the framework's request log or on the development
error page. Only the values are replaced: the rest of the
query string is logged as sent (control characters escaped). The list
matches by substring, case-insensitively; extend it in `config/app.rb`
(`c.filter_parameters = c.filter_parameters + ["otp", "ssn"]`) or replace
it with `CYBERTRAIN_FILTER_PARAMETERS`. Values an action logs itself are not
filtered; ask `Cybertrain::ParameterFilter.filter?(name)` or
`ParameterFilter.filter_query(text)` there.

**Filtered paths:** a secret in the path itself (a share link's token in
`/results/<token>`) has no parameter name to filter by, so list the prefix
it follows: with `c.filter_path_prefixes = ["/results/"]`, the whole
segment after `/results/` is written `[FILTERED]` wherever the framework
writes a request's path: the request log's `Started` line, a `Blocked host`
line, the request of an error report and the development error page. A
prefix is compared with the path as sent, from its first byte, and must
start and end with `/` and not be `/` alone, or the boot fails. The list is
empty by default; the framework's own signed tokens (a password reset
link's) are masked by their shape without it. A reverse proxy in front
keeps a log of its own: mask the path there too.

**Deployment:** `cybertrain build` produces `dist/`: the binary `dist/NAME`
with the views embedded, `dist/public/` (static assets, or let a reverse
proxy serve it), and `dist/storage/` (the SQLite file by default) and
`dist/tmp/`. Run it from `dist/` with `CYBERTRAIN_SECRET_KEY_BASE` set;
it is production unless `CYBERTRAIN_ENV` says otherwise, and `./NAME
migrate` applies the migrations compiled into it. The binary
speaks plain HTTP/1.1 only; put nginx/Caddy in front for TLS and HTTP/2 (the
session cookie is `Secure` in production, so serve it over HTTPS). In
production an exception answers 500 and a bare error response (the router's
plain-text 404, `head :not_found`, `render plain:`) is replaced by
`public/<status>.html` when that file exists; errors an action renders as HTML
or JSON pass through. `SIGTERM` stops accepting, lets requests already in
flight finish (answered with `Connection: close`; idle keep-alive connections
are closed at once) and exits when they are done, or after the server's
`drain_timeout` (10 s). The watcher/rebuild loop never runs in production. [docs/deploy.en.md](../deploy.en.md)
(in Japanese: [docs/deploy.md](../deploy.md)) walks through it end to end: `cybertrain new`, an Ubuntu server,
systemd, Caddy with HTTPS, redeploys, rollbacks and backups.

**Kamal:** `cybertrain new` also writes what [Kamal 2](https://kamal-deploy.org)
needs: a `Dockerfile` that runs `cybertrain setup` and `cybertrain build` in an
Ubuntu build stage and copies `dist/` into a slim stage of the same release
(migrate on boot, then serve on `0.0.0.0:3000`, with
`SPINEL_GC_FULL_INTERVAL=8` set, a variable of Spinel's garbage collector that
[docs/deploy.en.md](../deploy.en.md) explains and sets for systemd too), a
`.dockerignore`,
`config/deploy.yml` (kamal-proxy with Let's Encrypt in front, the
health check on `public/up.html`, the SQLite file on a volume at
`/app/storage`) and `.kamal/secrets` (`KAMAL_REGISTRY_PASSWORD` and
`CYBERTRAIN_SECRET_KEY_BASE` from the environment). Fill in the values marked
`CHANGE ME`, commit, and `kamal setup`;
[docs/deploy-kamal.md](../deploy-kamal.md) has the details (part 8 of
the deployment tutorial).
[examples/blog](../../examples/blog#deploying-with-kamal) carries the same setup,
built against this checkout's framework.

### Application settings

An application's own settings (a public base URL, a feature switch, an
interval, an SMTP host) are declared on the same `Config`, with a type, an
environment variable and a default:

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.setting_string :base_url, env: "MYAPP_BASE_URL", default: ""
  c.setting_string :smtp_password, env: "MYAPP_SMTP_PASSWORD", default: "", secret: true
  c.setting_bool :worker, env: "MYAPP_WORKER", default: true
  c.setting_int :prune_interval, env: "MYAPP_PRUNE_INTERVAL", default: 3600, min: 1, max: 9_999_999
end

Cybertrain.config.string_setting(:base_url)
Cybertrain.config.bool_setting(:worker)
Cybertrain.config.int_setting(:prune_interval)
```

Each value is read once, when `config/app.rb` runs at startup. An empty or
unset variable means the default. A boolean takes `1`/`true` or
`0`/`false`; an integer takes decimal digits (an optional leading `-`) within
`min..max` (both optional). Any other value falls back to the default and
logs a `WARN` line saying so (a text line, whatever `log_format` says:
`config/app.rb` is still running). Reading an undeclared name, or one declared
with another type, raises `ArgumentError`, as does declaring a name twice.
Tests change a value with `set_string_setting`, `set_int_setting` and
`set_bool_setting`. `./NAME help` lists every declared setting with its
variable and default, and the boot banner prints the current values
(`=> Settings: base_url="" worker=true ...`); a `secret: true` setting shows
up in both only by name, as `[FILTERED]`. There is no
`Cybertrain.config.base_url` accessor: a setting is declared by a call on the
config object, and Spinel compiles `define_method` in a class body but
refuses one called from an instance method, so the readers are typed methods
that take the name.

### Locales

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.i18n_default_locale = :en               # or CYBERTRAIN_I18N_DEFAULT_LOCALE
  c.i18n_available_locales = [:en, :ja]
  c.i18n_raise_on_missing = true if c.test?
end
```

`i18n_available_locales` (`[]`, the default locale alone) lists the
locales `I18n.locale=` and `I18n.locale_available?` accept; boot refuses an
entry that is not a locale name, and a default that is not in a non-empty
list. `i18n_raise_on_missing` (`false`) makes a missing translation raise
`I18n::MissingTranslationData` instead of answering a marker (development
and test) or the humanised key (production). The dictionaries and the
locale per request are in [Internationalization](i18n.md).

### Authentication settings

The code `cybertrain generate authentication` writes reads four settings
(the variables are in the table above): `auth_lockout_attempts` (10) and
`auth_lockout_period` (3600 s) for [lockout](authentication.md#lockout),
`auth_remember_for` (30 days) for a "keep me signed in" sign-in, and
`auth_idle_timeout` (7 days) for an unused one
([Remember me](authentication.md#remember-me-and-session-limits)); an
unremembered sign-in lasts `session_absolute_max_age` (two weeks). A value
out of range stops the boot. The generator also declares the application
setting `base_url`, from `<APP>_BASE_URL`, where links in mails start; set
it, with https, wherever the application is served
([Links in mails](authentication.md#links-in-mails)).

## MySQL

An application is built for one database: SQLite, the default, or MySQL
8.0 (`docs/design.md` D96; CI tests 8.0.46, and no newer release yet). The
`cybertrain` entry that `bin/<app>.rb` and `bin/db.rb` require chooses it
when the application is built (gen reads the one in `bin/<app>.rb`; keep
the two the same); nothing switches it at run time:

```ruby bin/<app>.rb (excerpt)
require "cybertrain/mysql"   # every subsystem; "cybertrain/core/mysql" is the core alone
```

`cybertrain new NAME --database=mysql` writes that line, explains
`DATABASE_URL` in `config/app.rb` and `.env.example`, passes it as a
secret in `config/deploy.yml` and `.kamal/secrets`, and writes a CI
workflow that runs the tests against a MySQL service. The models,
migrations and tests are the same on both;
[Models and the database](models.md#mysql) lists what MySQL answers
differently.

An application made for SQLite moves by changing the line in both files
(its data stays in the SQLite file), and then:

- with authentication, by running `cybertrain generate authentication`
  again with the flags it was generated with (`--invite-only`,
  `--confirmable`) and `--force`. It rewrites the four files whose MySQL
  form differs: `app/commands/user_command.rb` and
  `test/integration/first_run_test.rb` (they connect to `database_url`, not
  `database_path`), `app/models/user.rb` (the lockout UPDATE, in MySQL's
  order of assignment) and `test/controllers/accounts_controller_test.rb`
  (its table's DDL and the refused deletion's error class). Read the diff
  of any of them you changed since;
- by making the edits `new --database=mysql` makes in the `Dockerfile`,
  `config/deploy.yml`, `.kamal/secrets` and `.github/workflows/ci.yml`:
  `DATABASE_URL` passed as a secret, a MySQL service in CI, and the worker
  role left commented (below).

The database is the one `DATABASE_URL` names (`database_url`, read before
`config/app.rb` runs):

```shell
export DATABASE_URL='mysql://app:PASSWORD@db.internal:3306/shop_production'
```

- `USER`, `PASSWORD` and the database name are percent-decoded (`%40` is
  `@`). The parameters after `?` are `ssl_mode`, `connect_timeout` (5
  seconds by default), `read_timeout` and `write_timeout` (30 seconds
  each, for one wait on the server, not for a whole query); any other
  name stops the boot. No message, log line or `inspect` shows the
  password.
- Keep the password in the environment or the deploy's secrets
  (`.kamal/secrets`), never in `config/app.rb` or the repository: the
  binary holds no password.
- `ssl_mode=verify`, the default, connects over TLS and checks the
  server's certificate and its host name. `ssl_mode=disabled` connects
  without TLS, and only to `localhost`, a loopback address, a private
  address (10/8, 172.16/12, 192.168/16) or a unique local IPv6 address
  written in the URL; any other host is refused. There is no mode that
  encrypts without checking the certificate.
- Without TLS, MySQL 8.0's default `caching_sha2_password` cannot check a
  password the server has not cached yet, and the connection is refused
  with a message saying so: use TLS, or give a development user
  `mysql_native_password` (on MySQL 8.0: 8.4 turns that plugin off by
  default and 9.0 removes it).
- The certificates are checked against the system's CA store, or against
  `SSL_CERT_FILE` (a bundle) or `SSL_CERT_DIR` when they are set, as every
  TLS connection of the framework is. A managed server's CA goes there.
  For Amazon RDS or Aurora MySQL, download the global bundle and name it
  (`SSL_CERT_FILE` replaces the system's bundle file for every TLS
  connection of the process, the HTTP client and mail included, so join
  the two when the application also calls other services):

```shell
curl -fsSLo /etc/ssl/certs/rds-global-bundle.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
cat /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/rds-global-bundle.pem > /etc/ssl/certs/app-ca.pem
export SSL_CERT_FILE=/etc/ssl/certs/app-ca.pem
export DATABASE_URL='mysql://app:PASSWORD@shop.abc123.ap-northeast-1.rds.amazonaws.com:3306/shop_production'
```

The `db` commands take the same database: `db create` and `db drop`
create and drop it (`utf8mb4`, collation `utf8mb4_0900_bin`); `migrate`,
`rollback`, `status`, `schema` and `schema:dump` work as on SQLite; and
`dbconsole` opens the `mysql` client on it, over TCP, with the same TLS
mode and CA, the password in the client's environment. `db backup`,
`vacuum` and `normalize` are SQLite's and exit with status 2: use
`mysqldump` or the provider's snapshots.

`cybertrain test` empties and migrates the database `DATABASE_URL` names
before the tests, so it refuses one whose name does not end in `_test`, an
environment other than `test`, and a database that has tables but not the
marker table `cybertrain_test_marker`, which it creates in an empty one. It
never creates or drops a database: make `NAME_test` once (`db create`
with that URL, or your provider's console) and export its URL for the test
run. Between tests the tables are emptied and the fixtures inserted again;
on MySQL the emptying commits before the fixtures go in (resetting the ids
is DDL), so a fixture that fails to load leaves the tables empty.

The framework's tables (jobs, streams, the cache, leases, the scheduler's
timetable, the feed state) are not in `db/schema.rb` and `db migrate` does
not make them: each is created when its feature is first used, as on
SQLite. A CREATE TABLE inside a transaction would commit the transaction
half way on MySQL, so a first use inside `DB.transaction` (a `Job.enqueue`
or a `broadcast_*` in a transaction, on a database that has never had the
table) raises `Cybertrain::DB::Error` instead and commits nothing. The
process that runs jobs creates `cybertrain_jobs` when it starts; for the
others (or for jobs enqueued before that process first starts), create the
tables once outside a transaction after the first `migrate`, for instance
with an operational command:

```ruby bin/<app>.rb (excerpt)
Cybertrain::Main.command("install_tables", "create the framework's tables") do |argv|
  Cybertrain::Job.install!
  Cybertrain::Stream.install!
  Cybertrain::Cache.install!
  0
end
```

> [!NOTE]
> One process, for now. On MySQL the jobs, streams, leases and scheduled
> tasks are guaranteed within one process (they answer as on SQLite), not
> yet across several processes or hosts sharing the database: that is
> step 2 of the MySQL roadmap (a job's claim, a stream's order, a lease's
> clock), not done yet. Run one container, the web role alone, until a
> release says otherwise; on MySQL `generate job` and `generate
> authentication` leave `config/deploy.yml`'s worker role commented.

## Time zones

Spinel ships no tz database, and setting `ENV["TZ"]` to convert a time
changes it for every thread of the process. `Cybertrain::TimeZone` reads the
system's zone files instead: `/usr/share/zoneinfo/<name>`, or `$TZDIR/<name>`
when `TZDIR` is set (install the `tzdata` package in a slim container image).
It parses TZif versions 1 to 4 (RFC 9636, which replaced RFC 8536), including the POSIX TZ rule a
"slim" file relies on after its last transition, and caches each zone for the
life of the process (copy-on-write, so lookups from several workers take no
lock).

Everything is Integer epoch seconds. A *local epoch* is a wall-clock reading
counted as if it were UTC, so wall-clock arithmetic is plain addition and
`TimeZone.civil_to_epoch` / `TimeZone.epoch_to_civil` move between it and
`[year, month, day, hour, minute, second]`:

```ruby
tokyo = Cybertrain::TimeZone.find("Asia/Tokyo")
tokyo.found?                         # false for an unknown name: the zone then behaves as UTC
tokyo.utc_offset_at(Time.now.to_i)   # => 32400
tokyo.abbreviation_at(Time.now.to_i) # => "JST"

# The next 09:00 in Tokyo:
now = Time.now.to_i
today = Cybertrain::TimeZone.epoch_to_civil(tokyo.utc_to_local(now))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2], 9, 0, 0))
run = tokyo.local_to_utc(Cybertrain::TimeZone.civil_to_epoch(today[0], today[1], today[2] + 1, 9, 0, 0)) if run <= now
```

At a daylight-saving transition `local_to_utc` is deterministic: a wall time
that a forward jump skips (02:30 on a US spring-forward day) is read with the
offset before the jump, so it lands after it (03:30 EDT); a wall time that a
backward jump repeats gives the earlier instant. `find` accepts only a
relative name made of `A-Za-z0-9_+-./` with no empty, `.` or `..` segment, so
a zone name taken from a user's profile cannot reach a file outside the zone
directory; an unknown or malformed zone is not cached, and `"UTC"` needs no
file.

### The application's zone

```ruby
# config/app.rb
Cybertrain.configure do |c|
  c.time_zone = "Asia/Tokyo"   # or CYBERTRAIN_TIME_ZONE; "UTC" by default
end
```

`c.time_zone` takes an IANA name (Rails' own names, such as "Tokyo", are not
read), and boot stops on one the system does not have. Values stay UTC
instants: a column, `Time.current` and the calendar methods answer a UTC
`Time`, and `time.hour` is the UTC hour. The zone decides the calendar
(`beginning_of_day` and its kin, `Date.current`;
[Times and the time zone](models.md#times-and-the-time-zone)) and the
display: `l(time)` and `time_tag(time)` show a Time in it, `%z` and `%Z`
included, and `time_tag`'s `datetime` is ISO 8601 with the zone's offset
(`2026-11-12T05:00:00+09:00`). `l(time, zone: "America/New_York")` and
`time_tag(time, zone: "...")` show one value in another zone. A Time at
offset 0, which is every Time the framework hands out, is shown in the
zone; a Time that carries another offset of its own
(`time.getlocal("+05:30")`) keeps it unless `zone:` is given; a Date is
shown as it is. Cron tasks without `tz:` follow the zone too, unless `scheduler_tz` is set. A
registered command (`Main.command`), `./<app> jobs` and `./<app> console`
install the zone before they run as well, and refuse an unknown one as boot
does, with `error: time_zone "Mars/Base" is not a known time zone` and exit
status 1, before the database is opened. In `cybertrain test` every test
starts in the configured zone. ([Dates and times](i18n.md#dates-and-times) has `l`'s
formats.)

## Upgrading

The settings and defaults a release changes are listed by version in
[Upgrading](upgrading.md#notes-by-version).
