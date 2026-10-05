<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="site/assets/brand/lockup-stacked-dark.svg">
    <img alt="CyberTrain" src="site/assets/brand/lockup-stacked-light.svg" width="360">
  </picture>
</p>
<p align="center">
  <a href="https://saeki-mototsune.github.io/CyberTrain/">Homepage</a> ·
  <a href="https://saeki-mototsune.github.io/CyberTrain/tutorial.html">Tutorial</a> ·
  <a href="https://saeki-mototsune.github.io/CyberTrain/api/">API reference</a>
</p>

# cybertrain

cybertrain is a Rails-shaped web application framework written natively for
[Spinel](https://github.com/matz/spinel), matz's ahead-of-time Ruby compiler.
There is no Rack, no gems at runtime, and no Ruby interpreter in the deployed
artifact: `cybertrain build` compiles an application — controllers, models,
views and the framework itself — into a single native binary. Where Rails leans on
runtime metaprogramming (`method_missing`, `define_method`, `eval`) for
`before_action :set_post` or `Post.where(title: "x")`, cybertrain gets the
same vocabulary by generating plain, committed Ruby from `db/schema.rb` and
`config/routes.rb` at build time (`spin run gen`), plus a little runtime data
for validations/callbacks and a runtime-interpreted template language.

**Status:** pre-alpha. Every milestone in [docs/design.md](docs/design.md) is
implemented end to end: an HTTP/1.1 server, routing and controllers with
callbacks and `rescue_from`, cookie sessions/flash/CSRF, an ERB-flavored
template engine, SQLite-backed models with validations, callbacks and
schema-derived associations, migrations, the `cybertrain` CLI, and a
development loop that rebuilds and re-execs the server on code changes.
[examples/blog](examples/blog) is the Rails "Getting Started" blog (articles
with comments) built on it, exercised by CI on Linux and macOS. Not built:
authentication, mailers, jobs, WebSockets/ActionCable, an asset pipeline,
i18n, and anything beyond a minimal `render json:` — see "Differences from
Rails" below.

## Requirements

- Spinel `2026.09.12` (`Cybertrain::SPINEL_TAG`, the same release as
  `SPINEL_TAG` in [.github/workflows/ci.yml](.github/workflows/ci.yml));
  untested against other versions. You do not install it by hand: the
  `cybertrain` command builds that release into `~/.cybertrain` the first
  time it needs it (`cybertrain setup` does that on request), unless a
  `spinel` of that release is already on `PATH` — see "Installing the CLI".
- To build it: a C toolchain (`cc`, or the compiler `CC` names) and `make`
  — Spinel compiles every program to C — plus `git` and `curl`.
- SQLite 3 headers/library (`libsqlite3-dev` on Debian/Ubuntu; present with
  Xcode's command line tools on macOS) — models use Spinel's FFI directly,
  not a gem.
- Ruby 3.2+ and RubyGems, for the `cybertrain` command only (applications
  never run on CRuby).
- OpenSSL's headers (`libssl-dev`) are optional: without them Spinel builds
  without its `openssl` package, which cybertrain does not use.

`cybertrain doctor` checks these tools and headers and the Spinel install;
when a required one is missing it also prints the install command for your
platform.

The framework has no separate test runner; it tests itself. `spin` comes
with Spinel, and `cybertrain spin` runs the copy `cybertrain` installs
without touching `PATH` (or put that copy on `PATH` with the `export
PATH=...` line `cybertrain setup` prints, and call `spin` directly):

```sh
cybertrain spin test
```

compiles and runs every program under `test/` and diffs its output against a
committed `test/<name>.rb.expected` snapshot — minitest/RSpec can't run under
Spinel, since they find test methods by reflection and an ahead-of-time
compiler has nothing to reflect on at run time. `cybertrain spin test
--regen test/<name>.rb` rewrites a snapshot from CRuby's output; a few tests that
touch SQLite through FFI take theirs from the compiled binary instead
([spikes/NOTES.md](spikes/NOTES.md), rule 23); `script/regen-snapshot
test/<name>.rb` does that build-then-capture step for you and prints the diff stat.

## Installing the CLI

```sh
gem install cybertrain
cybertrain new blog    # also installs Spinel, the first time (a few minutes)
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000
cybertrain build       # production: dist/
```

The `cybertrain` command is plain Ruby and the gem runs it under CRuby
(3.2 or newer); neither the framework nor Spinel is in the gem. Its
commands (`cybertrain help` prints them):

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` creates an application in NAME, then runs `spin lock` and
  `spin run gen` in it, installing Spinel first when it is needed.
- `cybertrain generate scaffold NAME field:type ...` (alias `g scaffold`)
  adds a resource to the application in the current directory.
- `cybertrain db migrate` generates, applies pending migrations, and
  generates again (`spin run gen; spin run db -- migrate; spin run gen`);
  `cybertrain migration` is kept as an alias.
- `cybertrain db COMMAND...` runs any other database command after `spin
  run gen`: `status`, `rollback [N]` (which generates again afterwards),
  `schema:dump`, `create`.
- `cybertrain server [PORT]` generates, then starts the development server
  (`spin run gen; spin run NAME`, or `spin run NAME -- PORT`; default port
  3000).
- `cybertrain build` builds NAME with `app/views/` embedded and assembles
  `dist/` (the binary, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` runs `spin` with the pinned Spinel from any
  directory (`cybertrain spin test`, `cybertrain spin run gen -- --check`).
- `cybertrain setup [--force]` installs Spinel `2026.09.12` into
  `~/.cybertrain` unless a `spinel` of that release is already on `PATH`;
  `--force` rebuilds the copy under `~/.cybertrain`.
- `cybertrain doctor` checks the C toolchain, the SQLite headers and the
  Spinel install.
- `cybertrain version` prints the version.

`db`, `server` and `build` run inside an application; NAME is the
`[package] name` in its `spin.toml`.

Every command that runs `spin` (`new`, `db`, `server`, `build`, `spin`) first makes
sure a Spinel of the release in `Cybertrain::SPINEL_TAG` is available. A
`spinel` on `PATH` (with a `spin`) whose `spinel --version` reports that
release is used as it is; otherwise the copy `cybertrain` keeps under
`~/.cybertrain/spinel/2026.09.12/` is used; otherwise `cybertrain` builds
that copy from the release tag (`git clone`, `make deps`, `make -j`, `make
install PREFIX=...`), once, in a few minutes. The build log is
`~/.cybertrain/log/spinel-2026.09.12-build.log` (its last lines are printed
if a step fails); if a tool the build needs is missing, `cybertrain` says
which and prints the install command for your platform before it starts. A
`spinel` of another release on `PATH` is never used or touched:
`cybertrain` keeps its own copy (and says so when it installs it).

`cybertrain setup` does the same on request and, whenever its own copy is
the one in use, prints the line that puts it on `PATH`, for running `spin`
yourself (`~/.cybertrain/bin` holds `spinel` and `spin` links to the release
in use, so the line survives a release bump; `cybertrain spin ...` needs no
`PATH` at all):

```sh
export PATH="$HOME/.cybertrain/bin:$PATH"
```

Two environment variables override all this: `CYBERTRAIN_HOME` replaces
`~/.cybertrain` (a path without spaces, quotes, `$` or `:`, which Spinel's
Makefile and `PATH` cannot take), and `CYBERTRAIN_SPINEL_HOME=PREFIX` forces
an existing install — `cybertrain` then uses the `spinel` and `spin` in `PREFIX/bin` (or
in `PREFIX` itself, if `spinel` is directly in it) and stops with an error
if they are not that release.

`cybertrain new` writes the application with its `spin.toml` pointing at
the release matching the CLI (`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.2.0" }`), makes
sure Spinel is installed, then runs `spin lock` (spin fetches the framework
into its cache, `~/.cache/spin/packages/`, and pins the commit in
`spin.lock`) and `spin run gen`, much as `rails new` runs `bundle install`,
and prints the next steps. Nothing of the framework is copied into the app;
commit `spin.toml` and `spin.lock`. If Spinel or one of the two `spin`
steps fails, the files stay, `new` exits with 1 and prints what to run once
the cause is fixed (for Spinel: `cybertrain setup`, then `cybertrain spin
lock && cybertrain spin run gen` in the new directory).

`--skip-spin` only writes the files: no Spinel install, no `spin lock`, no
`spin run gen`. `--path DIR` depends on a local checkout instead,
`--git URL [--ref R]` on the framework at URL (at branch or tag R), and
`--version V` on an index version once cybertrain is on a `spin-index`.
Give only one of `--path`, `--version` and `--git`; `--ref` needs `--git`.

Working on cybertrain itself, run the CLI from the checkout (`spin install`
builds `bin/cybertrain.rb` into `~/.local/bin/cybertrain`; `ruby -I.
bin/cybertrain.rb` also works) and create apps against it with `cybertrain
new NAME --path ~/src/cybertrain` (wherever the checkout is).

## Walkthrough: building a blog

Mirrors Rails' own [Getting
Started](https://guides.rubyonrails.org/getting_started.html): a blog with
articles and comments.

### Create the application

```sh
cybertrain new blog
cd blog
cybertrain server            # works right away: `new` already locked the framework and ran `spin run gen`
```

```
blog/
  spin.toml  config/app.rb  config/routes.rb
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/
```

`bin/blog.rb` is the application's one entry point, the program `spin build
blog` compiles: `./blog` serves, `./blog migrate` and `./blog db status`
manage the database. `bin/gen.rb` runs the generator (`spin run gen`), and
`bin/db.rb` runs the migrator during development (`cybertrain db migrate`
uses it, since `bin/blog.rb` cannot compile until the first migration has
generated `gen/models/`). `gen/` already holds `views.rb`, the committed,
empty table of embedded views (see "How it works").

Apps created before `cybertrain build` existed have `bin/server.rb` and
no `bin/<name>.rb`: copy `bin/<name>.rb` from a fresh `cybertrain new` (with
the same NAME), delete `bin/server.rb`, add `/dist/` to `.gitignore` (the old
template did not ignore it) and run `cybertrain spin run gen`.

`ApplicationController` starts with the one thing every controller inherits:

```ruby
class ApplicationController < Cybertrain::Controller
  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end
end
```

### Scaffold an article

```sh
cybertrain generate scaffold article title:string body:text
```

writes a migration, a model, a controller and five views, and inserts
`resources :articles` into `config/routes.rb`. Point root at it and, as
Rails' guide does, add a length validation by hand:

```ruby
# config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
```

```ruby
# app/models/article.rb -- only the first string field gets a default
# presence validation; add anything past that yourself.
class Article
  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

The controller is full CRUD, Rails-shaped down to strong params and
flash-then-redirect, except for two things Spinel forces everywhere: `new` is
written `new_action` (a method literally named `new` would shadow
`ArticlesController.new(ctx)`), and every action/callback is called by its
literal name, never `send`:

```ruby
# app/controllers/articles_controller.rb (index/show/edit are as plain as
# Rails' own scaffold; update mirrors create)
class ArticlesController < ApplicationController
  before_action :set_article, only: [:show, :edit, :update, :destroy]

  def new_action   # a `new` method would shadow ArticlesController.new
    @article = Article.new
  end

  def create
    @article = Article.new(article_params)
    if @article.save
      flash[:notice] = "Article was successfully created."
      redirect_to article_path(@article), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_article
    @article = Article.find(params[:id])
  end

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
```

### Generate, migrate, run

```sh
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen
cybertrain server        # http://127.0.0.1:3000; rebuilds on Ruby edits, views reload without a rebuild
```

`spin run gen` reads `db/schema.rb` and `config/routes.rb`, scans `app/` and
writes `gen/`; `spin run db -- migrate` applies `db/migrate/*.rb` and
rewrites `db/schema.rb`.

Re-run `cybertrain spin run gen` (and commit `gen/`) after touching the
schema, routes, or a controller/model's callbacks and ivars — the dev server does this for
you automatically (see "How it works").

### Add comments, nested under articles

```sh
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # the scaffold wrote a migration for the comments table
```

`article:references` adds an `article_id` column, index and foreign key —
enough for `Article`/`Comment` to get their association; there's no
`has_many`/`belongs_to` to write, `spin run gen` reads it off the foreign
key. This also inserts an independent `resources :comments` line; Rails'
guide nests comments under articles instead, so edit `config/routes.rb`:

```ruby
Cybertrain::Routes.draw do
  root "articles#index"

  # A nested block takes the mapper explicitly (Spinel's instance_eval
  # trampoline only rewires `self` for the outermost block): `articles.resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
end
```

Trim `CommentsController` to the two actions the nested routes call,
resolving the parent from the URL instead of `:id`:

```ruby
class CommentsController < ApplicationController
  before_action :set_article

  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    if @comment.save
      flash[:notice] = "Comment was successfully created."
    else
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
    end
    redirect_to article_path(@article), status: :see_other
  end

  def destroy
    @comment = Comment.where(article_id: @article.id).find(params[:id])
    @comment.destroy
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end

  private

  def set_article
    @article = Article.find(params[:article_id])
  end

  def comment_params
    params.require(:comment).permit(:commenter, :body)
  end
end
```

Delete the now-unreachable `index`/`show`/`new`/`edit` comment views, give
`ArticlesController#show` a blank `@comment` to bind against, and add a list
and a form to the article page:

```erb
<%# app/views/articles/show.html.erb %>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>
<%= render "comments/form" %>

<%# app/views/comments/_form.html.erb %>
<%= form_with(model: [@article, @comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

`comments/_comment.html.erb` destroys with `button_to "Destroy comment",
[@article, comment], method: :delete`. Both that and `form_with(model:
[@article, @comment])` resolve through the same `[parent, child]` rule: a new
child routes to the nested collection (`article_comments_path`), a persisted
one to the nested member (`article_comment_path`) — generated into
`gen/routes.rb` from the nested `resources` block above.

### Build for deployment

```sh
cybertrain build
```

writes `dist/`: `dist/blog`, the app compiled with every `app/views/`
template embedded (rendered from memory, error messages still say
`articles/show.html.erb:12`), `dist/public/`, and empty `dist/storage/` and
`dist/tmp/`. Copy `dist/` to a machine with the same OS and CPU (the binary
links the system SQLite) and run `./blog migrate && ./blog`; a built binary
is production by default (`CYBERTRAIN_ENV` overrides). Set
`CYBERTRAIN_SECRET_KEY_BASE`. Static files can also be served by the reverse
proxy from `dist/public/` — see [docs/deploy.md](docs/deploy.md).

A running `cybertrain server` skips its rebuilds while `cybertrain build` is
in progress (the build holds `tmp/cybertrain-build.lock`, since both write
`build/bin/blog`), logs the skip, and rebuilds as usual on the next save
once the build has finished. The lock records the build's PID; one left
behind by a killed build is ignored and removed.

## How it works

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
helpers and gaps: [docs/template-language.md](docs/template-language.md).

**The HTTP server.** `Cybertrain::Server` is plain-Ruby HTTP/1.1:
`TCPServer#accept` plus one Spinel green thread per connection (M:N
scheduled, no GVL), typed `Request`/`Response`, no Rack layer. TLS/HTTP/2 are
left to a reverse proxy. `SPINEL_WORKERS` defaults to `1` — spikes found that
faster and stall-free for this I/O-bound shape at 100 concurrent connections.

**SQLite via FFI.** Models talk to SQLite through Spinel's
`ffi_func`/`ffi_lib` directly — no C extension, no gem. A pool (`SizedQueue`,
4 connections by default) hands out connections with WAL, a `busy_timeout`,
and foreign keys on; every query is bound, never interpolated. It's the only
adapter today (PostgreSQL via `libpq` FFI is noted as possible future work).

**The development loop.** `cybertrain server` (`spin run gen`, then `spin run NAME`) in
`development` (the default `CYBERTRAIN_ENV`, except in a binary from
`cybertrain build`) also polls `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`
and `gen/**/*.rb` every half second (views are excluded — the engine reloads
those itself — and so is `gen/views.rb`, empty in development). A change runs `spin run gen && spin build NAME` in the
background; success requests a restart (the same flag an external `kill -HUP`
sets): a monitor thread stops the listener and drains open requests, then the
main thread `execv`s the new binary on the same port and PID, invisible to a
client mid-session. A failed build keeps serving the old binary and banners the
compiler output on every HTML response. None of this loads in production.

## Differences from Rails

| Rails | cybertrain |
| --- | --- |
| `rails console` | No console — Spinel has no `eval` |
| Edit code, the running app picks it up | Ruby needs a rebuild; `cybertrain server` in development does this for you (rebuild, stop, `execv`) |
| Edit a view, no reload needed | Same — views are parsed from disk per request in development |
| `def new` | `def new_action` (`new` would shadow `Klass.new(ctx)`) |
| `before_action { do_thing }` (implicit `self`) | `before_action { \|c\| c.do_thing }` — no `instance_exec` on a stored block, so callbacks take the controller/record explicitly |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — nested blocks take the mapper explicitly |
| ERB compiles to a method; any object, any method | Interpreted against a fixed grammar/dispatch table — [docs/template-language.md](docs/template-language.md) |
| Session holds any marshalled object | Session values are Strings only, HMAC-signed cookie |
| Many database adapters | SQLite only, via FFI |
| `has_many :through`, `includes`, `pluck`, `dependent:`, enums, STI, polymorphic associations | Not implemented; associations come from schema foreign keys only |
| Any column name; an association can shadow `errors` | A column name must be an ASCII identifier (`[A-Za-z_][A-Za-z0-9_]*`): a schema with a non-ASCII column name (`名前`, `prénom`) generated under CRuby before PR #10 and `spin run gen` refuses it now, so rename the column when upgrading (a name like `first-name` was never a method name). A column named like a method the generated class or the framework calls on a record (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`, ...) or like a Ruby keyword (`end`, `class`, `begin`) generates under `<column>_column` (`hash_column`, reader, writer and ivar) with a note in the generated file; its SQL name keeps working in `read_attribute`, params and `attributes["hash"]`, and a template reaches it under either name (`post.hash`, `post.hash_column`), except `errors` and `to_param`, which a template resolves as the model methods, so use `post.errors_column` there; the query API (`where`, `order`, `find_by`) always takes the SQL column name (`Post.where(hash: 1)`), the Ruby name being the reader/writer and the template name only. A column named like another Object method (`display`, `tap`, `methods`) generates under its own name with a note. `cybertrain generate scaffold` refuses keywords and reserved names (it would have to call a renamed reader) and accepts a shadowing name with a note, like the generator. An association whose plain name a column, another association or a `Model` method already owns is emitted under a fallback name with a comment in the generated file: `<table>_as_<column stem>` for a `has_many` (`comments_as_article`), `<stem>_as_<column>` for a `belongs_to` (`author_as_author_id`) |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Not implemented — flat names, `render json:` only |
| `rescue StandardError` catches a bad `JSON.parse` | Under Spinel `JSON::ParserError` is not a `StandardError`: app code must `rescue JSON::ParserError, StandardError`. The server catches it as a last resort and answers 500 |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` takes only `column [ASC\|DESC]` lists (each column quoted) and raises `ArgumentError` (a 500: the string is the developer's) on anything else; request data must go through an allowlist first, e.g. `SORTS = { "title" => "title", "newest" => "created_at DESC" }` and `Post.order(SORTS.fetch(params[:sort].to_s, "id"))`, because a well-formed term can still name a missing column (a 500 from SQLite) or a column the client must not sort by; raw ORDER BY text goes through `order_sql` (`Post.order_sql("lower(title)")`, also on a relation), which must never see request data. A `limit`/`offset` on `delete_all` is honoured (a subselect), and request parameters nest at most 32 levels / 4096 pairs (400 past that). `Query.parse`, `Query.value_of`, `Query.decode` and `request.form_value` / `query_value` raise `Cybertrain::QueryMalformed` (a `StandardError` under `Cybertrain::QueryInvalid`, not an `ArgumentError`) on a malformed percent-escape, on both runtimes (`Cookies.parse` still keeps the raw value). They raise it too on an invalid UTF-8 byte sequence, raw (whatever the String's tag) or percent-encoded (Rails likewise answers 400 for an invalid parameter encoding), and so does a raw byte that only an escape would complete (`a=\xC3%A9`); `Cookies.parse` keeps such a value raw, and a path with an invalid sequence (raw, or percent-decoded in a segment) is a 400 as well (`request.path_segments`; a malformed escape in a path stays literal, a 404 by non-match). App code that rescued `ArgumentError` around them should rescue `Cybertrain::QueryInvalid` instead (upgrade note). The request keeps no parameter tree of its own (the Router builds `params`, the middleware read one key); an app that wants the whole tree parses it itself, `Query.parse(request.utf8_query_string)`, and owns the result |
| Full backtrace on an exception | Class, message, request line, template name/line — Spinel exposes no backtraces |
| Rack, its middleware, and any gem in a `Gemfile` | No Rack compatibility; a small fixed middleware set; Spinel's own `spin-index`, limited to what compiles under its Ruby subset |
| minitest / RSpec | `Cybertrain::Test` — reflection-based runners can't work ahead-of-time |
| Auth, mailers, jobs, ActionCable, asset pipeline, i18n | Not built (MVP non-goals, `docs/design.md` §2.3) |

Not exhaustive — `docs/design.md` §8 ("捨てたもの") is the fuller record.

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

Other attributes with fixed, overridable defaults: `host` (`"127.0.0.1"`),
`views_root` (`"app/views"`), `public_root` (`"public"`), `layout`
(`"layouts/application"`), `log_level` (`:info`), `session_cookie_name`,
`session_max_age` (2 weeks), `session_secure` (`true` in production, which
marks the session cookie `Secure`; `false` elsewhere), `pool_size` (4),
`static_files`/`csrf` (`true`), `max_render_depth` (12 renders open at once:
the page and its partials; raise it for partials that legitimately recurse
deeper; it must be at least 1, or boot fails). Upgrade note: render nesting,
unlimited before, is now capped at 12 by default (the page is depth 1, so
partials can nest 11 levels; the layout renders after the page and does not
nest), and an app with a deeper tree (threaded
comments, a category menu) gets a template error until it sets
`max_render_depth`.

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
`drain_timeout` (10 s). The watcher/rebuild loop never runs in production. [docs/deploy.md](docs/deploy.md)
(Japanese) walks through it end to end: `cybertrain new`, an Ubuntu server,
systemd, Caddy with HTTPS, redeploys, rollbacks and backups.

## Testing an app

App tests are plain Spinel programs under `test/`, like the framework's own:

```ruby
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

Assertions: `assert`, `refute`, `assert_equal`, `assert_nil`,
`assert_includes`, `assert_raises("Class") { }`, `flunk`. For controllers and
full HTTP flows, `Cybertrain::Test::Client` drives an app in-process (no
socket) with a cookie jar, so sessions and CSRF behave as behind a browser:

```ruby
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "POST /articles creates an article and redirects to it" do
  client = Cybertrain::Test::Client.new(BLOG)
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => BlogTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, BlogTest.article_path(Article.last)
  assert_response res, :see_other
end
```

Both snippets start from the example's helper,
[`examples/blog/test/support/blog_test.rb`](examples/blog/test/support/blog_test.rb):
copy it into an app's `test/support/`, where files are required, not run.
It migrates a fresh `storage/test.sqlite3`, boots the app as `BLOG`, loads
`Cybertrain::Test` and its client, and reads the CSRF token out of the last
rendered form (`BlogTest.form_token`). End each test file with
`Cybertrain::Test.run!`; `examples/blog/test/articles.rb` and `comments.rb`
show the full pattern.

Run with `cybertrain spin test`: it compiles each `test/*.rb` into its own
program and diffs its output (stdout and stderr together) against
`test/<name>.rb.expected`. Regenerate with `cybertrain spin test --regen
test/<name>.rb`; FFI/database tests can't run under CRuby, so their snapshot
comes from the compiled binary instead: `rm -f build/test/<name>; cybertrain
spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> >
test/<name>.rb.expected 2>&1` (`cybertrain spin test` exits non-zero while the
snapshot is stale, so it is followed by `;`, not `&&`; the `[ -x ]` check skips
the capture when the compile failed, so the old snapshot is kept; in the
framework checkout, `script/regen-snapshot test/<name>.rb` does exactly this and
prints the diff stat).

## Learn more

- [Homepage](https://saeki-mototsune.github.io/CyberTrain/) and
  [tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html) —
  the source lives in [site/](site/), published by
  [.github/workflows/pages.yml](.github/workflows/pages.yml); the logo files and
  brand notes are in [site/assets/brand/](site/assets/brand/BRAND.md).
- [API reference](https://saeki-mototsune.github.io/CyberTrain/api/) — every
  class and method an application uses (controllers, params, session and
  flash, models and relations, routes, migrations, configuration, tests),
  including what `spin run gen` generates. It is built by YARD
  (`script/api-docs`, into `site/api/`) from the doc comments marked
  `@api public` in `cybertrain/` and from [docs/api/](docs/api/); a method
  without that tag is internal and stays out. CI fails on any YARD warning.
- [docs/design.md](docs/design.md) — the design record (Japanese): every
  decision, what was rejected and why, and the Spinel constraints behind it.
- [docs/template-language.md](docs/template-language.md) — the full template
  grammar and helpers, and where it differs from Rails' ERB.
- [spikes/NOTES.md](spikes/NOTES.md) — the spikes that answered
  `docs/design.md`'s open questions, and the compiler constraints they found.
- [Spinel](https://github.com/matz/spinel) — the AOT Ruby compiler cybertrain targets.
- [Roundhouse](https://github.com/rubys/roundhouse) (Sam Ruby) — transpiles
  *existing* Rails apps to Spinel. cybertrain is not that: it's a native
  framework you write directly against, not a compatibility layer.

## Releasing

The gem and the framework are released from the same tag, and `cybertrain
new` depends on the tag `v` + `Cybertrain::VERSION`, so the tag must exist
before the gem is pushed:

1. Bump `Cybertrain::VERSION` (`cybertrain/version.rb`) and `version` in
   `spin.toml` together (CI checks they match); spin caches a git
   dependency by that version.
2. Merge to `main`, then tag and push: `git tag v0.2.0 && git push origin v0.2.0`.
3. `gem build cybertrain.gemspec && gem push cybertrain-0.2.0.gem`.

`Cybertrain::SPINEL_TAG` (also in `cybertrain/version.rb`) is the Spinel
release `cybertrain setup` installs. It must equal `SPINEL_TAG` in
[.github/workflows/ci.yml](.github/workflows/ci.yml), which CI checks, so
change the two together when the framework moves to another Spinel release.

## License

MIT.
