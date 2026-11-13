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
| `CYBERTRAIN_ENV` | `env` | `"development"`; `"production"` in a binary from `cybertrain build` (also `"test"`) |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
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
| `CYBERTRAIN_WORKER` | `worker` | `true`; `0` or `false` keeps a `server` process from running scheduled tasks, jobs and WebSocket feeds (see [Process roles](background-and-operations.md#process-roles)); `./<app> worker` and `feeds` ignore it |
| `CYBERTRAIN_JOB_THREADS` | `job_threads` | `3`: how many jobs one process runs at once (see [Background work](background-and-operations.md#background-work)); at least 1 |
| `CYBERTRAIN_TIME_ZONE` | `time_zone` | `"UTC"`: the application's zone, an IANA name such as `Asia/Tokyo`, for `Time.zone`, the day and month boundaries, `Date.current`, `l` and `time_tag` (see [Time zones](#time-zones)); one the system's zoneinfo does not have stops the boot |
| `CYBERTRAIN_SCHEDULER_TZ` | `scheduler_tz` | `time_zone` when unset: the zone a `Scheduler.cron` task without `tz:` is read in, an IANA name (see [Time zones](#time-zones)); one the system's zoneinfo does not have stops the boot |
| `CYBERTRAIN_JOBS_PAGE_PER_PAGE` | `jobs_page_per_page` | `50`: rows per list on the [jobs page](background-and-operations.md#the-jobs-page-and-the-jobs-command); at least 1 |
| `CYBERTRAIN_CACHE_PRUNE_INTERVAL` | `cache_prune_interval` | `300`: seconds between the prunes of expired [cache](background-and-operations.md#the-cache-store) rows, read when `cybertrain/cache` is required; at least 1 |
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
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`; also `tls` (implicit TLS) or `none` (plain text, credentials to loopback only); both TLS modes need `require "cybertrain/net/tls"` |
| `CYBERTRAIN_MAIL_DELIVERY_METHOD` | `mail_delivery_method` | `:test` in the test environment, `:smtp` in every other: `:test` keeps each mail in `Cybertrain::Mailer.deliveries` instead of sending it ([Testing mail](testing.md#testing-mail)); outside the test environment it boots with a warning and sends nothing; anything else stops the boot. `cybertrain test` uses `:test` unless `config/app.rb` sets it, whatever the variable says |
| `CYBERTRAIN_TEST_DATABASE` | — | `""`: the file `cybertrain test` deletes, migrates and runs the tests on, instead of `storage/test.sqlite3`; a file path (not `:memory:` or a `file:` URI). An existing file is deleted only when `cybertrain test` created it (it marks its databases), is this application's own `storage/test.sqlite3` or is empty; any other, and the development or production database, is refused with exit status 2 and nothing deleted ([Running the tests](testing.md#running-the-tests)) |
| `CYBERTRAIN_I18N_DEFAULT_LOCALE` | `i18n_default_locale` | `:en`: the locale every request starts in, a name such as `ja` or `pt-BR` (see [Locales](#locales)); anything else stops the boot |
| `CYBERTRAIN_AUTH_LOCKOUT_ATTEMPTS` | `auth_lockout_attempts` | `10`: wrong passwords before an account is locked; `0` turns lockout off (see [Authentication settings](#authentication-settings)) |
| `CYBERTRAIN_AUTH_LOCKOUT_PERIOD` | `auth_lockout_period` | `3600`: seconds a lockout lasts; at least 1 |
| `CYBERTRAIN_AUTH_REMEMBER_FOR` | `auth_remember_for` | `2592000` (30 days): seconds a "keep me signed in" sign-in lasts; at least 1 |
| `CYBERTRAIN_AUTH_IDLE_TIMEOUT` | `auth_idle_timeout` | `604800` (7 days): seconds without a request after which a sign-in ends; `0` turns it off |

Use `None` (with `CYBERTRAIN_SESSION_PARTITIONED=1`) only for an app shown
inside another site's frame; the browser must reach the app over HTTPS.

Other attributes with fixed, overridable defaults: `views_root`
(`"app/views"`), `public_root` (`"public"`), `layout`
(`"layouts/application"`), `log_level` (`:info`), `session_cookie_name`,
`session_max_age` (2 weeks), `session_secure` (`true` in production, which
marks the session cookie `Secure`; `false` elsewhere, though `SameSite=None`
and `Partitioned` add `Secure` anyway), `pool_size` (4), `static_files`/`csrf`
(`true`), `csrf_exempt_prefixes` (`[]`: path prefixes such as `"/api/"` whose
non-GET requests skip the CSRF check, for an endpoint that programs call with
a credential of their own; each must start and end with `/` and not be `/`
alone, or boot fails; the prefix is matched on the path as sent, so a
percent-encoded spelling is still checked; no other route may match a path
under the prefix, and the exempt controller must not rely on the session
for authentication, since the session is still loaded there), `max_body_bytes`
(10 MiB: a longer request body, as sent, is answered 413 before it is read;
raise it for large uploads; a gzip body's inflated size is bounded separately
by `request.decoded_body(limit)`), `max_render_depth` (12 renders open at once: the page and its
partials; raise it for partials that legitimately recurse deeper; it must be
at least 1, or boot fails). Upgrade note: render nesting, unlimited before, is
now capped at 12 by default (the page is depth 1, so partials can nest 11
levels; the layout renders after the page and does not nest), and an app with
a deeper tree (threaded comments, a category menu) gets a template error until
it sets `max_render_depth`. File uploads: `max_upload_bytes` (5 MiB per
uploaded file; it must not exceed `max_body_bytes`), `max_multipart_parts`
(128 parts, text fields included, at most 4096), `upload_root`
(`"storage/uploads"`, where `Cybertrain::BlobStore` writes; created on the
first upload, not at boot).

**Jobs and streams:** besides the variables above, `config/app.rb` sets
`scheduler_interval` (1 s, the scheduler's tick), `job_poll_interval` (1 s,
how long an idle job thread waits; it was 5 before job threads),
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
(migrate on boot, then serve on `0.0.0.0:3000`), a `.dockerignore`,
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
logs a `[WARN]` line saying so. Reading an undeclared name, or one declared
with another type, raises `ArgumentError`, as does declaring a name twice.
Tests change a value with `set_string_setting`, `set_int_setting` and
`set_bool_setting`. `./NAME help` lists every declared setting with its
variable and default, and the boot banner prints the current values
(`=> Settings: base_url="" worker=true ...`); a `secret: true` setting shows
up in both only by name, as `[FILTERED]`. There is no
`Cybertrain.config.base_url` accessor: Spinel has no `define_method`, so the
readers are typed methods that take the name.

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

## Time zones

Spinel ships no tz database, and setting `ENV["TZ"]` to convert a time
changes it for every thread of the process. `Cybertrain::TimeZone` reads the
system's zone files instead: `/usr/share/zoneinfo/<name>`, or `$TZDIR/<name>`
when `TZDIR` is set (install the `tzdata` package in a slim container image).
It parses TZif versions 1 to 4 (RFC 8536), including the POSIX TZ rule a
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
