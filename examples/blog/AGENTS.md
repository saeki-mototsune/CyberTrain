# AGENTS.md

Instructions for AI coding agents working on the blog, the
framework's acceptance application (the Rails Guides' "Getting Started"
blog). People start with README.md, which describes every part of it;
this file is the part an agent gets wrong without it.

The blog lives inside the framework's repository, so three things differ
from an application made by `cybertrain new`:

- It builds against the checkout around it (`spin.toml` has
  `cybertrain = { path = "../.." }`, and there is no `spin.lock`), so a
  change under `cybertrain/` is a change to what the blog compiles.
- Run every command below from `examples/blog`.
- The repository's rules apply to a commit here too: CONTRIBUTING.md
  (the commit gate, `script/gate`), and CI fails when `gen/` is not what
  `spin run gen` writes or when a test fails.

## What this application is

A [cybertrain](https://github.com/saeki-mototsune/CyberTrain)
application: Rails-shaped, compiled ahead of time by
[Spinel](https://github.com/matz/spinel) into one native binary.
It is **not Rails and not CRuby**:

- The Ruby is a statically typed subset: no metaprogramming, one
  type per variable and per method return, no gems.
- Views (`app/views/**/*.erb`) look like ERB but are a small
  template language of their own, not Ruby.
- `gen/` is Ruby generated from the application by `spin run gen`.

Rails knowledge is the right starting point and the most common
source of mistakes. Where this file, the guides or the framework
source disagree with what Rails would do, they win: look it up
instead of guessing.

## Commands

```sh
cybertrain generate scaffold post title:string body:text  # also: authentication, attachment, job, component, helper
cybertrain db migrate                       # regenerate gen/, apply db/migrate, regenerate (rewrites db/schema.rb)
cybertrain test                             # every test, compiled into one program
cybertrain test test/models/post_test.rb    # one file; -n /text/ for the tests whose name contains text
SPIN_DEBUG=1 spin run gen                   # regenerate gen/ after editing routes, models, controllers or locales
SPIN_DEBUG=1 spin run gen -- --check        # gen/ is current and every view helper has its require line
cybertrain build                            # the release binary in dist/ (slow: a minute or more)
cybertrain server                           # development server on http://127.0.0.1:3000
cybertrain help                             # every command and option
```

Compiling is slow (tens of seconds to minutes). Make a batch of
edits, then compile; run one test file while iterating and the
whole suite before you finish.

## Before you call a change done

1. `cybertrain test` passes. Add or update tests under `test/` for
   the behaviour you changed.
2. `SPIN_DEBUG=1 spin run gen -- --check` passes, and `gen/` is
   committed along with the change that produced it. Check new
   files as well: `git status --porcelain --untracked-files=all -- gen/`
   is empty after `spin run gen`.
3. `script/gate` passes, run from the repository root.
4. `cybertrain build` succeeds when the change touches
   `bin/blog.rb` (or `app/commands/`): the test program does not
   compile it.

A page that works in `cybertrain server` is not proof: right after
an edit it is served by a CRuby preview, which accepts Ruby that
Spinel rejects. The corner of each page says `Spinel` once the
compiled binary serves it; its background build logs to
`tmp/rebuild.log`.

## Layout

- `app/controllers`, `app/models`, `app/views`, `app/helpers`,
  `app/components`, `app/jobs`, `app/mailers`; concerns in
  `app/controllers/concerns` and `app/models/concerns`.
- `config/routes.rb`, `config/app.rb` (settings), `config/locales/*.yml`,
  `config/importmap.rb`.
- `db/migrate/` (migrations you write) and `db/schema.rb` (written
  by `cybertrain db migrate`; do not edit it by hand).
- `bin/blog.rb`: the program. Its `require` lines, operational
  commands (`Cybertrain::Main.command`: `touch`, `user`), a job
  handler (`Job.handle("touch")`). `bin/db.rb` must require the same
  subsystems.
- `app/commands/`: the code of the `user` command.
- `gen/`: **generated, never edit by hand.** Change the source and
  run `SPIN_DEBUG=1 spin run gen`. It is committed because
  `spin build` compiles what is checked in.
- `test/`: Rails-shaped tests, `test/fixtures/*.yml`, and shared
  helpers in `test/support/`.
- `config/locales/`: English and Japanese; a new text goes into
  both dictionaries.
- `spin.toml`: the framework dependency, the checkout at `../..`.

## Ruby that Spinel compiles

- No `eval`, `define_method`, `method_missing`, `instance_exec`,
  `instance_eval`, `instance_variable_get`, `respond_to?`, and no
  `send` / `public_send` with a computed name. Dispatch on a name
  with `case name when "a" then ... end`.
- Blocks receive their receiver explicitly:
  `before_action { |c| c.require_admin }`,
  `before_save { |record| record.normalize }`.
- A method returns one type. Do not return a String from one branch
  and nil or an Integer from another; return `""`, `-1` or `false`
  as the "none" value, or split the method.
- A variable keeps one type: start a local as `""` or `0`, not
  `nil`, if it later holds a String or an Integer.
- Seed empty containers with their element type:
  `Array.new(0) { "" }`; a typed empty Hash is
  `h = { "" => 0 }; h.delete("")`. Read nullable values through
  `Cybertrain::Cast.time_or_nil` / `date_or_nil`.
- String literals are frozen: build text in `+""` or `String.new`.
- Index the Array of a split (`parts = s.split("=", 2); k = parts[0]`)
  instead of `k, v = s.split(...)`.
- Write `rescue JSON::ParserError, StandardError`: under Spinel a
  JSON error is not a `StandardError`. Errors carry no backtrace,
  so raise with messages that say what and where.
- Process-wide state lives in a module's instance variables with
  `def self.x` accessors, not `@@class_variables`.
- Gems cannot be used. Use the framework (`Cybertrain::HttpClient`,
  `Cybertrain::Mailer`, `Cybertrain::Cache`, ...) and the standard
  library Spinel supports.

## Where Rails habits break

Controllers and routes

- The `new` action is `def new_action` (`new` would shadow the
  constructor); the route and the view are still `new`.
- Nested routes take the mapper:
  `resources :posts do |posts| posts.resources :comments end`.
  No `constraints`, `mount` or glob segments.
- Session values are Strings only.
- JSON is `render json:` with Hashes and Arrays (no jbuilder).
- CSRF runs before routing: exempt an API by path with
  `c.csrf_exempt_prefixes = ["/api/"]` in `config/app.rb`, not
  `skip_forgery_protection`.
- `GET /up` is built in; do not route it.

Models

- Relation methods change the receiver and return it. Branch from a
  shared base with `base.dup.where(...)`.
- `Model.transaction { |conn| ... }` returns nil; leave it by
  raising. Nested calls join the outer transaction (no savepoints).
- Typed queries: `pluck_int`, `pluck_str`, `pluck_float`,
  `maximum_int`, `sum_float_by`, ... instead of `pluck`, `maximum`,
  `sum`.
- `where(col: a..b)` takes Integer ranges; a Time or Date range is
  `where_between(:created_at, from, to)`.
- `order` takes `col: :desc` or `"col DESC"` lists only; raw SQL is
  `order_sql`. Never pass request parameters to it without an
  allowlist.
- `decimal` columns are Floats: keep money in an integer column of
  minor units.
- No `has_many :through`, enums, STI or polymorphic associations.
  Associations come from foreign keys or one-line `has_many`,
  `has_one`, `belongs_to` declarations; `includes` goes one level.
- SQLite only. A column named like a framework method or a Ruby
  keyword is generated as `<name>_column`.

Jobs, cache, time

- `perform(args)` takes one Hash of JSON values
  (`ReportJob.perform_later("id" => 1)`). Jobs run at least once,
  so make them idempotent.
- `Cybertrain::Cache` stores Strings; `fetch_int`, `fetch_hash` and
  `fetch_array` for the rest.
- A `Time` is a UTC instant; the application's zone is
  `c.time_zone` in `config/app.rb`.

## Templates

Only what the template language reference lists works; anything
else is an error naming the template and line.

- Allowed: literals, `@ivars`, locals, helper calls, the methods
  the per-type table lists, `if`/`unless`/`elsif`, `case`/`when`
  (compared with `==`), `each`/`each_with_index`/`each_slice` with
  declared block parameters, a fixed set of Array and Hash block
  methods (`map`, `select`, `sum`, `group_by`, ...), and
  `form_with ... do |f|`.
- Not available: `and`/`or`/`not`, ranges, regular expressions,
  constants, `begin`/`rescue`, `def`, multiple assignment,
  `inject`, `each_with_object`, and a space before a call's `(`.
- Compute in the controller, the model or an application helper
  (`app/helpers`: no `*rest` or `**opts`, at most three optional
  parameters, no `_path` / `_url` ending, not named like a
  framework helper; narrow arguments with `Cybertrain::Cast`),
  then render simple values.
- `link_to ... method: :delete` does not exist: use `button_to`.
- Strict locals are `<%# locals: (post:) %>` on line 1, with no
  defaults.
- Components are rendered by name:
  `<%= render component: "card", title: "x" %>`.
- A misspelled `@ivar` renders empty without an error; check the
  name against the controller.

## Subsystems

The blog uses every subsystem, so `bin/blog.rb` and `bin/db.rb`
require `cybertrain`, which loads them all; do not narrow it to
`cybertrain/core`. An application made by `cybertrain new` requires
`cybertrain/core` instead, and then a feature outside the core needs its
line in **both** files, written literally there (gen reads them as
text):

- `require "cybertrain/jobs"`: job classes, `Scheduler`, the worker
- `require "cybertrain/streams"`: Turbo Stream broadcasts and `turbo_stream_from`
- `require "cybertrain/feeds"`: WebSocket feeds (`Cybertrain::WebSocket.subscribe`)
- `require "cybertrain/mailer"` / `"cybertrain/mailer/later"`: mail, `deliver_later`
- `require "cybertrain/cache"`: `Cybertrain::Cache`
- `require "cybertrain/rate_limit"`: `rate_limit` in controllers
- `require "cybertrain/error_reporter/sentry"`: Sentry (in `bin/blog.rb` only)

The generators add the lines their code needs. The blog also requires
some of these lines in the files that use them (`require
"cybertrain/cache"` at the top of `ArticlesController`).

## Secrets

Never commit a secret. The configuration guide lists the variables
the application reads (`CYBERTRAIN_SECRET_KEY_BASE`,
`CYBERTRAIN_ENCRYPTION_KEY`, ...); `cybertrain secret` makes one.

## Looking things up

- Guides: https://saeki-mototsune.github.io/CyberTrain/guide/
  (models, requests, testing, the template language, background
  work, realtime, external services, configuration).
- Differences from Rails:
  https://saeki-mototsune.github.io/CyberTrain/guide/how-it-works.html#differences-from-rails
- API reference: https://saeki-mototsune.github.io/CyberTrain/api/
- The framework source is this repository: `cybertrain/` (public
  API marked `@api public`) and the guides' Markdown in `docs/guide/`.
  Read it, and `gen/`, to see what a call really does. The Spinel
  constraints behind the rules above are in `spikes/NOTES.md`.
