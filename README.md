# cybertrain

cybertrain is a Rails-shaped web application framework written natively for
[Spinel](https://github.com/matz/spinel), matz's ahead-of-time Ruby compiler.
There is no Rack, no gems at runtime, and no Ruby interpreter in the deployed
artifact: `spin build` compiles an application — controllers, models, views
and the framework itself — into a single native binary. Where Rails leans on
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

- Spinel `2026.09.12`, with `spinel` and `spin` on `PATH` (see `SPINEL_TAG`
  in [.github/workflows/ci.yml](.github/workflows/ci.yml)); untested against
  other versions.
- A C toolchain (`cc`) — Spinel compiles every program to C.
- SQLite 3 headers/library (`libsqlite3-dev` on Debian/Ubuntu; present with
  Xcode's command line tools on macOS) — models use Spinel's FFI directly,
  not a gem. Building Spinel itself also needs OpenSSL's headers
  (`libssl-dev`); cybertrain itself does not link OpenSSL.

The framework has no separate test runner; it tests itself:

```sh
spin test
```

compiles and runs every program under `test/` and diffs its output against a
committed `test/<name>.rb.expected` snapshot — minitest/RSpec can't run under
Spinel, since they find test methods by reflection and an ahead-of-time
compiler has nothing to reflect on at run time. `spin test --regen
test/<name>.rb` rewrites a snapshot from CRuby's output; a few tests that
touch SQLite through FFI take theirs from the compiled binary instead
([spikes/NOTES.md](spikes/NOTES.md), rule 23).

## Installing the CLI

```sh
spin install                      # builds bin/cybertrain.rb -> ~/.local/bin/cybertrain
```

or, without touching `PATH`:

```sh
spin build cybertrain
build/bin/cybertrain help
```

One binary, two real commands: `cybertrain new NAME` scaffolds an
application, `cybertrain generate scaffold NAME field:type ...` (alias `g
scaffold`) adds a resource to one. `cybertrain new` points the app's
`spin.toml` at this checkout by default; pass `--path DIR` for a different
checkout, or `--version V` once cybertrain is on a `spin-index`.

## Walkthrough: building a blog

Mirrors Rails' own [Getting
Started](https://guides.rubyonrails.org/getting_started.html): a blog with
articles and comments.

### Create the application

```sh
cybertrain new blog
cd blog
```

```
blog/
  spin.toml  config/app.rb  config/routes.rb
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/
  public/  bin/server.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/
```

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
spin run gen          # reads db/schema.rb + config/routes.rb, scans app/, writes gen/
spin run db -- migrate   # applies db/migrate/*.rb, rewrites db/schema.rb (arguments go after --)
spin run server       # http://127.0.0.1:3000
```

Re-run `spin run gen` (and commit `gen/`) after touching the schema, routes,
or a controller/model's callbacks and ivars — the dev server does this for
you automatically (see "How it works").

### Add comments, nested under articles

```sh
cybertrain generate scaffold comment commenter:string body:text article:references
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
`gen/migrations.rb` and `gen/app.rb` (the `require_relative` manifest).
`gen/` is committed, not gitignored — `spin build`/`spin test` have no hook
to generate first, so the checked-in output has to already be what compiles.
CI re-runs `spin run gen` and fails on a diff, so stale generated code can't
merge.

**Views are interpreted, not compiled.** `app/views/**/*.html.erb` files look
like Rails ERB but are read from disk, parsed into an AST at request time
(cached after first parse in production; re-parsed on change in
development), then walked by a tree-walking interpreter — Spinel has no
`eval`, so this is a closed grammar (literals, `@ivar`/local lookups, calls
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

**The development loop.** `spin run server` in `development` (the default
`CYBERTRAIN_ENV`) also polls `app/**/*.rb`, `config/**/*.rb`, `db/schema.rb`
and `gen/**/*.rb` every half second (views are excluded — the engine reloads
those itself). A change runs `spin run gen && spin build server` in the
background; success sends the server `SIGHUP`, whose handler stops listening
and `execv`s the new binary on the same port and PID, invisible to a client
mid-session. A failed build keeps serving the old binary and banners the
compiler output on every HTML response. None of this loads in production.

## Differences from Rails

| Rails | cybertrain |
| --- | --- |
| `rails console` | No console — Spinel has no `eval` |
| Edit code, the running app picks it up | Ruby needs a rebuild; `spin run server` in development does this for you (rebuild, `SIGHUP`, `execv`) |
| Edit a view, no reload needed | Same — views are parsed from disk per request in development |
| `def new` | `def new_action` (`new` would shadow `Klass.new(ctx)`) |
| `before_action { do_thing }` (implicit `self`) | `before_action { \|c\| c.do_thing }` — no `instance_exec` on a stored block, so callbacks take the controller/record explicitly |
| `resources :posts do resources :comments end` | `resources :posts do \|posts\| posts.resources :comments end` — nested blocks take the mapper explicitly |
| ERB compiles to a method; any object, any method | Interpreted against a fixed grammar/dispatch table — [docs/template-language.md](docs/template-language.md) |
| Session holds any marshalled object | Session values are Strings only, HMAC-signed cookie |
| Many database adapters | SQLite only, via FFI |
| `has_many :through`, `includes`, `pluck`, `dependent:`, enums, STI, polymorphic associations | Not implemented; associations come from schema foreign keys only |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Not implemented — flat names, `render json:` only |
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
| `CYBERTRAIN_ENV` | `env` | `"development"` (also `"test"`, `"production"`) |
| `PORT` | `port` | `3000` |
| `CYBERTRAIN_DATABASE` | `database_path` | `storage/#{env}.sqlite3` |
| `CYBERTRAIN_SECRET_KEY_BASE` | `secret_key_base` | required in production; dev/test auto-generate one into `tmp/secret_key` |
| `SPINEL_WORKERS` | `workers` | `1` |

Other attributes with fixed, overridable defaults: `host` (`"127.0.0.1"`),
`views_root` (`"app/views"`), `public_root` (`"public"`), `layout`
(`"layouts/application"`), `log_level` (`:info`), `session_cookie_name`,
`session_max_age` (2 weeks), `session_secure` (`true` in production, which
marks the session cookie `Secure`; `false` elsewhere), `pool_size` (4),
`static_files`/`csrf` (`true`).

**Deployment:** `spin build server` produces `build/bin/server`. Ship it with
`app/views/` (read at request time, never compiled in), `public/` (static
assets, or let a reverse proxy serve it) and `storage/` (the SQLite file),
`CYBERTRAIN_ENV=production` and `CYBERTRAIN_SECRET_KEY_BASE` set. The binary
speaks plain HTTP/1.1 only; put nginx/Caddy in front for TLS and HTTP/2 (the
session cookie is `Secure` in production, so serve it over HTTPS). In
production an exception answers 500 and a bare error response (the router's
plain-text 404, `head :not_found`, `render plain:`) is replaced by
`public/<status>.html` when that file exists; errors an action renders as HTML
or JSON pass through. `SIGTERM` stops accepting and exits. The
watcher/rebuild loop never runs in production. [docs/deploy.md](docs/deploy.md)
(Japanese) walks through it end to end: `cybertrain new`, an Ubuntu server,
systemd, Caddy with HTTPS, redeploys, rollbacks and backups.

## Testing an app

App tests are plain Spinel programs under `test/`, like the framework's own:

```ruby
require "cybertrain/test"

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
require "cybertrain/test/client"

client = Cybertrain::Test::Client.new(BLOG)
client.get("/articles/new")
res = client.post("/articles", "article[title]" => "Hello",
                                "article[body]" => "I am on Rails!",
                                "authenticity_token" => token)  # from the rendered form
assert_redirected_to res, "/articles/1"
assert_response res, :see_other
```

`examples/blog/test/articles.rb`/`comments.rb` (setup in
`test/support/blog_test.rb`) show the full pattern, including token
extraction, against a freshly migrated `storage/test.sqlite3`.

Run with `spin test`: it compiles each `test/*.rb` into its own program and
diffs stdout against `test/<name>.rb.expected`. Regenerate with `spin test
--regen test/<name>.rb`; FFI/database tests can't run under CRuby, so their
snapshot comes from the compiled binary instead: `spin test test/<name>.rb &&
./build/test/<name> > test/<name>.rb.expected`.

## Learn more

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

## License

MIT.
