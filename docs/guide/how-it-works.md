# How it works

**Build-time code generation.** `spin run gen` (`bin/gen.rb`) executes
`db/schema.rb`'s `create_table` DSL and `config/routes.rb`'s `Routes.draw`
DSL to get table and route *data*, and separately does a **lexical scan**
(regexes, not a parser — Spinel exposes none at run time) of
`app/controllers/**/*.rb` and `app/models/**/*.rb` for `@ivar =`
assignments, `before_action`/`after_action`/`rescue_from ... with:` names and
zero-argument `def`s. From that it writes plain, readable Ruby under `gen/`:
`gen/models/<name>.rb` (accessors, casts, finders, FK-derived associations),
`gen/routes.rb` (route table, dispatcher, `*_path`/`*_url` helpers),
`gen/controllers.rb` (`view_assigns` and `run_callback` per controller),
`gen/migrations.rb`, `gen/views.rb` (the embedded views table, empty unless
building for deployment) and `gen/app.rb` (the `require_relative` manifest).
`gen/` is committed, not gitignored — `spin build`/`spin test` have no hook
to generate first, so the checked-in output has to already be what compiles.
CI re-runs `spin run gen` and fails on a diff, so stale generated code can't
merge.

**Views are interpreted, not compiled.** `app/views/**/*.html.erb` files look
like Rails ERB but are parsed into an AST at request time, then walked by a
tree-walking interpreter. Where the source comes from depends on the mode:
in development (and test) the engine reads `app/views/` from disk, and in
development re-parses a template when it changes, so view edits need no rebuild.
`cybertrain build` runs `spin run gen -- --embed-views`, which writes every
template's source into `gen/views.rb` as a string table for that one `spin
build`, then runs `spin run gen` again to restore the empty table that is
committed; the production binary renders only that table (parsing each
template once) and refuses to boot when it is empty (`error: views are not
embedded in this binary`). Spinel has no `eval`, so this is a closed grammar (literals, `@ivar`/local lookups, calls
through fixed per-type dispatch tables, `if`/`unless`,
`each`/`each_with_index`/one helper block), not real Ruby. Full grammar,
helpers and gaps: [docs/guide/template-language.md](template-language.md).

**The HTTP server.** `Cybertrain::Server` is plain-Ruby HTTP/1.1:
`TCPServer#accept` plus one Spinel green thread per connection (M:N
scheduled, no GVL), typed `Request`/`Response`, no Rack layer. It calls an `HttpHandler` (`call(request) -> Response`); `ContextHandler` joins it to the middleware stack, so the HTTP layer (`cybertrain/http/`, plus `Params` and `Logger`) does not depend on the rest of the framework; `script/check-http-layer` enforces it in CI. TLS/HTTP/2 are
left to a reverse proxy. `SPINEL_WORKERS` defaults to `1` — spikes found that
faster and stall-free for this I/O-bound shape at 100 concurrent connections.

**SQLite via FFI.** Models talk to SQLite through Spinel's
`ffi_func`/`ffi_lib` directly — no C extension, no gem. A pool (`SizedQueue`,
4 connections by default) hands out connections with WAL, a busy timeout of
about five seconds (a busy handler retrying every 100 µs, where SQLite's
`busy_timeout` sleeps a millisecond or more), up to 64 cached prepared
statements and foreign keys on; every query is bound, never interpolated. It's the only
adapter today (PostgreSQL via `libpq` FFI is noted as possible future work).

**Transactions.** `Cybertrain::DB.transaction { |c| ... }` (or
`Article.transaction`, the same thing under the Rails name) checks a
connection out, runs `BEGIN`, yields the connection, `COMMIT`s when the block
returns and rolls back and re-raises when it raises. `immediate: true` runs
`BEGIN IMMEDIATE`, which takes SQLite's write lock at the start: use it for a
transaction that reads and then writes, so a concurrent writer makes it wait
at `BEGIN` rather than fail with "database is locked" at its first write.
While the block runs, everything on that thread that goes through the pool
(`save`, `update`, `destroy`, Relation queries, `DB.with`) uses the
transaction's connection, so it is part of the transaction:

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

A `DB.transaction` nested in the block joins the outer one (only the
outermost commits; a raise anywhere rolls everything back; no savepoints).
Code that must keep its `rescue` in a plain method uses the block-free form,
`c.begin!(immediate: true)` ... `c.commit!`, with `c.rollback!` in the rescue.
It returns nil rather than the block's value, and a `DB.transaction` called
inside a `DB.with` block (which is not a transaction) checks out a second
connection: on a one-connection pool (`:memory:` included) it then waits
forever. Open the transaction first and do the work inside it.

