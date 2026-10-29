---
description: How a CyberTrain app is built and run (build-time code generation, interpreted views, the HTTP server, SQLite via FFI, the development loop) and the differences from Rails.
---

# How it works

This page explains how a CyberTrain app is built and run: code generated at
build time, views interpreted at request time, the HTTP server, SQLite
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
names and zero-argument `def`s.

From that it writes plain, readable Ruby under `gen/`:

- `gen/models/<name>.rb`: accessors, casts, finders, FK-derived associations;
- `gen/routes.rb`: the route table, the dispatcher, the `*_path`/`*_url` helpers;
- `gen/controllers.rb`: `view_assigns` and `run_callback` per controller;
- `gen/migrations.rb`;
- `gen/views.rb`: the embedded views table, empty unless building for deployment;
- `gen/app.rb`: the `require_relative` manifest.

`gen/` is committed, not gitignored: `spin build` and `spin test` have no hook
to generate first, so the checked-in output has to already be what compiles.
CI re-runs `spin run gen` and fails on a diff, so stale generated code can't
merge.

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
- `cybertrain build` runs `spin run gen -- --embed-views`, which writes every
  template's source into `gen/views.rb` as a string table for that one
  `spin build`, then runs `spin run gen` again to restore the empty table that
  is committed.
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
- a busy timeout of about five seconds (a busy handler retrying every 100 µs,
  where SQLite's `busy_timeout` sleeps a millisecond or more);
- up to 64 cached prepared statements;
- foreign keys on.

How a transaction checks out one of these connections, and what runs on it:
[Transactions](models.md#transactions).

## The development loop

`cybertrain server` (`spin run gen`, then `spin run NAME`) in `development`
(the default `CYBERTRAIN_ENV`, except in a binary from `cybertrain build`)
also polls `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb` and `gen/**/*.rb`
every half second. Views are excluded (the engine reloads those itself), and
so is `gen/views.rb`, empty in development.

A change runs `spin run gen && spin build NAME -- --incremental` in the
background: Spinel's incremental build, which recompiles only the C units the
edit changed. A Spinel release without `--incremental` rejects the flag, and
the loop then builds without it.

Success requests a restart (the same flag an external `kill -HUP` sets): a
monitor thread stops the listener and drains open requests, then the main
thread `execv`s the new binary on the same port and PID, invisible to a client
mid-session. A failed build keeps serving the old binary and banners the
compiler output on every HTML response. Rebuilds are skipped while
`cybertrain build` holds `tmp/cybertrain-build.lock`. None of this loads in
production.

## Differences from Rails

<!-- table: cmp -->
| Rails | CyberTrain |
| --- | --- |
| `rails console` | No console — Spinel has no `eval` |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` in `bin/<app>.rb`: `./<app> name ARGS` runs it with the database connected |
| Edit code, the running app picks it up | Ruby needs a rebuild; `cybertrain server` in development does this for you (rebuild, stop, `execv`) |
| Edit a view, no reload needed | Same — views are parsed from disk per request in development |
| `def new` | `def new_action` (`new` would shadow `Klass.new(ctx)`) |
| `before_action { do_thing }` (implicit `self`) | `before_action { \|c\| c.do_thing }` — no `instance_exec` on a stored block, so callbacks take the controller/record explicitly |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — nested blocks take the mapper explicitly |
| ERB compiles to a method; any object, any method | Interpreted against a fixed grammar/dispatch table ([Template language](template-language.md)) |
| Session holds any marshalled object | Session values are Strings only, HMAC-signed cookie |
| Many database adapters | SQLite only, via FFI |
| `Article.transaction { ... }` returns the block's value; `raise ActiveRecord::Rollback`; `requires_new: true` savepoints | `Article.transaction { \|c\| ... }` yields the connection and returns nil; leave it by raising; nested calls join the outer transaction, no savepoints ([Transactions](models.md#transactions)) |
| `has_many :through`, `includes`, `dependent:`, enums, STI, polymorphic associations | Not implemented; associations come from schema foreign keys only |
| `pluck(:a)`, `sum(:a)`, `group(:a).count`, `upsert`, `update_counters`, `where("title LIKE ?", "%#{q}%")` | Typed flavours, as a Spinel method has one return type: `pluck_int` and its kin, `sum_int`, `count_by`, `upsert`, `increment(:col, by: n)`, `where_like` ([Querying beyond `where`](models.md#querying-beyond-where)) |
| Any column name; an association can shadow `errors` | ASCII identifiers only; a column named like a framework method or a Ruby keyword generates as `<column>_column`, a clashing association under a fallback name ([Column names](models.md#column-names)) |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Not implemented — flat names, `render json:` only |
| `rescue StandardError` catches a bad `JSON.parse` | Under Spinel `JSON::ParserError` is not a `StandardError`: app code must `rescue JSON::ParserError, StandardError`. The server catches it as a last resort and answers 500 |
| `skip_forgery_protection` in an API controller | CSRF runs before routing, so an API is exempted by path, `c.csrf_exempt_prefixes = ["/api/"]`, and authenticates its callers itself ([Configuration](configuration.md#configuration-and-environment-variables)) |
| Rack leaves a gzip request body as it is | A `Content-Encoding: gzip` body is `request.decoded_body`, inflated under a 10 MiB ceiling; a corrupt or oversize one is a 400; `request.body` stays as sent ([Query strings and bodies](requests.md#query-strings-and-bodies)) |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` takes only `column [ASC\|DESC]` lists; request data goes through an allowlist, raw SQL through `order_sql` ([Ordering](models.md#ordering)). Malformed or deeply nested parameters are a 400 ([Query strings and bodies](requests.md#query-strings-and-bodies)) |
| Full backtrace on an exception | Class, message, request line, template name/line — Spinel exposes no backtraces |
| Rack, its middleware, and any gem in a `Gemfile` | No Rack compatibility; a small fixed middleware set; Spinel's own `spin-index`, limited to what compiles under its Ruby subset |
| minitest / RSpec | `Cybertrain::Test` — reflection-based runners can't work ahead-of-time |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` writes the same shape plus a sign-up page; passwords use PBKDF2-HMAC-SHA256 (bcrypt needs a C library; macOS `String#crypt` has no bcrypt); no password reset ([Add sign-in](tutorial.md#authentication)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment` writes five `cover_*` columns and model methods; files stay on local disk under `storage/uploads/`, served by `send_blob`; one per field, no variants or direct uploads ([Add a cover image](tutorial.md#attachments)) |
| `skip_before_action :x` | The same, for named before callbacks (a block callback has no name to skip); no `skip_after_action` |
| `resource :session` | The same six routes to `SessionsController`; no nesting under it |
| `get "/x"` then `post "/x"` | Both are fine: the second route's derived name is taken, so it is unnamed, as in Rails; a duplicate `as:` is still an error |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, ActiveSupport's bundled zone data | `Cybertrain::TimeZone.find("Asia/Tokyo")` reads the system's TZif files (`/usr/share/zoneinfo`, or `TZDIR`) and converts Integer epoch seconds (`utc_offset_at`, `utc_to_local`, `local_to_utc`); no per-request `Time.zone` and no `l(time, zone:)` yet ([Time zones](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` for webhooks and APIs: every wait bounded, non-public destinations refused by default, no redirects or keep-alive (see [Outbound HTTP](external-services.md#outbound-http)); Spinel's `Net::HTTP` blocks the whole server on a stalled peer |
| Action Mailer (`deliver_later`, mailer classes, views) | `Cybertrain::Mailer.deliver(to:, subject:, body:)` sends plain text over SMTP (STARTTLS, implicit TLS or plain to loopback; AUTH PLAIN; every wait bounded); no templates, HTML, attachments or queue (see [Sending e-mail](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, recurring tasks | `Cybertrain::Job.handle(kind)` and `Job.enqueue(kind, payload, run_at:)` (a String payload, retried with backoff), `Cybertrain::Scheduler.every(seconds, name)`; one thread in the served process ([Background work](background-and-operations.md#background-work)) |
| ActionCable client, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url)` keeps a feed connected while the server runs (reconnects, pings, silence detection); `WebSocket::Client` for one synchronous connection; outbound only ([Consuming WebSocket feeds](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` is an Array of Strings matched by substring, case-insensitively (no Regexps or lambdas); it applies to the request log and the development error page ([Filtered parameters](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (a route to a controller) | `GET /up` is built in, answered before static files, session and router, so no `before_action` runs; it checks the database and the worker, `200 ok` or `503` ([Operations](background-and-operations.md#operations-backups-vacuum-health-check)) |
| `bin/rails db:...` tasks for backups (none built in) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, mode 0600, renamed into place) and `./<app> db vacuum` |
| ActionCable (the server), asset pipeline, i18n | Not built (MVP non-goals, `docs/design.md` §2.3) |

<!-- table-foot: Not exhaustive: docs/design.md §8 ("What was deliberately left out") is the fuller record. -->
