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
with comments) built on it, exercised by CI on Linux and macOS.
`cybertrain generate authentication` adds email-and-password sign-in the way
Rails 8's generator does, and `cybertrain generate attachment` (or a
`cover:attachment` scaffold field) adds a file upload to a model. Not built: mailers, jobs, WebSockets/ActionCable,
an asset pipeline, i18n, and anything beyond a minimal `render json:` — see
"Differences from Rails" below.

## Try it in the browser

[Open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
to try cybertrain without installing anything: VS Code opens in your browser with
Spinel 2026.09.12, the `cybertrain` CLI and the blog from the walkthrough below
already created (`cybertrain new blog`, the article scaffold, the root route and
the first migration, built once so the server starts without compiling), its
development server running in a terminal and the app, showing the article list,
in a new browser tab. The app is a git repository with one commit, so Source
Control shows what you change. `PLAYGROUND.md` in the app lists what to try, from
editing a view to carrying on with the walkthrough's comments. A view edit shows
on the next reload; a Ruby edit is a full rebuild, about a minute, after which the
server restarts by itself; the app's tab does not reload by itself. `cybertrain new`
works there with no network.

- A GitHub account is required, and the codespace runs on your own Codespaces
  quota: GitHub's free plan includes 120 core-hours and 15 GB-month of storage a
  month, about 60 hours on the default 2-core machine the playground uses. GitHub
  stops an idle codespace after 30 minutes by default; its storage counts until
  you delete it.
- If VS Code asks whether you trust the authors of the files in this folder,
  choose "Trust Folder & Continue": the server's terminal starts only then.
- If the app's tab did not open (a pop-up blocker, or the codespace was stopped
  and restarted), click "Open in Browser" in VS Code's notification for port
  3000 or in the Ports view, or Ctrl-click the app's URL in the `server`
  terminal. `PLAYGROUND.md` shows where each is.
- The same image runs locally (it is published for linux/amd64; on arm64, build
  it from a checkout):

  ```sh
  docker run --rm -it --init -p 127.0.0.1:3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  Then open http://localhost:3000. [playground/README.md](playground/README.md)
  describes the image, building it and the Codespaces setup.

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
- zlib headers/library (`zlib1g-dev` on Debian/Ubuntu; in the macOS SDK) —
  gzip request bodies (`request.decoded_body`) are inflated through the
  system zlib, bound the same way.
- Ruby 3.2+ and RubyGems, for the `cybertrain` command only (applications
  never run on CRuby).
- OpenSSL's headers (`libssl-dev`) are optional: without them Spinel builds
  without its `openssl` package, which cybertrain does not use. On macOS an
  application that requires `openssl` needs Homebrew's (keg-only) OpenSSL on
  the compiler's paths: `export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`.
- jemalloc's development package (`libjemalloc-dev`; `brew install jemalloc`)
  is optional: an app needs it only once its `spin.toml` says
  `allocator = "jemalloc"`, which `cybertrain new` writes commented out. It
  is worth turning on for production: 1.1 to 1.4 times the requests per second on
  examples/blog ([docs/benchmark.md](docs/benchmark.md)).

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
- `cybertrain generate authentication` adds email-and-password sign-in to
  it: users and sessions tables, `User` and `Session` models, the sign-in
  and sign-up controllers and views, the routes, a `before_action` in
  `ApplicationController` and a test (see "Add authentication").
- `cybertrain generate attachment MODEL FIELD [--any]` adds a file upload
  to a scaffolded model: five metadata columns, model methods and
  callbacks, a download action, the route, the form field and a test (see
  "Add a file upload"). A scaffold field `cover:attachment` does the same.
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
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.2.1" }`), makes
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

Operational commands of your own (create a user, prune old rows, take a
backup) go on the same binary: register them in `bin/blog.rb` before
`Main.run`.

```ruby
Cybertrain::Main.command("prune", "delete comments older than DAYS") do |argv|
  days = argv.empty? ? 30 : argv[0].to_i
  Cybertrain::DB.with do |c|
    c.execute("DELETE FROM comments WHERE created_at < datetime('now', ?)", ["-#{days} days"])
  end
  0 # the exit status
end
```