**The development loop.** `cybertrain server` (`spin run gen`, then `spin run NAME`) in
`development` (the default `CYBERTRAIN_ENV`, except in a binary from
`cybertrain build`) also polls `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`
and `gen/**/*.rb` every half second (views are excluded — the engine reloads
those itself — and so is `gen/views.rb`, empty in development). A change runs `spin run gen && spin build NAME -- --incremental` in the
background (Spinel's incremental build, which recompiles only the C units the
edit changed; a Spinel release without `--incremental` rejects the flag, and the
loop then builds without it); success requests a restart (the same flag an external `kill -HUP`
sets): a monitor thread stops the listener and drains open requests, then the
main thread `execv`s the new binary on the same port and PID, invisible to a
client mid-session. A failed build keeps serving the old binary and banners the
compiler output on every HTML response. None of this loads in production.


## Differences from Rails

| Rails | cybertrain |
| --- | --- |
| `rails console` | No console — Spinel has no `eval` |
| `rails runner`, `lib/tasks/*.rake` | `Cybertrain::Main.command("name", "description") { \|argv\| ...; 0 }` in `bin/<app>.rb`: `./<app> name ARGS` runs it with the database connected |
| Edit code, the running app picks it up | Ruby needs a rebuild; `cybertrain server` in development does this for you (rebuild, stop, `execv`) |
| Edit a view, no reload needed | Same — views are parsed from disk per request in development |
| `def new` | `def new_action` (`new` would shadow `Klass.new(ctx)`) |
| `before_action { do_thing }` (implicit `self`) | `before_action { \|c\| c.do_thing }` — no `instance_exec` on a stored block, so callbacks take the controller/record explicitly |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — nested blocks take the mapper explicitly |
| ERB compiles to a method; any object, any method | Interpreted against a fixed grammar/dispatch table — [docs/guide/template-language.md](template-language.md) |
| Session holds any marshalled object | Session values are Strings only, HMAC-signed cookie |
| Many database adapters | SQLite only, via FFI |
| `Article.transaction { ... }` returns the block's value; `raise ActiveRecord::Rollback`; `requires_new: true` savepoints | `Article.transaction { \|c\| ... }` (= `Cybertrain::DB.transaction`) yields the connection and returns nil; leave it by raising (it re-raises after the rollback); nested calls join the outer transaction, no savepoints. `immediate: true` for SQLite's `BEGIN IMMEDIATE`. `c.transaction { }` cannot be called on the yielded `c` under Spinel: nest `DB.transaction`, or use `c.begin!` / `c.commit!` / `c.rollback!` |
| `has_many :through`, `includes`, `dependent:`, enums, STI, polymorphic associations | Not implemented; associations come from schema foreign keys only |
| `pluck(:a)`, `sum(:a)`, `group(:a).count`, `upsert`, `update_counters`, `where("title LIKE ?", "%#{q}%")` | Typed one-column flavours, because a Spinel method has one return type: `pluck_str` / `pluck_int` / `pluck_float` (one column only), `sum_int` / `sum_float`, `count_by(:a)` (a `Hash{String => Integer}`) and `count_by_sql(expr)` for expressions; `Model.upsert(attrs, conflict:, update:)` takes the `DO UPDATE SET` expressions as SQL text and runs no validations, callbacks or timestamps; `relation.increment(:col, by: n)`; `where_like(:col, text)` escapes `\`, `%` and `_` for you. See [Querying beyond `where`](models.md#querying-beyond-where) |
| Any column name; an association can shadow `errors` | A column name must be an ASCII identifier (`[A-Za-z_][A-Za-z0-9_]*`): a schema with a non-ASCII column name (`名前`, `prénom`) generated under CRuby before PR #10 and `spin run gen` refuses it now, so rename the column when upgrading (a name like `first-name` was never a method name). A column named like a method the generated class or the framework calls on a record (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`, ...) or like a Ruby keyword (`end`, `class`, `begin`) generates under `<column>_column` (`hash_column`, reader, writer and ivar) with a note in the generated file; its SQL name keeps working in `read_attribute`, params and `attributes["hash"]`, and a template reaches it under either name (`post.hash`, `post.hash_column`), except `errors` and `to_param`, which a template resolves as the model methods, so use `post.errors_column` there; the query API (`where`, `order`, `find_by`) always takes the SQL column name (`Post.where(hash: 1)`), the Ruby name being the reader/writer and the template name only. A column named like another Object method (`display`, `tap`, `methods`) generates under its own name with a note. `cybertrain generate scaffold` refuses keywords and reserved names (it would have to call a renamed reader) and accepts a shadowing name with a note, like the generator. An association whose plain name a column, another association or a `Model` method already owns is emitted under a fallback name with a comment in the generated file: `<table>_as_<column stem>` for a `has_many` (`comments_as_article`), `<stem>_as_<column>` for a `belongs_to` (`author_as_author_id`) |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Not implemented — flat names, `render json:` only |
| `rescue StandardError` catches a bad `JSON.parse` | Under Spinel `JSON::ParserError` is not a `StandardError`: app code must `rescue JSON::ParserError, StandardError`. The server catches it as a last resort and answers 500 |
| `skip_forgery_protection` in an API controller | CSRF is a middleware that runs before routing, so an API is exempted by path: `c.csrf_exempt_prefixes = ["/api/"]` in `config/app.rb`. The controller must then authenticate its callers itself (an API key in a header), and no session-authenticated route may match under the prefix |
| Rack leaves a gzip request body as it is | A body sent with `Content-Encoding: gzip` (an SDK or API client past a few kilobytes) is `request.decoded_body`, inflated once through the system zlib under a ceiling on the output (10 MiB by default; an endpoint that expects more passes its own, `request.decoded_body(limit)`): a corrupt body or an encoding other than gzip/identity is `Cybertrain::BodyUndecodable`, one that would inflate past the limit `Cybertrain::BodyTooLarge`, both `QueryInvalid`s answered 400; `request.body` stays the bytes as sent |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` takes only `column [ASC\|DESC]` lists (each column quoted) and raises `ArgumentError` (a 500: the string is the developer's) on anything else; request data must go through an allowlist first, e.g. `SORTS = { "title" => "title", "newest" => "created_at DESC" }` and `Post.order(SORTS.fetch(params[:sort].to_s, "id"))`, because a well-formed term can still name a missing column (a 500 from SQLite) or a column the client must not sort by; raw ORDER BY text goes through `order_sql` (`Post.order_sql("lower(title)")`, also on a relation), which must never see request data. A `limit`/`offset` on `delete_all` is honoured (a subselect), and request parameters nest at most 32 levels / 4096 pairs (400 past that). `Query.parse`, `Query.value_of`, `Query.decode` and `request.form_value` / `query_value` raise `Cybertrain::QueryMalformed` (a `StandardError` under `Cybertrain::QueryInvalid`, not an `ArgumentError`) on a malformed percent-escape, on both runtimes (`Cookies.parse` still keeps the raw value). They raise it too on an invalid UTF-8 byte sequence, raw (whatever the String's tag) or percent-encoded (Rails likewise answers 400 for an invalid parameter encoding), and so does a raw byte that only an escape would complete (`a=\xC3%A9`); `Cookies.parse` keeps such a value raw, and a path with an invalid sequence (raw, or percent-decoded in a segment) is a 400 as well (`request.path_segments`; a malformed escape in a path stays literal, a 404 by non-match). App code that rescued `ArgumentError` around them should rescue `Cybertrain::QueryInvalid` instead (upgrade note). The request keeps no parameter tree of its own (the Router builds `params`, the middleware read one key); an app that wants the whole tree parses it itself, `Query.parse(request.utf8_query_string)`, and owns the result |
| Full backtrace on an exception | Class, message, request line, template name/line — Spinel exposes no backtraces |
| Rack, its middleware, and any gem in a `Gemfile` | No Rack compatibility; a small fixed middleware set; Spinel's own `spin-index`, limited to what compiles under its Ruby subset |
| minitest / RSpec | `Cybertrain::Test` — reflection-based runners can't work ahead-of-time |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` writes the same shape (User, Session, SessionsController, the before_action) plus a sign-up page, since there is no console to create a user in; `has_secure_password` is written out as methods on the User model over `Cybertrain::Password` (PBKDF2-HMAC-SHA256 in Ruby: bcrypt would need a C library the binary links, and `String#crypt` has no bcrypt on macOS). No password reset (no mailers); sign-in attempts are limited by `rate_limit` (counted per process; see [Rate limiting](requests.md#rate-limiting-and-the-client-address)) |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment post cover` writes five `cover_*` columns on the owner table and the model methods (`cover_file=`, `cover_url`, ...) into the app; files live on disk under `storage/uploads/` and are served by a generated action through `send_blob`. One file per field, local disk only, no variants or direct uploads |
| `skip_before_action :x` | The same, for named before callbacks (a block callback has no name to skip); no `skip_after_action` |
| `resource :session` | The same six routes to `SessionsController`; no nesting under it |
| `get "/x"` then `post "/x"` | Both are fine: the second route's derived name is taken, so it is unnamed, as in Rails; a duplicate `as:` is still an error |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, ActiveSupport's bundled zone data | `Cybertrain::TimeZone.find("Asia/Tokyo")` reads the system's TZif files (`/usr/share/zoneinfo`, or `TZDIR`) and converts Integer epoch seconds (`utc_offset_at`, `utc_to_local`, `local_to_utc`); no per-request `Time.zone` and no `l(time, zone:)` yet ([Time zones](configuration.md#time-zones)) |
| `Net::HTTP`, Faraday | `Cybertrain::HttpClient` for webhooks and APIs: every wait bounded, non-public destinations refused by default, no redirects or keep-alive (see [Outbound HTTP](external-services.md#outbound-http)); Spinel's `Net::HTTP` blocks the whole server on a stalled peer |
| Action Mailer (`deliver_later`, mailer classes, views) | `Cybertrain::Mailer.deliver(to:, subject:, body:)` sends plain text over SMTP (STARTTLS, implicit TLS or plain to loopback; AUTH PLAIN; every wait bounded); no templates, HTML, attachments or queue (see [Sending e-mail](external-services.md#sending-e-mail)) |
| Active Job, `perform_later`, `solid_queue`, recurring tasks | `Cybertrain::Job.handle(kind) { \|payload\| ... }` and `Job.enqueue(kind, payload, run_at:)` (a String payload in a `cybertrain_jobs` table, retried with backoff, then `failed`), `Cybertrain::Scheduler.every(seconds, name) { ... }`; one thread in the served process, `CYBERTRAIN_WORKER=0` elsewhere ([Background work](background-and-operations.md#background-work)) |
| ActionCable client, faye-websocket, websocket-client-simple | `Cybertrain::WebSocket.subscribe(name, url).on_message { \|conn, data\| ... }` keeps a feed connected while the server runs (reconnects, pings, silence detection), `Cybertrain::WebSocket::Client` for one synchronous connection; outbound only, every wait bounded (see [Consuming WebSocket feeds](external-services.md#consuming-websocket-feeds)) |
| `config.filter_parameters += [:passw, /\Apin\z/, ->(k, v) { ... }]` | `config.filter_parameters` is an Array of Strings matched by substring, case-insensitively (no Regexps or lambdas); it applies to the request log and the development error page ([Filtered parameters](configuration.md#configuration-and-environment-variables)) |
| `get "up" => "rails/health#show"` (a route to a controller) | `GET /up` is built in and answered before the static files, the session and the router, so no `before_action` runs; it queries the database and the background worker's last tick, `200 ok` or `503` ([Operations](background-and-operations.md#operations-backups-vacuum-health-check)) |
| `bin/rails db:...` tasks for backups (none built in) | `./<app> db backup PATH` / `db backup DIR/ --keep N` (`VACUUM INTO`, mode 0600, renamed into place) and `./<app> db vacuum` |
| ActionCable (the server), asset pipeline, i18n | Not built (MVP non-goals, `docs/design.md` §2.3) |

Not exhaustive — `docs/design.md` §8 ("What was deliberately left out") is the fuller record.

## Performance

[docs/benchmark.md](../benchmark.md) measures examples/blog against the
same blog written in Rails 8.1, [bench/rails_blog](../../bench/rails_blog) (the same
views, routes, models and schema), both in production mode, each server
pinned to the same CPU cores of one 4-vCPU cloud VM and loaded by wrk from
two others. Medians of three 10-second runs, recorded 2026-10-09:

| 1 CPU core, 16 connections | CyberTrain 0.2.1 | Rails 8.1.4 (YJIT, Puma) | |
| --- | --: | --: | --: |
| `GET /articles` (30 articles) | 2,641 req/s | 468 req/s | 5.6x |
| `GET /articles/1` (10 comments, 12 forms) | 2,450 req/s | 201 req/s | 12.2x |
| `POST /articles/2/comments` | 1,507 req/s | 390 req/s | 3.9x |
| `GET /style.css` | 13,300 req/s | 5,127 req/s | 2.6x |
| Memory after the load (RSS) | 10.6 MB | 126 MB | |
| Spawn to first response | 0.02 s | 1.3 s | |
| What the server needs | 2.5 MB (one binary) | 109 MB (Ruby, 69 gems, the app) | |

With jemalloc in both (`allocator = "jemalloc"` in spin.toml; Rails'
production image preloads it) the ratios are 2.8 to 14.6. On two cores the lead
narrows to 2.0 to 5.5: a second Puma worker doubles Rails, while
`SPINEL_WORKERS=2` adds 9 to 58% to CyberTrain (set it to the core count on a
multi-core server; it defaults to 1). The binary also has to be built
(`cybertrain build` took about three minutes there). docs/benchmark.md has
latency, every configuration, the method and what was optimized to get here;
`bench/run` repeats the measurement and `bench/report` prints its tables.
