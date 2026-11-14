---
description: How a CyberTrain app is built and run (build-time code generation, optional subsystems, interpreted views, the HTTP server, SQLite via FFI, the development loop) and the differences from Rails.
---

# How it works

This page explains how a CyberTrain app is built and run: code generated at
build time, the subsystems an app requires, views interpreted at request time, the HTTP server, SQLite
through FFI and the development loop, then a table of the differences from Rails.
The home page's [performance section](site:index.html#performance) compares
the result with the same blog written in Rails 8.1. The method, every number
and how to run the measurement again are in [docs/benchmark.md](../benchmark.md).

## Build-time code generation

`spin run gen` (`bin/gen.rb`) executes `db/schema.rb`'s `create_table` DSL
and `config/routes.rb`'s `Routes.draw` DSL to get table and route *data*.
Separately it does a **lexical scan** (regexes, not a parser — Spinel exposes
none at run time) of `app/controllers/**/*.rb` and `app/models/**/*.rb` for
`@ivar =` assignments, `before_action`/`after_action`/`rescue_from ... with:`
names, `helper_method`, `layout` and `rate_limit` lines, `include`s of
concerns and zero-argument `def`s. It digests the files under `app/assets/`,
`app/javascript/` and `vendor/javascript/`, reads `config/importmap.rb`
as text, and reads the dictionaries in `config/locales/` with a YAML reader
of its own.

From that it writes plain, readable Ruby under `gen/`:

- `gen/models/<name>.rb`: accessors, casts, finders, FK-derived associations;
- `gen/routes.rb`: the route table, the dispatcher, the `*_path`/`*_url` helpers;
- `gen/controllers.rb`: `view_assigns`, `run_callback`, the `helper_method`
  table and `controller_layout` per controller;