`./blog prune 90` then runs the block with the arguments after the name
(`["90"]`), with `Cybertrain::DB` already connected to the configured
database (a pool of one connection), and exits with the block's value; a
`Cybertrain::DB::Error` is printed as `prune failed: ...` and exits 1, and
`./blog help` lists the command. The block takes `argv` explicitly, as a
`before_action` block takes the controller (Spinel has no `instance_eval`).
A built-in word (`server`, `migrate`, `db`, `help`), a number (the port
argument) or a name already registered raises `ArgumentError`. The server,
views and session secret are not set up for a command.

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

### Add authentication

```sh
cybertrain generate authentication
cybertrain db migrate
cybertrain server        # then open http://127.0.0.1:3000/sign_up
```

Like Rails 8's `bin/rails generate authentication`, this writes code the
app owns rather than installing an engine: migrations for `users`
(`email_address`, `password_digest`, a unique index) and `sessions` (one
row per signed-in browser, with `ip_address` and `user_agent`), the `User`
and `Session` models, `SessionsController` (`/session/new`, `POST
/session`, `DELETE /session`), `RegistrationsController` (`/sign_up`,
because there is no console to create the first user in; delete it for an
invitation-only app), their views, a `sessions/_nav` partial rendered at
the top of the layout, and `test/authentication.rb` with its
`test/support/app_test.rb`. It also inserts a block after the class line of
`ApplicationController`:

```ruby
class ApplicationController < Cybertrain::Controller
  before_action :resume_session          # sets @current_user and @current_session
  before_action :require_authentication  # 303 to /session/new unless signed in

  def self.allow_unauthenticated_access(only: [], except: [])
    skip_before_action(:require_authentication, only: only, except: except)
  end
  # authenticated?, start_new_session_for(user), terminate_session,
  # after_authentication_url ...
```

so every action needs a signed-in user unless its controller says
`allow_unauthenticated_access only: [:new, :create]`, as the two generated
controllers do. Templates read `@current_user` (`<% if @current_user %>`).
Passwords are hashed by `Cybertrain::Password` (PBKDF2-HMAC-SHA256, 100,000
iterations by default, about 0.2 s compiled; raise it with
`Cybertrain::Password.iterations = 600_000` in `config/app.rb`, and
`User#authenticate` rehashes each user as they sign in). The `User` model
spells out what `has_secure_password` would define (`password=`,
`authenticate`, `User.authenticate_by(email_address:, password:)`), since
Spinel cannot define methods at run time; edit it like any other model.
Password reset is not generated (no mailers). Running the generator again
writes nothing. The design, and why not a package: [docs/design.md](docs/design.md) D15.

In the blog, open the pages anyone may read again, as Rails' guide does, and
hide what a visitor cannot use (`resume_session` still runs on those pages,
so `@current_user` is set):

```ruby
# app/controllers/articles_controller.rb
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]
```

```erb
<%# app/views/articles/show.html.erb (excerpt) %>
<% if @current_user %>
  <%= button_to "Destroy this article", article_path(@article), method: :delete %>
<% end %>

<% if @current_user %>
  <h2>Add a comment:</h2>
  <%= render "comments/form" %>
<% end %>
```

A test that expects a form, submits one, or reaches an action other than
`index` and `show` now meets the sign-in page: sign the client in first
with the helpers in `test/support/app_test.rb`.

```ruby
require_relative "support/app_test"   # written by generate authentication: APP, AppTest

test "a signed-in user creates an article" do
  client = Cybertrain::Test::Client.new(APP)
  AppTest.user("ann@example.com", "s3cr3t-s3cr3t")
  AppTest.sign_in(client, "ann@example.com", "s3cr3t-s3cr3t")
  client.get("/articles/new")
  res = client.post("/articles", { "authenticity_token" => AppTest.form_token(client),
                                   "article[title]" => "Hello Rails",
                                   "article[body]" => "I am on Rails! This is my first article." })
  assert_redirected_to res, "/articles/#{Article.last.id}"
end
```

