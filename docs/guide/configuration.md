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
| `SPINEL_WORKERS` | `workers` | `1` |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`; `0.0.0.0` listens on every interface (containers) |
| `CYBERTRAIN_ALLOWED_HOSTS` | `allowed_hosts` | Development accepts `localhost`, `127.0.0.1`, `[::1]`; comma-separated exact hostnames extend this list (no scheme, port or wildcard). Other hosts get 403 before static files, sessions, routing or diagnostics. This is separate from the listening address; production and test do not apply this development guard |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`; also `Strict` or `None` (`None` always adds `Secure`); anything else stops the server at boot |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`; `1` or `true` adds `Partitioned` (and `Secure`) |
| `CYBERTRAIN_TRUSTED_PROXY` | `trusted_proxy` | `false`; `1` or `true` makes `request.client_ip` (what `rate_limit` counts) the last `X-Forwarded-For` address of a connection from loopback, for a reverse proxy on the same host (see [Rate limiting](requests.md#rate-limiting-and-the-client-address)); shorthand for `CYBERTRAIN_TRUSTED_PROXIES=127.0.0.0/8,::1` |
| `CYBERTRAIN_TRUSTED_PROXIES` | `trusted_proxies` | `[]`; comma-separated IPv4/IPv6 addresses or CIDRs (`172.16.0.0/12,10.0.0.0/8`) whose connections have `request.client_ip` taken from the last `X-Forwarded-For` address, for a proxy reached over a network, such as kamal-proxy in its container; a bad entry stops the server at boot |
| `CYBERTRAIN_MAX_PAGE` | `max_page` | `10000`: the largest page `params.page_number` gives and `Relation#page` accepts (see [Pagination](models.md#pagination)); a value that is not a number of at most 18 digits, or below 1, is the default |
| `CYBERTRAIN_FILTER_PARAMETERS` | `filter_parameters` | `["password", "password_confirmation", "token", "secret", "secret_key_base", "session_key", "api_key", "authorization"]`; comma-separated names replace the list. A parameter whose name contains one of them (ASCII case-insensitively: `password` also matches `user[password]`) has its value written as `[FILTERED]` in the request log and on the development error page; `[]` in `config/app.rb` turns this off |
| `CYBERTRAIN_WORKER` | `worker` | `true`; `0` or `false` keeps this process from running scheduled tasks and jobs (see [Background work](background-and-operations.md#background-work)); `scheduler_interval` (1 s), `job_poll_interval` (5 s) and `job_max_attempts` (5) are set in `config/app.rb` |
| `CYBERTRAIN_HEALTH_PATH` | `health_path` | `"/up"`; the built-in health check's path (see [Operations](background-and-operations.md#operations-backups-vacuum-health-check)); an empty value turns it off; one without a leading `/` stops the server at boot. `health_worker_stale` (300 s) is set in `config/app.rb` |
| `CYBERTRAIN_HTTP_ALLOW_PRIVATE` | `http_allow_private` | `false`; `1` or `true` lets `Cybertrain::HttpClient` connect to loopback, private and other non-public addresses (see [Outbound HTTP](external-services.md#outbound-http)) |
| `CYBERTRAIN_SMTP_HOST` | `smtp_host` | `""`; the SMTP server `Cybertrain::Mailer` sends through (see [Sending e-mail](external-services.md#sending-e-mail)) |
| `CYBERTRAIN_SMTP_PORT` | `smtp_port` | `0`: the mode's port, 587 for `starttls`, 465 for `tls`, 25 for `none`; anything but 1 to 65535 is 0 |
| `CYBERTRAIN_SMTP_USER` | `smtp_user` | `""`: no AUTH; set, the mailer authenticates with AUTH PLAIN |
| `CYBERTRAIN_SMTP_PASSWORD` | `smtp_password` | `""`; a secret, never logged, never in the boot banner or an error message |
| `CYBERTRAIN_SMTP_FROM` | `smtp_from` | `""`: the sender `Mailer.deliver` uses when it is not given `from:` |
| `CYBERTRAIN_SMTP_TLS` | `smtp_tls` | `"starttls"`; also `tls` (implicit TLS) or `none` (plain text, credentials to loopback only); both TLS modes need `require "cybertrain/net/tls"` |

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

**Security headers:** every response the server writes (actions, the
static-file middleware, error pages and the development diagnostics page,
the server's own 400/411/413/500, and HEAD) carries
`X-Content-Type-Options: nosniff` and `X-Frame-Options: SAMEORIGIN`, unless
the response already sets a header of that name (any case): `Response#to_http`
adds them after the response's own headers and only when missing, so
`response.set_header("X-Frame-Options", "DENY")` in an action sends exactly
your value, once. There is deliberately no `Config`
switch to turn them off app-wide; an embeddable widget overrides the header
on its own responses (a `Content-Security-Policy: frame-ancestors ...` header
takes precedence over `X-Frame-Options` in current browsers). Because of
`nosniff`, browsers take `Content-Type` literally: the static-file middleware
knows the usual `public/` extensions (html, css, js/mjs, images including
webp and avif, fonts, wasm, pdf, audio and video, json, csv, xml), and
anything else is served as `application/octet-stream`, a download; add the
extension to `Cybertrain::Static::EXTENSIONS` if an app needs another one
inline. A reverse proxy that serves `public/` itself bypasses these headers
(see [docs/deploy.en.md](../deploy.en.md)). `Cybertrain::Test::Client` calls the
app in-process and never serializes the response, so it does not show the two
defaults; assert them on `response.to_http`.

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
file. Formatting helpers for templates (`l(time, zone:)`) are not there yet.