- `gen/concerns.rb` and `gen/concerns/**`: the concerns' `included` blocks
  spliced into each including class, and the concern modules with those
  blocks blanked ([Concerns](requests.md#concerns-and-helper_method));
- `gen/assets.rb`: the digested asset paths and the import map
  ([Assets](assets.md)), with the digested files in `public/assets/`;
- `gen/locales.rb`: the application's dictionaries as two Hashes, which
  `I18n.t` reads ([Internationalization](i18n.md#dictionaries));
- `gen/migrations.rb`;
- `gen/views.rb`: the embedded views table, empty unless building for deployment;
- `gen/app.rb`: the `require_relative` manifest;
- `gen/tests.rb` and `gen/test/**`: every test of `test/` in one program,
  each test class rewritten into methods, and `gen/test/data.rb`, the
  tables and the fixtures ([Testing an app](testing.md#running-the-tests)).

`gen/` is committed, not gitignored: `spin build` and `spin test` have no hook
to generate first, so the checked-in output has to already be what compiles.
CI re-runs `spin run gen` and fails on a diff, so stale generated code can't
merge.

## Subsystems

Spinel compiles every method of every file a program requires, called or
not, and its analysis of the whole program is most of every build. So the
parts of the framework an application may not use are separate, and
`bin/<app>.rb` names the ones it does, as Rails' `config/application.rb`
lists railties:

| Line | Loads |
| --- | --- |
| `require "cybertrain/core"` | HTTP, routing, controllers, models, views and helpers (`turbo_frame_tag`, `dom_id`, `render turbo_stream:` and `format.turbo_stream` among them), assets, sessions, CSRF, CSP, the console, `db` and `migrate` |
| `require "cybertrain/jobs"` | `Job` and job classes, `Scheduler` (`every`, `cron`), the `worker` role, the `jobs` command and the jobs page |
| `require "cybertrain/streams"` | `Stream.broadcast_*`, the stream endpoint (SSE and WebSocket), `Controller#turbo_stream`, the helpers `turbo_stream_from`, `turbo_stream`, `signed_stream_name` and `stream_source_path` |
| `require "cybertrain/feeds"` | `Background`, the `feeds` role and its health check; `require "cybertrain/websocket"` (`WebSocket.subscribe`) loads it |
| `require "cybertrain/mailer"` | `Mailer.deliver` |
| `require "cybertrain/mailer/later"` | `Mailer.deliver_later`; loads the mailer and jobs |
| `require "cybertrain/cache"` | `Cache` |
| `require "cybertrain/rate_limit"` | `rate_limit` in controllers; loads the cache |
| `require "cybertrain"` | all of the above |

Each line goes after `require "cybertrain/core"` (`cybertrain/jobs` and
`cybertrain/feeds` load the core themselves, the others do not), and their
order does not matter: the framework
starts and stops the subsystems in a fixed order of its own. On a
scaffolded application, the core alone compiles 2,205 methods instead of
2,767 and analyses in 38 s instead of 52 s; a full build takes 83 s
instead of 108 s, and an edit to a controller about 47 s instead of 65 s
([docs/performance-next.md](../performance-next.md)).

`cybertrain new` writes `require "cybertrain/core"` into `bin/<app>.rb` and
`bin/db.rb` (which loads `config/app.rb`, so it needs the same lines).
`cybertrain generate job` adds `require "cybertrain/jobs"` to both, and
`generate authentication` the four its code uses (`cybertrain/jobs`,
`cybertrain/mailer`, `cybertrain/mailer/later` and `cybertrain/rate_limit`:
the jobs page, mail sent with `deliver_later`, rate-limited sign-in); the
other lines are yours to add. An application written before the split has
`require "cybertrain"`, which still loads everything: it builds and behaves
as before, and replacing that line with the core and the lines it uses is
what makes it build faster.

A missing line is caught before the application runs:

<!-- list: points -->
- Ruby code that names a missing subsystem (`ReportJob.perform_later`,
  `Cybertrain::Stream.broadcast_append_to`, `Cybertrain::Mailer.deliver`,
  `rate_limit to:`) does not compile; the error names the constant or the
  method, and the table above names its line.
- A view calling a subsystem's helper stops `spin run gen` (and `spin run
  gen -- --check`) with exit status 1:
  `app/views/articles/show.html.erb:3: turbo_stream_from needs require "cybertrain/streams" in bin/blog.rb`.
  A template rendered anyway raises `undefined helper 'turbo_stream_from'`.
- `./<app> worker`, `./<app> jobs` and `./<app> feeds` print, for example,
  `the worker role needs require "cybertrain/jobs" in bin/<app>.rb` and
  exit with 1.
- `/up` reports only on what is loaded: no worker staleness without jobs,
  no feed staleness without feeds.

gen reads `bin/<app>.rb` as text and sees only the literal
`require "cybertrain"` and `require "cybertrain/..."` lines in it: move
them into a file that `bin/<app>.rb` loads with `require_relative`, and gen
refuses a helper that would have worked. Keep them in `bin/<app>.rb`.

Without jobs the cache prunes its expired rows itself: the first write of
a process, and the first after each `cache_prune_interval`, deletes up to a
thousand of them. With jobs it is the scheduled task `"cybertrain cache
prune"`, as before ([The cache store](background-and-operations.md#the-cache-store)).

Two cases are not caught by gen: a `jobs_page` line in `config/routes.rb`
without `cybertrain/jobs` is a compile error of the generated controller
rather than gen's message, and a job whose `retry_on` or `discard_on`
names a `Cybertrain::Mailer` error makes the generated `gen/app.rb`
require `cybertrain/mailer` itself.

Tests are not cut by these lines: the program `cybertrain test` compiles
(`gen/tests.rb`) requires `cybertrain`, every subsystem, whatever
`bin/<app>.rb` requires. So `perform_enqueued_jobs`, `assert_emails` and
`assert_broadcasts` work in any application, an application on
`cybertrain/core` compiles its tests with every subsystem, and code that
names a subsystem without its line passes its tests and stops at
`spin build` ([Testing an app](testing.md)).

## Views are interpreted

`app/views/**/*.html.erb` files look like Rails ERB but are parsed into an AST
at request time, then walked by a tree-walking interpreter. Spinel has no
`eval`, so this is a closed grammar (literals, `@ivar`/local lookups, calls
through fixed per-type dispatch tables, `if`/`unless`,
`each`/`each_with_index`/one helper block), not real Ruby. The full grammar,
the helpers and the gaps are in the
[template language reference](template-language.md).

Where the source comes from depends on the mode:

- In development (and test) the engine reads `app/views/` from disk, and in
  development re-parses a template when it changes, so view edits need no
  rebuild.
- `cybertrain build` runs `SPIN_DEBUG=1 spin run gen -- --embed-views`, which
  writes every template's source into `gen/views.rb` as a string table for
  that one `spin build`, then runs `SPIN_DEBUG=1 spin run gen` again to
  restore the empty table that is committed.
- The production binary renders only that table (parsing each template once)
  and refuses to boot when it is empty
  (`error: views are not embedded in this binary`).

## The HTTP server

`Cybertrain::Server` is plain-Ruby HTTP/1.1: `TCPServer#accept` plus one
Spinel green thread per connection (M:N scheduled, no GVL), typed
`Request`/`Response`, no Rack layer. TLS/HTTP/2 are left to a reverse proxy.
`SPINEL_WORKERS` defaults to `1`: spikes found that faster and stall-free for
this I/O-bound shape at 100 concurrent connections.

The server calls an `HttpHandler` (`call(request) -> Response`);
`ContextHandler` joins it to the middleware stack, so the HTTP layer
(`cybertrain/http/`, plus `Params` and `Logger`) does not depend on the rest
of the framework. `script/check-http-layer` enforces that in CI.

## SQLite via FFI

Models talk to SQLite through Spinel's `ffi_func`/`ffi_lib` directly: no C
extension, no gem. Every query is bound, never interpolated. It's the only
adapter today (PostgreSQL via `libpq` FFI is noted as possible future work).

A pool (`SizedQueue`, 4 connections by default) hands out connections with:

- WAL;
- a busy timeout of about five seconds, waited out in a green-thread `sleep`
  (100 µs at first, then up to 1 ms) so the connection holding the lock keeps
  running even on one worker; a schema script waits inside SQLite instead
  (where SQLite's own `busy_timeout` sleeps a millisecond or more);
- up to 64 cached prepared statements;
- foreign keys on.

How a transaction checks out one of these connections, and what runs on it:
[Transactions](models.md#transactions).

## The development loop

`cybertrain server` in `development` (the default `CYBERTRAIN_ENV`, except
in a binary from `cybertrain build`) is a supervisor. It runs under CRuby,
the Ruby that runs the `cybertrain` command, holds the listening socket
itself and runs one child on it at a time: the application under CRuby
right after a change, then the compiled binary once Spinel has built it in
the background. A Ruby edit is answered at once by the CRuby preview (in
under a second on examples/blog), and the compiled program takes the port
over without you doing anything.

At the start the supervisor runs gen under CRuby (`ruby bin/gen.rb`, which
writes the same `gen/` as `spin run gen`), starts the application under
CRuby (`ruby -r cybertrain/preview bin/NAME.rb`) and starts the build. Both
run the `ruby` on `PATH`, the one `cybertrain doctor` checks for `fiddle`,
which may be another Ruby than the one that runs the `cybertrain` command.
The preview gives the framework its FFI (SQLite, zlib) through a shim over
Ruby's `fiddle` that compiles the same C the binary uses, once, into
`tmp/cybertrain-dev/ffi/`. The first build is `spin build NAME`, so an
application that has not changed since its binary was built compiles
nothing and the binary serves within a second. A first build on a binary
older than a Ruby file, and every later build, is `spin build NAME --
--incremental`: Spinel's incremental build, which recompiles only the C
units the edit changed. A Spinel release without `--incremental` rejects
the flag, and the build then runs without it. The output goes to
`tmp/rebuild.log`.

The supervisor polls `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`,
`gen/**/*.rb` and the asset roots (`app/assets/**`, `app/javascript/**`,
`vendor/javascript/**`) ten times a second. Views are excluded (both
runtimes reread them from disk), and so is `gen/views.rb`, empty in
development. A change cancels the running build, runs gen under CRuby,
replaces the child with a new CRuby child and starts a new build. When a
build succeeds and nothing has changed since, the supervisor stops the
CRuby child and starts `build/bin/NAME` on the same socket: stop, then
start, with the socket held open in between, so a request made during the
switch waits a moment and is answered. None is refused.

Every response of the application carries `X-Cybertrain-Runtime: cruby` or
`spinel`, and every HTML page one quiet line in its bottom right corner:

- `CRuby preview · Spinel building…`: CRuby rendered the page while the
  build runs.
- `Spinel ready — reload`: the compiled binary serves now; reload to see
  its page.
- `CRuby preview · Spinel build failed`: CRuby keeps serving, and the page
  shows the compiler output in a banner.
- `CRuby preview · Spinel binary failed`: the binary did not start, or
  exited; CRuby serves again, the banner shows what the binary reported,
  and the next change builds and tries it again.
- `Spinel`: the compiled binary rendered the page.
- `Source changed — reload`: a file changed after the page was rendered.
- `CRuby preview`: CRuby rendered the page and none of the above applies.

The line keeps itself current; the application's pages never reload
themselves, so a form being filled in is not lost. When gen fails, or the
application cannot boot under CRuby (a `SyntaxError`, say), the supervisor
answers every request itself with a 503 page that shows the error and what
it is waiting for; that page, the supervisor's own, refreshes itself every
2 s until a child can answer, and the save that fixes the error brings the
application back. While `cybertrain build` holds
`tmp/cybertrain-build.lock`, nothing is regenerated or restarted; the
server catches up once the lock is gone. The supervisor keeps its files in
`tmp/cybertrain-dev/`; one runs per application, and Ctrl-C stops the
build, the child and the server.

What the preview does not show:

- Whether the code compiles. The background build says so when it ends.
- The runtime differences recorded in
  [spikes/NOTES.md](../../spikes/NOTES.md) (exception ancestry, String
  encodings on sockets, `Float#round` on a narrowed Float, and the rest).
  They appear once the binary serves.
- Timing and concurrency: CRuby has a GVL and OS threads, and
  `SPINEL_WORKERS` means nothing to it.

Background work (jobs, the scheduler, the stream poller, WebSocket feeds)
runs in whichever child serves, so an edit restarts it twice, into CRuby
and then into the binary, and Server-Sent Events and WebSocket clients
reconnect twice. A page that works in the preview is done only once the
binary serves it too, and only compiled tests (`spin test`) count.

`cybertrain server --spinel` runs the compiled loop instead, as do `spin
run NAME` typed directly and the native CLI that `spin install` builds:
`SPIN_DEBUG=1 spin run gen`; `spin build NAME -- --incremental` when a
Ruby file is newer than `build/bin/NAME`; then `spin run NAME`. The binary
itself polls the same files every half second, runs `SPIN_DEBUG=1 spin run
gen && spin build NAME -- --incremental` in the background on a change,
and on success stops its listener, drains open requests and `execv`s the
new binary on the same port and PID; a failed build keeps the old binary
serving and banners the compiler output on its HTML responses (not on a
download, `Content-Disposition: attachment`, nor on a body the application
encoded, `Content-Encoding`), and rebuilds are skipped while `cybertrain build` holds its lock. The CLI and
this loop build gen, and the CLI `bin/db.rb`, in spin's debug mode
(`SPIN_DEBUG=1`, `-O0`): they run for milliseconds, and gen compiles in a
fraction of the time `-O2` takes; the application is always a release
build. When the preview cannot run, `cybertrain server` prints one line
beginning `preview unavailable:` and runs the compiled loop. That happens
when `CYBERTRAIN_ENV` names another environment than `development`, when
the application's framework is older than the preview (it lacks
`cybertrain/preview.rb` or `cybertrain/dev/supervision.rb`), when there is
no `ruby` on `PATH`, or when that `ruby` cannot be started, does not answer
within 10 s or cannot load `fiddle` (`cybertrain doctor` checks it). None
of this loads in production.

## Differences from Rails

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console`, `rails dbconsole` | `./<app> console` evaluates the template expression language over the models (Spinel has no `eval`, so not Ruby); `./<app> dbconsole` opens `sqlite3` ([The console](background-and-operations.md#the-console)) |
| `config/application.rb` requires the railties the app uses | `bin/<app>.rb` and `bin/db.rb` require `cybertrain/core` and the [subsystems](#subsystems) the app uses; `require "cybertrain"` is all of them |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` in `bin/<app>.rb`: `./<app> name ARGS` runs it with the database connected |
| Edit code, the running app picks it up | Ruby changes show at once from a CRuby preview; the compiled binary takes the port when its build finishes (`cybertrain server`) |
| Edit a view, no reload needed | Same — views are parsed from disk per request in development |
| `def new` | `def new_action` (`new` would shadow `Klass.new(ctx)`) |
| `before_action { do_thing }` (implicit `self`) | `before_action { \|c\| c.do_thing }` — no `instance_exec` on a stored block, so callbacks take the controller/record explicitly |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — nested blocks take the mapper explicitly |
| ERB compiles to a method; any object, any method | Interpreted against a fixed grammar/dispatch table ([Template language](template-language.md)) |
| Session holds any marshalled object | Session values are Strings only, in an AES-256-GCM encrypted cookie, as Rails' cookie store ([Cookies and the session](requests.md#cookies-and-the-session)) |
| Many database adapters | SQLite only, via FFI |
| `Article.transaction { ... }` returns the block's value; `raise ActiveRecord::Rollback`; `requires_new: true` savepoints | `Article.transaction { \|c\| ... }` yields the connection and returns nil; leave it by raising; nested calls join the outer transaction, no savepoints ([Transactions](models.md#transactions)) |
| `has_many :through`, enums, STI, polymorphic associations | Not implemented; `has_many`, `has_one` and `belongs_to` come from foreign keys or one-line declarations, with `dependent:`, `counter_cache:` and one level of `includes` ([Associations](models.md#associations)) |
| `pluck(:a)`, `maximum(:a)`, `group(:a).sum(:b)`, `upsert`, `update_counters`, `where(created_at: t1..t2)` | Typed flavours, as a Spinel method has one return type: `pluck_int` and its kin, `maximum_int`, `sum_float_by`, `upsert`, `increment(:col, by: n)`; a Time range is `where_between` ([Querying beyond `where`](models.md#querying-beyond-where)) |
| Any column name; an association can shadow `errors` | ASCII identifiers only; a column named like a framework method or a Ruby keyword generates as `<column>_column`, a clashing association under a fallback name ([Column names](models.md#column-names)) |
| `namespace`, `scope`, formats and `respond_to` | The same ([Routing](requests.md#routing), [Formats](requests.md#formats-and-respond_to)); JSON is answered with `render json:` (no jbuilder templates) |
| `constraints`, `mount`, glob segments | Not implemented |
| `ActiveSupport::Concern` included at run time | Concerns in `app/controllers/concerns` and `app/models/concerns`, expanded by `spin run gen` into the including classes; an `include` names a concern, and a `class_methods` method may not share an instance method's name ([Concerns](requests.md#concerns-and-helper_method)) |
| `rescue StandardError` catches a bad `JSON.parse` | Under Spinel `JSON::ParserError` is not a `StandardError`: app code must `rescue JSON::ParserError, StandardError`. The server catches it as a last resort and answers 500 |
| `skip_forgery_protection` in an API controller | CSRF runs before routing, so an API is exempted by path, `c.csrf_exempt_prefixes = ["/api/"]`, and authenticates its callers itself ([Configuration](configuration.md#configuration-and-environment-variables)) |
| Rack leaves a gzip request body as it is | A `Content-Encoding: gzip` body is `request.decoded_body`, inflated under a 10 MiB ceiling; a corrupt or oversize one is a 400; `request.body` stays as sent ([Query strings and bodies](requests.md#query-strings-and-bodies)) |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` takes only `column [ASC\|DESC]` lists; request data goes through an allowlist, raw SQL through `order_sql` ([Ordering](models.md#ordering)). Malformed or deeply nested parameters are a 400 ([Query strings and bodies](requests.md#query-strings-and-bodies)) |
| Full backtrace on an exception | Class, message, request line, template name/line — Spinel exposes no backtraces |
| Rack, its middleware, and any gem in a `Gemfile` | No Rack compatibility; a small fixed middleware set; Spinel's own `spin-index`, limited to what compiles under its Ruby subset |
| minitest / RSpec | Rails-shaped test classes (`ActiveSupport::TestCase`, `ActionDispatch::IntegrationTest`, `ViewComponent::TestCase`) and fixtures, which `spin run gen` rewrites into one program that `cybertrain test` compiles and runs; reflection-based runners can't work ahead-of-time ([Testing an app](testing.md)) |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` writes the same shape plus a sign-up page; passwords use PBKDF2-HMAC-SHA256 (bcrypt needs a C library; macOS `String#crypt` has no bcrypt); password reset, confirmation, lockout and remember me are generated too, as Devise would add them ([Authentication](authentication.md)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment` writes five `cover_*` columns and model methods; files stay on local disk under `storage/uploads/`, served by `send_blob`; one per field, no variants or direct uploads ([Add a cover image](tutorial.md#attachments)) |
| `skip_before_action :x` | The same, for named before callbacks (a block callback has no name to skip); no `skip_after_action` |
| `resource :session` | The same six routes to `SessionsController`; no nesting under it |
| `get "/x"` then `post "/x"` | Both are fine: the second route's derived name is taken, so it is unnamed, as in Rails; a duplicate `as:` is still an error |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, ActiveSupport's bundled zone data | `Cybertrain::TimeZone.find("Asia/Tokyo")` reads the system's TZif files (`/usr/share/zoneinfo`, or `TZDIR`) and converts Integer epoch seconds (`utc_offset_at`, `utc_to_local`, `local_to_utc`); `c.time_zone` sets `Time.zone` for the whole application, `in_time_zone` answers a small value with the wall fields, and a Time stays a UTC instant (no TimeWithZone, `time.hour` is UTC) ([Time zones](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` for webhooks and APIs: every wait bounded, non-public destinations refused by default, redirects only when asked for, streamed and gzip responses, a Server-Sent Events parser, no keep-alive (see [Outbound HTTP](external-services.md#outbound-http)); Spinel's `Net::HTTP` blocks the whole server on a stalled peer |
| Action Mailer (`deliver_later`, mailer classes, views) | `Cybertrain::Mailer.deliver(to:, subject:, body:, html:)` sends plain text, or `multipart/alternative` with an HTML part rendered from a partial (`Views.render_mail`), over SMTP (STARTTLS, implicit TLS or plain to loopback; AUTH PLAIN; every wait bounded); `Mailer.deliver_later` sends it from a built-in job; a mailer is a module in `app/mailers` whose methods return a `Cybertrain::MailMessage` (`deliver_later`, `deliver_now`), as the generated `PasswordsMailer` is; no attachments (see [Sending e-mail](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, recurring tasks, Mission Control | Job classes in `app/jobs` (`< Cybertrain::Job::Base`, `perform(args)` with a Hash of JSON values, `perform_later`, `retry_on`, `discard_on`, `limits_concurrency` with a key), `Job.handle(kind)` as the short form; `Scheduler.every` and `Scheduler.cron` with a time zone and a timetable kept in the database; a jobs page (`jobs_page` in the routes) and `./<app> jobs`; `job_threads` threads per process, in the server or in `./<app> worker` processes, delivered at least once ([Background work](background-and-operations.md#background-work)) |
| `Rails.cache.fetch(key, expires_in:, race_condition_ttl:)` | `Cybertrain::Cache.fetch` in the application's SQLite database, the same options; values are Strings, with `fetch_hash`, `fetch_array` and `fetch_int` for the rest; no memory or Redis store ([The cache store](background-and-operations.md#the-cache-store)) |
| ActionCable client, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` keeps a feed connected while the server runs (reconnects, pings, silence detection); `WebSocket::Client` for one synchronous connection; outbound only ([Consuming WebSocket feeds](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` is an Array of Strings matched by substring, case-insensitively (no Regexps or lambdas); it applies to the request log and the development error page ([Filtered parameters](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (a route to a controller) | `GET /up` is built in, answered before static files, session and router, so no `before_action` runs; it checks the database, the worker and the WebSocket feeds, `200 ok` or `503` ([Operations](background-and-operations.md#operations-backups-vacuum-health-check)) |
| `bin/rails db:...` tasks for backups (none built in) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, mode 0600, renamed into place) and `./<app> db vacuum` |
| Action Cable, `turbo_stream_from`, `broadcast_append_to` | The same helper names over signed streams, delivered by Server-Sent Events or WebSocket from one SQLite table; no channel classes ([Realtime](realtime.md)) |
| Propshaft, importmap-rails | The same layout (`app/assets`, `app/javascript`, `vendor/javascript`, `config/importmap.rb`), digested by `spin run gen` into `public/assets/`; no `bin/importmap pin`, no bundled Turbo ([Assets](assets.md)) |
| Rails i18n, rails-i18n's dictionaries, `I18n.t`, `t(".title")` | The same API and keys, English and Japanese bundled; `config/locales/*.yml` compiled in by `spin run gen` from a YAML subset (no anchors, aliases or tags), lists through `I18n.translate_list` ([Internationalization](i18n.md)) |

<!-- table-foot: Not exhaustive: docs/design.md §8 ("What was deliberately left out") is the fuller record. -->