`examples/blog` itself stops before this step.

### Add a file upload

```sh
cybertrain generate attachment article cover   # or: generate scaffold article title:string cover:attachment
cybertrain db migrate
```

The same split as authentication: the framework parses
`multipart/form-data` and stores bytes, and the generator writes the rest
as code the app owns. It writes a migration adding five columns to
`articles` (`cover_key`, `cover_filename`, `cover_content_type`,
`cover_byte_size`, `cover_checksum`; the file itself is not in SQLite) and
a block in `Article` (`cover_file=`, `cover_attached?`, `cover_url`, a
validation and save/destroy callbacks). In `ArticlesController` it adds a
`cover` action behind `before_action :set_article` and one line in
`create` and `update`:

```ruby
@article.cover_file = params.nested(:article).upload(:cover)
```

It also adds `get "/articles/:id/cover"` to `config/routes.rb`, and to the
form `form_with(model: article, multipart: true)` with `f.file_field :cover`.
The show page gets an `<img>`, and `test/attachment_article_cover.rb` tests
the whole flow.

What is accepted and how it is served:

- **Types.** By default only PNG, JPEG, GIF and WebP up to 2 MB are
  accepted (`COVER_TYPES` / `COVER_MAX_BYTES` in the model; `--any` accepts
  any type). The type is detected from the file's first bytes, never taken
  from the browser.
- **Storage.** The bytes go to `storage/uploads/<2 hex>/<32 hex key>`
  (`Cybertrain::BlobStore`, mode 0600). Replacing a file deletes the old
  one, and destroying the record deletes its file.
- **Serving.** The `cover` action serves files with `send_blob`, so the
  controller's `before_action`s (sign-in, scoping) apply to downloads too.
  The four image types are served inline; anything else is a download
  (`application/octet-stream`). Like every response, they carry
  `X-Content-Type-Options: nosniff` and `X-Frame-Options: SAMEORIGIN` (the
  framework-wide defaults, below), and `send_blob` adds
  `Content-Security-Policy: default-src 'none'; sandbox`. Never put uploads
  under `public/`. The download is exactly as public as show: in the blog
  above, where `allow_unauthenticated_access only: [:index, :show]` lets
  visitors read articles, the generator adds `:cover` to that list, so the
  image on a public page loads (only when the download loads the record
  through the same `before_action :set_article` as show, and show checks
  nothing more). The generator checks inherited callbacks too. If a policy
  applies only to show, show contains inline checks, or the policy cannot
  be read safely, generation stops before writing any files. Put authorization
  in an explicit callback shared by show and the download, for example
  `before_action :authorize_article, only: [:show, :cover]`, and load both
  through `before_action :set_article`, then rerun the generator. Keeping a
  download behind sign-in alone does not preserve record or role permissions.
  Where show needs a sign-in, so does the download.
- **Params and CSRF.** `params.nested(:article).upload(:cover)` is a
  `Cybertrain::UploadedFile` (`original_filename`, `byte_size`,
  `detected_content_type`, `body_bytes`, `sha256_hex`), or nil when no
  file was chosen. `permit` never returns files. The CSRF token and
  `_method` are read from multipart bodies like any form.
- **Limits.** Three config keys bound uploads: `max_upload_bytes`,
  `max_multipart_parts` and `upload_root` (see "Configuration"). A broken
  or oversize body is a 400.
- **Not built yet:** several files per field, S3 or other remote storage,
  image variants, and streaming large bodies to disk (the whole body is
  read into memory, up to `max_body_bytes`).

Back up `storage/uploads/` together with the SQLite file. The design, and
why it is not a separate library: [docs/design.md](docs/design.md) D16.

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
proxy from `dist/public/` — see [docs/deploy.en.md](docs/deploy.en.md).

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
inside a `DB.with` block (which is not a transaction) gets a second connection.

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

## Migrations

