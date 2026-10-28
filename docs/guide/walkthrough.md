# Walkthrough: building a blog

Mirrors Rails' own [Getting
Started](https://guides.rubyonrails.org/getting_started.html): a blog with
articles and comments.

## Create the application

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
empty table of embedded views (see [How it works](how-it-works.md#how-it-works)).

Operational commands of your own (create a user, prune old rows, take a
backup) go on the same binary: register them in `bin/blog.rb` before
`Main.run`.

```ruby
Cybertrain::Main.command("prune", "delete comments older than DAYS") do |argv|
  arg = argv.empty? ? "30" : argv[0]
  days = arg.to_i
  if argv.size > 1 || days < 1 || days.to_s != arg # "foo".to_i is 0, "1.5".to_i is 1
    puts "usage: prune [DAYS], DAYS a positive whole number"
    1 # the exit status
  else
    Cybertrain::DB.with do |c|
      c.execute("DELETE FROM comments WHERE created_at < datetime('now', ?)", ["-#{days} days"])
    end
    0
  end
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

## Scaffold an article

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

## Generate, migrate, run

```sh
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen
cybertrain server        # http://127.0.0.1:3000; rebuilds on Ruby edits, views reload without a rebuild
```

`spin run gen` reads `db/schema.rb` and `config/routes.rb`, scans `app/` and
writes `gen/`; `spin run db -- migrate` applies `db/migrate/*.rb` and
rewrites `db/schema.rb`.

Re-run `cybertrain spin run gen` (and commit `gen/`) after touching the
schema, routes, or a controller/model's callbacks and ivars — the dev server does this for
you automatically (see [How it works](how-it-works.md#how-it-works)).

## Add comments, nested under articles

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

## Add authentication

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
writes nothing. The design, and why not a package: [docs/design.md](../design.md) D15.

Sign-in is protected from password guessing the way Rails 8's generator
does it: `SessionsController` declares `rate_limit to: 10, within: 3 * 60,
only: [:create], redirect_to: "/session/new", alert: "Try again later."`,
so an address that has tried ten times in three minutes goes back to the
form until the window closes. Behind a reverse proxy on the same machine,
set `CYBERTRAIN_TRUSTED_PROXY=1`, or every visitor shares the proxy's
address (see [Rate limiting](requests.md#rate-limiting-and-the-client-address)); behind
kamal-proxy, the generated `config/deploy.yml` already sets
`CYBERTRAIN_TRUSTED_PROXIES` to the Docker network.
`AppTest.sign_in` forgets the counts first, since every test client comes
from 127.0.0.1.

### An invitation-only app: `--invite-only`

The sign-up page lets anyone who reaches the server register, which is the
wrong default for an internal tool: whoever gets there before the admin
does has an account. `--invite-only` writes no `RegistrationsController`
and no sign-up link; the first user comes from the command line or from a
page only the server's own machine can open, with a link the server prints
when it starts:

```sh
cybertrain generate authentication --invite-only
cybertrain db migrate
cybertrain server        # then open the http://127.0.0.1:3000/setup?token=... link it prints, on the same machine
```

In production, from the directory the binary runs in:

```sh
./shop user ann@example.com                        # reads the password from stdin (one line)
printf '%s' "$PASSWORD" | ./shop user ann@example.com
./shop user ann@example.com 's3cr3t-s3cr3t'        # or as an argument (visible in ps)
```

- `app/commands/user_command.rb` registers the `user` command with
  `Cybertrain::Main.command` (so `./shop help` lists it) and is required
  from `bin/shop.rb`. `EMAIL [PASSWORD]` creates the user, or sets the
  password of the one with that address (which signs that user's browsers
  out, as any password change does); it prints `created ADDRESS` or
  `updated ADDRESS` and exits 0. Without `PASSWORD` it reads one line of
  standard input (prompting when that is a terminal; the typing is echoed)
  and drops the trailing newline, so the password stays out of `ps` and
  the shell history. An empty password, a record that does not validate
  (a password under 8 characters) or bad arguments print an error or the
  usage line and exit 1.
- `SetupController` (`GET`/`POST /setup`, `app/views/setup/new.html.erb`)
  creates the first user and signs them in. It answers only while no user
  exists, only with the one-time token (below), and only to a connection
  whose socket peer is the loopback address (`request.loopback?`:
  `127.0.0.0/8` or `::1`) and that carries no `X-Forwarded-For` header (a
  proxy on the same host makes every request a loopback one, and it adds
  that header). A header can close the page, never open it. Everyone else,
  and a missing or wrong token, gets a 404.
- The token: `SetupController::SETUP_TOKEN`, 32 random hex characters
  (`Cybertrain::Crypto.random_token(16)`) made when the program starts and
  kept until it exits, so a restart makes a new one. `GET /setup` takes it
  as `?token=`, the form carries it back in a hidden field, and both
  compare it in constant time (`Cybertrain::Crypto.secure_compare`). It is
  what keeps the page closed when the address check cannot: a proxy on the
  same host that adds no `X-Forwarded-For` (nginx without
  `proxy_set_header X-Forwarded-For ...`) makes every client look like
  loopback, and only someone who can read the server's log has the token.
  The request log's `Started GET "/setup?token=..."` line writes it to the
  same log; it opens nothing once the user exists.
- For a first run behind a proxy on another host, `SHOP_SETUP_OPEN=1`
  (declared in `config/app.rb` with `c.setting_bool :setup_open`) lifts the
  address check, still only while no user exists and still only with the
  token. Unset it once the user is there.
- While no user exists, the server logs `[WARN] no user exists yet: run
  ./shop user EMAIL, or open /setup?token=<token> from this machine` before
  it boots (`UserCommand.warn_if_no_user`, called from `bin/shop.rb` when
  `Cybertrain::Main.server?(ARGV)`; it connects for that one question and
  says nothing when the users table is not migrated yet). That line is the
  only place the token is printed.

The generated `test/authentication.rb` covers both: `/setup` with and
without the token (`SetupController.setup_token`) or with a wrong one, from
another address (`client.peer_address = "203.0.113.7"`), through a proxy,
once a user exists and with the switch on, and the `user` command run in-process
through `Cybertrain::Main.run`. All of it is application code, yours to
change (docs/design.md D29); the framework only provides
`request.loopback?`, `Main.command`, `Main.server?`,
`Crypto.random_token` / `Crypto.secure_compare` and the test client's
`peer_address`.

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

### Authentication: what the framework provides

The generator above writes the flow; the pieces it is built from are
framework API, usable without it (for an API token, an admin password, a
hand-written sign-in):

- **`Cybertrain::Password`**: `hash(plain)` makes a salted
  PBKDF2-HMAC-SHA256 digest that records its own parameters
  (`$pbkdf2-sha256$i=100000$salt$key`), `verify?(plain, digest)` checks one
  in constant time and never raises on a malformed digest, and
  `needs_rehash?(digest)` says when one is behind the current
  `Password.iterations`. For a sign-in action:
  - `verify_serialized(plain, digest)` is `verify?` one at a time per
    process (a Mutex). A hash takes about 0.2 s of CPU; a burst of attempts
    side by side would hold every worker, through this method they queue and
    the other workers keep serving pages.
  - `dummy_digest` is a digest of a random password, made once per process
    at the current cost. Verify against it when the address is unknown, so
    the response time does not tell which addresses have accounts:
    `Cybertrain::Password.verify_serialized(password, user.nil? ? Cybertrain::Password.dummy_digest : user.password_digest)`.
  - `session_key(digest)` is an HMAC of the password digest under
    `secret_key_base`; keep it in the session at sign-in and check it with
    `session_key_matches?(session[:password_key], user.password_digest)` on
    each request. A password change makes a new digest, so every session
    started before it is signed out.
  - `iterations` is `Password::TEST_ITERATIONS` (1,000) when
    `Cybertrain.config.test?`, so test suites do not pay the production cost
    per user; digests record their count, so nothing else changes.
- **The session** (`session[:key]`, a signed cookie): `clear` empties it
  (CSRF token included) on sign-out, and `config.session_absolute_max_age`
  (two weeks; `0` turns it off) bounds a session's whole life however often
  it is used: the cookie records when it was first written, a cookie older
  than that loads as an empty session, so a copied cookie cannot be
  replayed forever. `session.restart_lifetime!` starts the count again (at
  sign-in).
- **`Controller#local_path?(text)` and `safe_redirect_path(text, fallback)`**:
  a path that came from the request (a `return_to` parameter, a remembered
  page) is redirected to only when it starts with `/` but not `//` or `/\`,
  holds printable ASCII only and is at most 2,048 bytes:
  `redirect_to safe_redirect_path(params[:return_to], "/"), status: :see_other`.
- **`skip_before_action(name, only:, except:)`** on a controller class drops
  an inherited `before_action` for some actions; the generated
  `allow_unauthenticated_access` is a one-line wrapper around it.
- **`cybertrain generate authentication`** writes, as code the app owns: the
  `users` and `sessions` migrations and models, `SessionsController`,
  `RegistrationsController`, their views and nav partial, the
  `ApplicationController` block (`resume_session`, `require_authentication`,
  `start_new_session_for`, `terminate_session`, `after_authentication_url`)
  and `test/authentication.rb`. That code uses everything in this list:
  `User.authenticate_by` verifies with `verify_serialized` and the dummy
  digest, `start_new_session_for` stores the password key and restarts the
  lifetime, `resume_session` ends a Session row whose key no longer matches
  or that is older than `session_absolute_max_age`, and
  `after_authentication_url` is `safe_redirect_path`. To keep the browser
  that changed a password signed in, store the new key after saving:
  `session[:password_key] = Cybertrain::Password.session_key(user.password_digest)`.
  The design: [docs/design.md](../design.md) D25.

## Add a file upload

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
  `max_multipart_parts` and `upload_root` (see [Configuration](configuration.md#configuration-and-environment-variables)). A broken
  or oversize body is a 400.
- **Not built yet:** several files per field, S3 or other remote storage,
  image variants, and streaming large bodies to disk (the whole body is
  read into memory, up to `max_body_bytes`).

Back up `storage/uploads/` together with the SQLite file. The design, and
why it is not a separate library: [docs/design.md](../design.md) D16.

## Build for deployment

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
proxy from `dist/public/` — see [docs/deploy.en.md](../deploy.en.md).

A running `cybertrain server` skips its rebuilds while `cybertrain build` is
in progress (the build holds `tmp/cybertrain-build.lock`, since both write
`build/bin/blog`), logs the skip, and rebuilds as usual on the next save
once the build has finished. The lock records the build's PID; one left
behind by a killed build is ignored and removed.