A migration in `db/migrate/<version>_<name>.rb` is a `Cybertrain::Migration::Base`
subclass. Its `change` records schema operations (`create_table`,
`add_column`, `add_index`, `rename_column`, `add_reference`, `remove_column`,
`remove_index`, `drop_table`); `cybertrain db migrate` applies each pending
version in its own transaction and rewrites `db/schema.rb` from the database,
and `cybertrain db rollback [N]` runs the inverse of `change`. When `change`
holds an operation with no automatic inverse, write `down` (and `up`).

A schema change that needs a data step to be safe uses `execute(sql, binds =
[])`. It runs at its place in the migration, on the migrator's own
connection and in the same transaction as the version's schema operations,
so the column added before it exists when it runs, and a failure undoes the
whole version:

```ruby
class AddRetentionDaysToBackups < Cybertrain::Migration::Base
  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]   # existing rows keep "forever"
  end

  def down
    remove_column "backups", "retention_days"
  end
end
```

Without binds the SQL may be several `;`-separated statements; with binds
it is one statement with `?` placeholders. `execute` has no inverse: rolling
back a `change` that executes SQL, with no `down` of its own, stops with
`version N is irreversible: it executes SQL in change; write down` before
anything is reverted. A data statement never appears in `db/schema.rb`,
which is dumped from the database. Recording a migration runs nothing, so
the statement runs exactly once per `migrate` of its version.

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
| ERB compiles to a method; any object, any method | Interpreted against a fixed grammar/dispatch table — [docs/template-language.md](docs/template-language.md) |
| Session holds any marshalled object | Session values are Strings only, HMAC-signed cookie |
| Many database adapters | SQLite only, via FFI |
| `Article.transaction { ... }` returns the block's value; `raise ActiveRecord::Rollback`; `requires_new: true` savepoints | `Article.transaction { \|c\| ... }` (= `Cybertrain::DB.transaction`) yields the connection and returns nil; leave it by raising (it re-raises after the rollback); nested calls join the outer transaction, no savepoints. `immediate: true` for SQLite's `BEGIN IMMEDIATE`. `c.transaction { }` cannot be called on the yielded `c` under Spinel: nest `DB.transaction`, or use `c.begin!` / `c.commit!` / `c.rollback!` |
| `has_many :through`, `includes`, `pluck`, `dependent:`, enums, STI, polymorphic associations | Not implemented; associations come from schema foreign keys only |
| Any column name; an association can shadow `errors` | A column name must be an ASCII identifier (`[A-Za-z_][A-Za-z0-9_]*`): a schema with a non-ASCII column name (`名前`, `prénom`) generated under CRuby before PR #10 and `spin run gen` refuses it now, so rename the column when upgrading (a name like `first-name` was never a method name). A column named like a method the generated class or the framework calls on a record (`errors`, `save`, `attributes`, `hash`, `to_s`, `to_ary`, `raise`, ...) or like a Ruby keyword (`end`, `class`, `begin`) generates under `<column>_column` (`hash_column`, reader, writer and ivar) with a note in the generated file; its SQL name keeps working in `read_attribute`, params and `attributes["hash"]`, and a template reaches it under either name (`post.hash`, `post.hash_column`), except `errors` and `to_param`, which a template resolves as the model methods, so use `post.errors_column` there; the query API (`where`, `order`, `find_by`) always takes the SQL column name (`Post.where(hash: 1)`), the Ruby name being the reader/writer and the template name only. A column named like another Object method (`display`, `tap`, `methods`) generates under its own name with a note. `cybertrain generate scaffold` refuses keywords and reserved names (it would have to call a renamed reader) and accepts a shadowing name with a note, like the generator. An association whose plain name a column, another association or a `Model` method already owns is emitted under a fallback name with a comment in the generated file: `<table>_as_<column stem>` for a `has_many` (`comments_as_article`), `<stem>_as_<column>` for a `belongs_to` (`author_as_author_id`) |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Not implemented — flat names, `render json:` only |
| `rescue StandardError` catches a bad `JSON.parse` | Under Spinel `JSON::ParserError` is not a `StandardError`: app code must `rescue JSON::ParserError, StandardError`. The server catches it as a last resort and answers 500 |
| `skip_forgery_protection` in an API controller | CSRF is a middleware that runs before routing, so an API is exempted by path: `c.csrf_exempt_prefixes = ["/api/"]` in `config/app.rb`. The controller must then authenticate its callers itself (an API key in a header), and no session-authenticated route may match under the prefix |
| Rack leaves a gzip request body as it is | A body sent with `Content-Encoding: gzip` (an SDK or API client past a few kilobytes) is `request.decoded_body`, inflated once through the system zlib under a ceiling on the output (10 MiB by default; an endpoint that expects more passes its own, `request.decoded_body(limit)`): a corrupt body or an encoding other than gzip/identity is `Cybertrain::BodyUndecodable`, one that would inflate past the limit `Cybertrain::BodyTooLarge`, both `QueryInvalid`s answered 400; `request.body` stays the bytes as sent |
| `order("lower(title)")`, `order("posts.title")`, `order(params[:sort])` | `order` takes only `column [ASC\|DESC]` lists (each column quoted) and raises `ArgumentError` (a 500: the string is the developer's) on anything else; request data must go through an allowlist first, e.g. `SORTS = { "title" => "title", "newest" => "created_at DESC" }` and `Post.order(SORTS.fetch(params[:sort].to_s, "id"))`, because a well-formed term can still name a missing column (a 500 from SQLite) or a column the client must not sort by; raw ORDER BY text goes through `order_sql` (`Post.order_sql("lower(title)")`, also on a relation), which must never see request data. A `limit`/`offset` on `delete_all` is honoured (a subselect), and request parameters nest at most 32 levels / 4096 pairs (400 past that). `Query.parse`, `Query.value_of`, `Query.decode` and `request.form_value` / `query_value` raise `Cybertrain::QueryMalformed` (a `StandardError` under `Cybertrain::QueryInvalid`, not an `ArgumentError`) on a malformed percent-escape, on both runtimes (`Cookies.parse` still keeps the raw value). They raise it too on an invalid UTF-8 byte sequence, raw (whatever the String's tag) or percent-encoded (Rails likewise answers 400 for an invalid parameter encoding), and so does a raw byte that only an escape would complete (`a=\xC3%A9`); `Cookies.parse` keeps such a value raw, and a path with an invalid sequence (raw, or percent-decoded in a segment) is a 400 as well (`request.path_segments`; a malformed escape in a path stays literal, a 404 by non-match). App code that rescued `ArgumentError` around them should rescue `Cybertrain::QueryInvalid` instead (upgrade note). The request keeps no parameter tree of its own (the Router builds `params`, the middleware read one key); an app that wants the whole tree parses it itself, `Query.parse(request.utf8_query_string)`, and owns the result |
| Full backtrace on an exception | Class, message, request line, template name/line — Spinel exposes no backtraces |
| Rack, its middleware, and any gem in a `Gemfile` | No Rack compatibility; a small fixed middleware set; Spinel's own `spin-index`, limited to what compiles under its Ruby subset |
| minitest / RSpec | `Cybertrain::Test` — reflection-based runners can't work ahead-of-time |
| `bin/rails generate authentication`, `has_secure_password` + bcrypt | `cybertrain generate authentication` writes the same shape (User, Session, SessionsController, the before_action) plus a sign-up page, since there is no console to create a user in; `has_secure_password` is written out as methods on the User model over `Cybertrain::Password` (PBKDF2-HMAC-SHA256 in Ruby: bcrypt would need a C library the binary links, and `String#crypt` has no bcrypt on macOS). No password reset (no mailers), no `rate_limit` |
| Active Storage, `has_one_attached :cover` | `cybertrain generate attachment post cover` writes five `cover_*` columns on the owner table and the model methods (`cover_file=`, `cover_url`, ...) into the app; files live on disk under `storage/uploads/` and are served by a generated action through `send_blob`. One file per field, local disk only, no variants or direct uploads |
| `skip_before_action :x` | The same, for named before callbacks (a block callback has no name to skip); no `skip_after_action` |
| `resource :session` | The same six routes to `SessionsController`; no nesting under it |
| `get "/x"` then `post "/x"` | Both are fine: the second route's derived name is taken, so it is unnamed, as in Rails; a duplicate `as:` is still an error |
| `Time.zone = "Asia/Tokyo"`, `time.in_time_zone`, ActiveSupport's bundled zone data | `Cybertrain::TimeZone.find("Asia/Tokyo")` reads the system's TZif files (`/usr/share/zoneinfo`, or `TZDIR`) and converts Integer epoch seconds (`utc_offset_at`, `utc_to_local`, `local_to_utc`); no per-request `Time.zone` and no `l(time, zone:)` yet ([Time zones](#time-zones)) |
| Mailers, jobs, ActionCable, asset pipeline, i18n | Not built (MVP non-goals, `docs/design.md` §2.3) |

Not exhaustive — `docs/design.md` §8 ("捨てたもの") is the fuller record.

## Performance

[docs/benchmark.md](docs/benchmark.md) measures examples/blog against the
same blog written in Rails 8.1, [bench/rails_blog](bench/rails_blog) (the same
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
(see [docs/deploy.en.md](docs/deploy.en.md)). `Cybertrain::Test::Client` calls the
app in-process and never serializes the response, so it does not show the two
defaults; assert them on `response.to_http`.

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
`drain_timeout` (10 s). The watcher/rebuild loop never runs in production. [docs/deploy.en.md](docs/deploy.en.md)
(in Japanese: [docs/deploy.md](docs/deploy.md)) walks through it end to end: `cybertrain new`, an Ubuntu server,
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
[docs/deploy-kamal.md](docs/deploy-kamal.md) has the details (part 8 of
the deployment tutorial).
[examples/blog](examples/blog#deploying-with-kamal) carries the same setup,
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

- [Homepage](https://saeki-mototsune.github.io/CyberTrain/),
  [tutorial](https://saeki-mototsune.github.io/CyberTrain/tutorial.html) and
  [playground](https://saeki-mototsune.github.io/CyberTrain/playground.html) —
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
- [docs/benchmark.md](docs/benchmark.md) — examples/blog measured against the
  same blog in Rails 8.1 ([bench/](bench/)), and how to run it again.
- [spikes/NOTES.md](spikes/NOTES.md) — the spikes that answered
  `docs/design.md`'s open questions, and the compiler constraints they found.
- [Spinel](https://github.com/matz/spinel) — the AOT Ruby compiler cybertrain targets.
- [Roundhouse](https://github.com/rubys/roundhouse) (Sam Ruby) — transpiles
  *existing* Rails apps to Spinel. cybertrain is not that: it's a native
  framework you write directly against, not a compatibility layer.

## Contributing

Bug reports, questions and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md)
explains how to set up a checkout, run the tests and the commit gate
(`script/install-hooks` once per clone; `script/gate` runs the same checks CI
does), and what a pull request needs. Security issues go through
[SECURITY.md](SECURITY.md), not an issue.

## Releasing

The gem and the framework are released from the same tag, and `cybertrain
new` depends on the tag `v` + `Cybertrain::VERSION`, so the tag must exist
before the gem is pushed:

1. Bump `Cybertrain::VERSION` (`cybertrain/version.rb`) and `version` in
   `spin.toml` together (CI checks they match); spin caches a git
   dependency by that version.
2. Merge to `main`, then tag and push: `git tag v0.2.1 && git push origin v0.2.1`.
3. `gem build cybertrain.gemspec && gem push cybertrain-0.2.1.gem`.
4. The tag also publishes the playground image
   `ghcr.io/saeki-mototsune/cybertrain-playground:X.Y.Z` (and `latest`) through
   [.github/workflows/playground-image.yml](.github/workflows/playground-image.yml);
   check that run.

`Cybertrain::SPINEL_TAG` (also in `cybertrain/version.rb`) is the Spinel
release `cybertrain setup` installs. It must equal `SPINEL_TAG` in
[.github/workflows/ci.yml](.github/workflows/ci.yml) and in
[script/claude-cloud-setup](script/claude-cloud-setup), which `script/gate`
checks, so change the three together when the framework moves to another
Spinel release.

## License

MIT; see [LICENSE](LICENSE). Contributions are accepted under the same license.
