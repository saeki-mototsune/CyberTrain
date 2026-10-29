---
path: tutorial.html
title: "Getting started: the blog"
description: "Build the Rails Getting Started blog, articles with comments, with CyberTrain: scaffold, migrate, nest routes, test with Cybertrain::Test and build for deployment with cybertrain build."
og_title: "Getting started with CyberTrain: the blog"
og_description: "Mirrors Rails' own Getting Started: a blog with articles and comments, built with CyberTrain on Spinel."
og_image: tutorial.png
crumb: Tutorial
nav: tutorial
toc_title: "Steps 00–15"
meta:
  - term: You need
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, SQLite 3 headers (Spinel `2026.10.27.7020` is installed for you) <a class="meta-link" href="#requirements">Step 00</a>'
  - term: You start from
    text: "`gem install cybertrain`"
  - term: You finish with
    text: "`dist/blog`"
---

# Getting started: the&nbsp;blog

Mirrors Rails' own [Getting Started](https://guides.rubyonrails.org/getting_started.html):
a blog with articles and comments. You will scaffold articles, add
validations, nest comments under them, write a test that drives the app
in-process, add sign-in, attach an uploaded image, and build the app into a
deployable `dist/` folder. The finished app is
[`examples/blog`](../../examples/blog), exercised by CI on Linux and macOS.

<!-- step 00 #requirements stage: Setup · Ruby, `cc`, SQLite -->
## Requirements

> [!WHY]
> CyberTrain compiles through Spinel to C, so it needs a C toolchain and the
> SQLite headers; the `cybertrain` command is a gem, so it needs Ruby.

<!-- list: checklist -->
- Ruby 3.2+ and RubyGems, for the `cybertrain` command only; applications
  never run on CRuby. Building Spinel also needs Ruby&rsquo;s `prism` gem:
  Ruby 3.3 and newer bundle it; on Ruby 3.2, run `gem install prism` (with
  Ruby&rsquo;s development headers, `ruby-dev` on Debian/Ubuntu).
  `cybertrain doctor` checks it.
- Spinel `2026.10.27.7020`, a release of the
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) fork,
  which carries the fixes CyberTrain needs ahead of an upstream release;
  untested against other versions. You do not install it by hand: the first
  command that needs it builds that release into `~/.cybertrain` (a few
  minutes, once), unless a `spinel` of that release is already on `PATH`.
- A C toolchain (`cc`, or the compiler `CC` names) and `make`, plus `git` and
  `curl`, to build Spinel, which compiles every program to C.
- SQLite 3 and zlib headers and libraries: `libsqlite3-dev` and `zlib1g-dev`
  on Debian/Ubuntu; present with Xcode's command line tools on macOS.
- OpenSSL headers (`libssl-dev`) are optional: without them Spinel builds
  without its `openssl` package, which CyberTrain does not use.

`cybertrain doctor` checks these tools and headers and the Spinel install;
when a required one is missing it also prints the install command for your
platform.

<details><summary>How CyberTrain installs Spinel — What happens the first time a command needs `spin`</summary>

`cybertrain new`, `db`, `server`, `build` and `spin` first look for Spinel
`2026.10.27.7020`: a `spinel` and `spin` of that release already on `PATH`,
else the copy under `~/.cybertrain/spinel/2026.10.27.7020/`, else they build
that copy from the Spinel release tag (`git clone`, `make deps`, `make -j`,
`make install`), once, in a few minutes. The log is
`~/.cybertrain/log/spinel-2026.10.27.7020-build.log`; if a tool the build
needs is missing, `cybertrain` says which and prints the install command for
your platform before it starts.

`cybertrain setup` does the same on request (`--force` rebuilds the copy under
`~/.cybertrain`) and, when its own copy is the one in use, prints the line
that puts it on your `PATH`, for running `spin` yourself:

```shell terminal — any directory
export PATH="$HOME/.cybertrain/bin:$PATH"
```

`~/.cybertrain/bin` holds `spinel` and `spin` links to the release in use.
Without it on `PATH`, `cybertrain spin ARGS...` runs `spin` with that release
from any directory. `CYBERTRAIN_HOME` replaces `~/.cybertrain`, and
`CYBERTRAIN_SPINEL_HOME=PREFIX` uses the Spinel installed in `PREFIX` instead
(it must be that release). A `spinel` of another release on `PATH` is never
used or touched.

</details>

> [!NOTE]
> No machine to install on? The [playground](site:playground.html) opens this
> blog in a GitHub Codespace with steps 02, 03, 04 and 07 already done.

<!-- step 01 #install stage: Setup · the `cybertrain` CLI -->
## Install the CLI

> [!WHY]
> `cybertrain` is the command that creates apps, scaffolds resources,
> migrates, serves and builds.

The first line installs it from RubyGems. The rest is the whole tutorial at a
glance; the steps below take it one command at a time.

<figure class="code" data-lang="shell" markdown="0">
<figcaption><span class="code-path">terminal &mdash; any directory, then&nbsp;blog/</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="Code: terminal &mdash; any directory, then blog/"><code><span class="ln cmd">gem install cybertrain</span>
<span class="ln cmd">cybertrain new blog          <span class="c"># installs Spinel 2026.10.27.7020 the first time (a few minutes)</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># production: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

The `cybertrain` command is plain Ruby and the gem runs it under CRuby (3.2 or
newer); neither the framework nor Spinel is in the gem. Its commands
(`cybertrain help` prints them):

<!-- list: points -->
- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]] [--skip-spin]`
  creates an application in NAME, then runs `spin lock` and `spin run gen` in
  it, installing Spinel first when it is needed.
- `cybertrain generate scaffold NAME field:type ...` (alias `g scaffold`) adds
  a resource to the application in the current directory.
- `cybertrain generate authentication` adds email-and-password sign-in to the
  application in the current directory ([step 13](#authentication)).
- `cybertrain generate attachment MODEL FIELD [--any]` adds a file upload to a
  scaffolded model in the application in the current directory
  ([step 14](#attachments)).
- `cybertrain db migrate` generates, applies pending migrations, and generates
  again (`spin run gen; spin run db -- migrate; spin run gen`);
  `cybertrain migration` is kept as an alias.
- `cybertrain db COMMAND...` runs any other database command after
  `spin run gen`: `status`, `rollback [N]` (which generates again afterwards),
  `schema:dump`, `create`.
- `cybertrain server [PORT]` generates, then starts the development server
  (`spin run gen; spin run NAME`, or `spin run NAME -- PORT`; default port 3000).
- `cybertrain build` builds NAME with `app/views/` embedded and assembles
  `dist/` (the binary, `public/`, `storage/`, `tmp/`).
- `cybertrain spin ARGS...` runs `spin` with the pinned Spinel, from any
  directory: `cybertrain spin test`, `cybertrain spin run gen -- --check`.
- `cybertrain setup [--force]` installs Spinel `2026.10.27.7020` into
  `~/.cybertrain` unless a `spinel` of that release is already on `PATH`;
  `--force` rebuilds the copy under `~/.cybertrain`.
- `cybertrain doctor` checks the C toolchain, the SQLite headers and the
  Spinel install.
- `cybertrain version` prints the version (`cybertrain 0.3.1`);
  `cybertrain help` prints the usage.

> [!NOTE]
> `db`, `server` and `build` run inside an application; NAME is the
> `[package] name` in its `spin.toml`.

<!-- step 02 #new-app stage: You write · `blog/` -->
## Create the application

> [!WHY]
> You get the Rails directory conventions plus three `bin/` programs:
> `bin/blog.rb` (the app), `bin/gen.rb` (the generator) and `bin/db.rb`
> (development migrations).

```shell terminal — any directory
cybertrain new blog
cd blog
```

`cybertrain new` writes the application with its `spin.toml` pointing at the
release matching the CLI:

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }
```

Then it makes sure Spinel is installed (the first time, that means building
Spinel `2026.10.27.7020` into `~/.cybertrain`: a few minutes, once; see
[step 00](#requirements)) and runs `spin lock` (spin fetches the framework
into its cache, `~/.cache/spin/packages/`, and pins the commit in `spin.lock`)
and `spin run gen`, much as `rails new` runs `bundle install`, so
`cybertrain server` works right away. It ends by printing the next steps.
Nothing of the framework is copied into the app; commit `spin.toml` and
`spin.lock`.

> [!NOTE]
> If Spinel or one of the two `spin` steps fails, the files stay, `new` exits
> with 1 and prints what to run once the cause is fixed (for Spinel:
> `cybertrain setup`, then `cybertrain spin lock && cybertrain spin run gen`
> in the new directory). `--skip-spin` only writes the files; `--path DIR`
> depends on a local checkout instead, `--git URL [--ref R]` on the framework
> at URL (at branch or tag R), and `--version V` on an index version once
> `cybertrain` is on a `spin-index`.

App names use lowercase letters, digits and `_`, starting with a letter. The
generated tree:

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/
```

`bin/blog.rb` is the application's one entry point, the program
`spin build blog` compiles: `./blog` serves, `./blog migrate` and
`./blog db status` manage the database. `bin/gen.rb` runs the generator
(`spin run gen`), and `bin/db.rb` runs the migrator during development
(`cybertrain db migrate` uses it, since `bin/blog.rb` cannot compile until the
first migration has generated `gen/models/`). `gen/` already holds `views.rb`,
the committed, empty table of embedded views.

`ApplicationController` starts like this, so a missing record maps to a 404
through `rescue_from`:

```ruby app/controllers/application_controller.rb
class ApplicationController < Cybertrain::Controller
  rescue_from Cybertrain::RecordNotFound, with: :record_not_found

  private

  def record_not_found
    render plain: "Not Found", status: :not_found
  end
end
```

<!-- step 03 #scaffold-article stage: You write · `app/`, `db/migrate/` -->
## Scaffold an article

> [!WHY]
> One command writes the whole CRUD slice, Rails-style.

```shell terminal — blog/
cybertrain generate scaffold article title:string body:text
```

It writes a migration, a model, a controller and five views (`index`, `show`,
`new`, `edit`, `_form`), and inserts `resources :articles` into
`config/routes.rb`. Field types are `string`, `text`, `integer`, `float`,
`boolean`, `date`, `datetime` and `references`; the default is `string`. The
quick start's `cybertrain g scaffold` is the same command.

> [!NOTE]
> Existing files are never overwritten: each file is reported as `create`,
> `identical` or `exist`.

<!-- step 04 #root-route stage: You write · `config/routes.rb` -->
## Point the root route

> [!WHY]
> `/` should show the article list.

```ruby config/routes.rb
# config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
```

> [!NOTE]
> Routes are read at build time: `spin run gen` turns them into
> `gen/routes.rb`. `cybertrain server`, `cybertrain db migrate` and
> `cybertrain build` run it for you.

<!-- step 05 #validations stage: You write · `app/models/` -->
## Add model validations

> [!WHY]
> As in Rails' guide, add a length validation by hand.

```ruby app/models/article.rb
# app/models/article.rb -- only the first string field gets a default
# presence validation; add anything past that yourself.
class Article
  validates :title, presence: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` has no superclass written: the `Cybertrain::Model` superclass,
columns and finders come from `gen/models/article.rb`. A failed save reports
messages such as "Title can't be blank" and "Body is too short (minimum is 10
characters)".

<!-- step 06 #articles-controller stage: You write · `app/controllers/` -->
## The ArticlesController

> [!WHY]
> Full CRUD, Rails-shaped down to strong params and flash-then-redirect,
> except for two things Spinel forces everywhere.

```ruby app/controllers/articles_controller.rb
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

> [!RULE] Spinel rule: new_action
> ### `new_action`, not `new`
>
> A method literally named `new` would shadow `ArticlesController.new(ctx)`,
> which the framework uses to construct the controller. The route
> `GET /articles/new` still maps to it; you only rename the method. The view is
> still `new.html.erb` and `render :new` is unchanged.

> [!RULE] Spinel rule: callbacks
> ### Callbacks take the controller explicitly
>
> There is no `instance_exec` on a stored block, so a block callback receives
> the controller (or the record) as an argument:
> `before_action { |c| c.do_thing }`, not `before_action { do_thing }`. Actions
> and callbacks are called by their literal name, never `send`.

The scaffold writes the full controller with `index`, `show`, `edit`, `update`
and `destroy` too; the excerpt above omits them. In `index`,
`@articles = Article.all.to_a`: the `.to_a` is required.

> [!NOTE]
> Instance variables are found by a lexical scan of `@ivar =`, so re-run
> `cybertrain spin run gen` after adding one; the development server does this
> for you.

<!-- step 07 #run stage: Build time, then run time · `gen/` &rarr; `build/bin/blog` -->
## Generate, migrate, run

> [!WHY]
> Turn schema and routes into `gen/`, create the SQLite database, start the
> server.

```shell terminal — blog/
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen
cybertrain server        # http://127.0.0.1:3000; rebuilds on Ruby edits, views reload without a rebuild
```

`spin run gen` reads `db/schema.rb` and `config/routes.rb`, scans `app/` and
writes `gen/`; `spin run db -- migrate` applies `db/migrate/*.rb` and rewrites
`db/schema.rb`. The order matters: the first `spin run gen` puts the new
migration into `gen/migrations.rb`, which `bin/db.rb` requires, and the second
builds the models from the rewritten `db/schema.rb`.

`cybertrain server` prints each `spin` command it runs, then the app's boot
banner. The first start compiles the app, so it takes a while:

```text output — cybertrain server
=> Booting cybertrain 0.3.1
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

<!-- list: points -->
- Re-run `cybertrain spin run gen` and commit `gen/` after touching the
  schema, routes, or a controller's or model's callbacks and ivars. The
  development server does this for you.
- Change the port with `cybertrain server 4000` (or `PORT=4000`).
- `cybertrain db` adds the `--` that `spin run db` needs before its arguments;
  `cybertrain db status` and the other database commands work the same way.

> [!RULE] Spinel rule: no console
> ### There is no console
>
> `rails console` has no counterpart: Spinel has no `eval`. Ruby changes need a
> rebuild, which `cybertrain server` does for you in development (rebuild, stop,
> `execv`). In development views are parsed from disk per request, so editing
> one needs no rebuild; `cybertrain build` embeds them for production.

<!-- step 08 #scaffold-comment stage: You write · `db/migrate/`, `app/` -->
## Scaffold comments

> [!WHY]
> The `references` type gives you the foreign key that the association is
> derived from.

```shell terminal — blog/
cybertrain generate scaffold comment commenter:string body:text article:references
cybertrain db migrate    # the scaffold wrote a migration for the comments table
```

`article:references` adds an `article_id` column, index and foreign key —
enough for `Article`/`Comment` to get their association; there's no
`has_many`/`belongs_to` to write, `spin run gen` reads it off the foreign key.
The resulting schema:

```ruby db/schema.rb (excerpt)
  s.create_table "comments" do |t|
    t.string "commenter"
    t.text "body"
    t.integer "article_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  s.add_index "comments", ["article_id"], name: "index_comments_on_article_id"

  s.add_foreign_key "comments", "articles", column: "article_id"
```

The scaffold inserts an independent `resources :comments` line, which the next
step replaces.

> [!EXAMPLE] Deleting an article with comments
> ### Deleting an article with comments
>
> Associations come from foreign keys only, and `dependent:` is not implemented.
> The example adds a `before_destroy` callback that takes the record explicitly:
>
> ```ruby app/models/article.rb (excerpt)
>   # Rails' `has_many :comments, dependent: :destroy`: the foreign key
>   # would refuse to delete an article that still has comments.
>   before_destroy { |article| Comment.where(article_id: article.id).delete_all }
> ```

<!-- step 09 #nested-routes stage: You write · `config/routes.rb` -->
## Nest the routes

> [!WHY]
> Rails' guide nests comments under articles.

```ruby config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"

  # A nested block takes the mapper explicitly (Spinel's instance_eval
  # trampoline only rewires `self` for the outermost block): `articles.resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
end
```

> [!RULE] Spinel rule: explicit mapper
> ### Nested blocks take the mapper explicitly
>
> Write `resources :articles do |articles|` and `articles.resources :comments`,
> not a bare `resources :comments`. Spinel's `instance_eval` trampoline only
> rewires `self` for the outermost block.

<!-- step 10 #comments-controller stage: You write · `app/controllers/` -->
## The CommentsController

> [!WHY]
> Only two actions are reachable, and the parent article comes from the URL
> (`params[:article_id]`), not `:id`.

```ruby app/controllers/comments_controller.rb
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

Then add validations to the comment model:

```ruby app/models/comment.rb
class Comment
  validates :commenter, presence: true
  validates :body, presence: true
end
```

> [!NOTE]
> `Article#comments` is an Array here, so Rails'
> `@article.comments.find(params[:id])` becomes
> `Comment.where(article_id: @article.id).find(params[:id])`. A comment under
> the wrong article returns 404.

<!-- step 11 #views stage: Run time · `app/views/`, read from disk in development, embedded by `cybertrain build` -->
## Views and partials

> [!WHY]
> The article page lists its comments and ends with a form bound to
> `[@article, @comment]`.

First, delete the now-unreachable `index`, `show`, `new` and `edit` comment
views, and give `ArticlesController#show` a blank `@comment`:

```ruby app/controllers/articles_controller.rb (excerpt)
  def show
    @comment = Comment.new
  end
```

Then render the comments and the form on the article page:

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
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

The comment partial, as it ships in the example:

```erb app/views/comments/_comment.html.erb
<%# locals: (comment:) %>
<div class="comment">
  <p>
    <strong>Commenter:</strong>
    <%= comment.commenter %>
  </p>

  <p>
    <strong>Comment:</strong>
    <%= comment.body %>
  </p>

  <%= button_to "Destroy comment", [@article, comment], method: :delete %>
</div>
```

Both `button_to ... [@article, comment]` and
`form_with(model: [@article, @comment])` resolve through the same
`[parent, child]` rule: a new child routes to the nested collection
(`article_comments_path`), a persisted one to the nested member
(`article_comment_path`) — generated into `gen/routes.rb` from the nested
`resources` block above.

> [!RULE] Views are a closed grammar
> ### Views are a closed grammar, not Ruby
>
> Spinel has no `eval`, so templates are interpreted against a fixed grammar.
> `link_to` has no `method:` option; use `button_to`. `each` takes one or two
> block parameters. A strict-locals comment such as `<%# locals: (comment:) %>`
> takes no default values. A partial gets a copy of the caller's environment, so
> `@article` is visible in `comments/_form`.

<!-- step 12 #test stage: Build time · `cybertrain spin test` -->
## Test it

> [!WHY]
> minitest and RSpec find tests by reflection, which an ahead-of-time compiler
> cannot do, so CyberTrain ships `Cybertrain::Test`.

### A model test

```ruby test/articles.rb (snippet)
require_relative "support/blog_test"   # the app, BLOG and Cybertrain::Test

test "title must be present" do
  article = Article.new(body: "a body long enough to pass length")
  refute article.save
  assert_includes article.errors.full_messages, "Title can't be blank"
end
```

Assertions: `assert`, `refute`, `assert_equal`, `assert_nil`,
`assert_includes`, `assert_raises("Class") { }`, `flunk`. The example also
uses `assert_response` and `assert_redirected_to`.

### A full HTTP flow

```ruby test/articles.rb (snippet)
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

`Cybertrain::Test::Client` drives an app in-process (no socket) with a cookie
jar, so sessions and CSRF behave as behind a browser. Requests without the
token get a 403.

> [!COMPILE] What the snippets leave out
> ### What the snippets leave out
>
> - `support/blog_test` is
>   [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb):
>   copy it into your app&rsquo;s `test/support/`, where files are required, not
>   run. It migrates a fresh `storage/test.sqlite3`, boots the app as `BLOG`,
>   loads `Cybertrain::Test` and its client, and gives you `BlogTest.form_token`
>   (the CSRF token of the last rendered form) and `BlogTest.article_path`.
> - End the file with `Cybertrain::Test.run!`, which runs the tests and prints
>   the lines the snapshot compares.
> - Set `c.log_level = :none if c.test?` in `config/app.rb` to keep request logs
>   out of the compared output.

### Run the tests

```shell terminal — blog/
cybertrain spin test
```

`cybertrain spin test` runs `spin test` with the pinned Spinel; with the
toolchain on `PATH` ([step 00](#requirements)), `spin test` does the same. It
compiles each `test/*.rb` into its own program and diffs its output (stdout
and stderr together) against a committed `test/<name>.rb.expected` snapshot.
Files in `test/support/` are required, not run. To write a snapshot:

```shell terminal — blog/
cybertrain spin test --regen test/<name>.rb
rm -f build/test/<name>; cybertrain spin test test/<name>.rb; [ -x build/test/<name> ] && ./build/test/<name> > test/<name>.rb.expected 2>&1
```

> [!NOTE]
> `--regen` writes the snapshot from CRuby's output. Tests that touch SQLite
> through FFI can't run under CRuby, so their snapshot comes from the compiled
> binary (the second line above). `cybertrain spin test` exits non-zero while
> a snapshot is stale, so it is followed by `;`, not `&&`; the `[ -x ]` check
> skips the capture when the compile failed, so the old snapshot is kept.
> Tests that cannot run under CRuby need this snapshot before
> `cybertrain spin test` can pass; other tests without a snapshot are compared
> with CRuby's output.

<!-- step 13 #authentication stage: You write · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Add sign-in

> [!WHY]
> So far anyone can edit or delete an article. Like Rails 8&rsquo;s
> `bin/rails generate authentication`, one command adds email-and-password
> sign-in, written as code the app owns rather than installed as an engine.

```shell terminal — blog/
cybertrain generate authentication
cybertrain db migrate    # creates the users and sessions tables
```

It writes migrations for `users` (`email_address`, `password_digest`, a unique
index) and `sessions` (one row per signed-in browser), the `User` and
`Session` models, `SessionsController` (`/session/new`, `POST /session`,
`DELETE /session`), `RegistrationsController` (`/sign_up`) and their views, a
`sessions/_nav` partial at the top of the layout, and `test/authentication.rb`
with `test/support/app_test.rb`. It also inserts the routes, and a block right
after the class line of `ApplicationController`:

```ruby app/controllers/application_controller.rb (excerpt)
class ApplicationController < Cybertrain::Controller
  before_action :resume_session          # sets @current_user and @current_session
  before_action :require_authentication  # 303 to /session/new unless signed in

  def self.allow_unauthenticated_access(only: [], except: [])
    skip_before_action(:require_authentication, only: only, except: except)
  end
  # authenticated?, start_new_session_for(user), terminate_session,
  # after_authentication_url ...
```

From now on every action needs a signed-in user, and a visitor is redirected
to `/session/new`. Open the pages anyone may read again, as Rails&rsquo; guide
does:

```ruby app/controllers/articles_controller.rb (excerpt)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show]
  before_action :set_article, only: [:show, :edit, :update, :destroy]
```

`resume_session` still runs on those pages, so templates can read
`@current_user`. Hide what a visitor cannot use:

```erb app/views/articles/show.html.erb (excerpt)
<% if @current_user %>
  <%= button_to "Destroy this article", article_path(@article), method: :delete %>
<% end %>

<% if @current_user %>
  <h2>Add a comment:</h2>
  <%= render "comments/form" %>
<% end %>
```

Start the server and open `http://127.0.0.1:3000/sign_up` to create the first
user. Rails&rsquo; generator has no sign-up page and leaves that to the
console; CyberTrain has no console, so it writes `RegistrationsController`.
Delete it and its routes for an invitation-only app.

<details><summary>An invitation-only app: `--invite-only` — No sign-up page; the first user comes from the command line or a page only the server's machine can open</summary>

The sign-up page lets anyone who reaches the server register, which is the
wrong default for an internal tool: whoever gets there before the admin
does has an account. `--invite-only` writes no `RegistrationsController`
and no sign-up link; the first user comes from the command line or from a
page only the server's own machine can open, with a link the server prints
when it starts:

```shell terminal — blog/
cybertrain generate authentication --invite-only
cybertrain db migrate
cybertrain server        # then open the http://127.0.0.1:3000/setup?token=... link it prints, on the same machine
```

In production, from the directory the binary runs in:

```shell terminal — production host
./blog user ann@example.com                        # reads the password from stdin (one line)
printf '%s' "$PASSWORD" | ./blog user ann@example.com
./blog user ann@example.com 's3cr3t-s3cr3t'        # or as an argument (visible in ps)
```

<!-- list: points -->
- `app/commands/user_command.rb` registers the `user` command with
  `Cybertrain::Main.command` (so `./blog help` lists it) and is required
  from `bin/blog.rb`. `EMAIL [PASSWORD]` creates the user, or sets the
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
  The request log does not repeat it: `token` is one of the default
  `filter_parameters`, so the line reads `Started GET
  "/setup?token=[FILTERED]"` (unless `config.filter_parameters` or
  `CYBERTRAIN_FILTER_PARAMETERS` leaves `token` out). Once the user exists,
  the token opens nothing.
- For a first run behind a proxy on another host, `BLOG_SETUP_OPEN=1`
  (declared in `config/app.rb` with `c.setting_bool :setup_open`) lifts the
  address check, still only while no user exists and still only with the
  token. Unset it once the user is there.
- While no user exists, the server logs `[WARN] no user exists yet: run
  ./blog user EMAIL, or open /setup?token=<token> from this machine` before
  it boots (`UserCommand.warn_if_no_user`, called from `bin/blog.rb` when
  `Cybertrain::Main.server?(ARGV)`; it connects for that one question and
  says nothing when the users table is not migrated yet). That line is the
  only place the token is printed.

The generated `test/authentication.rb` covers both: `/setup` with and
without the token (`SetupController.setup_token`) or with a wrong one, from
another address (`client.peer_address = "203.0.113.7"`), through a proxy,
once a user exists and with the switch on, and the `user` command run
in-process through `Cybertrain::Main.run`. All of it is application code,
yours to change (docs/design.md D29); the framework only provides
`request.loopback?`, `Main.command`, `Main.server?`,
`Crypto.random_token` / `Crypto.secure_compare` and the test client's
`peer_address`.

</details>

> [!RULE] Spinel rule: has_secure_password
> ### `has_secure_password` is written out
>
> Spinel cannot define methods at run time, so the `User` model spells out what
> `has_secure_password` would define: `password=`, `authenticate` and
> `User.authenticate_by(email_address:, password:)`. Passwords are hashed by
> `Cybertrain::Password`, PBKDF2-HMAC-SHA256 in Ruby, 100,000 iterations by
> default (about 0.2 s compiled): bcrypt would need a C library the binary
> links. Raise the cost with `Cybertrain::Password.iterations = 600_000` in
> `config/app.rb`; `User#authenticate` rehashes each user as they sign in.

<details><summary>Authentication: what the framework provides — The pieces the generator is built from, usable without it</summary>

The generator above writes the flow; the pieces it is built from are
framework API, usable without it (for an API token, an admin password, a
hand-written sign-in):

<!-- list: points -->
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

</details>

### Update the tests

Any [step 12](#test) test that expects a form, submits one, or reaches an
action other than `index` and `show` now meets the sign-in page instead. Sign
the client in first, with the helpers the generator wrote into
`test/support/app_test.rb`:

```ruby test/signed_in.rb
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

> [!NOTE]
> Run `cybertrain spin test` as in [step 12](#test); `test/authentication.rb`
> and this test use SQLite, so their snapshots come from the compiled binary.
> `examples/blog` stops before this step. Sign-in attempts are rate limited
> as in Rails' generator: `SessionsController` declares `rate_limit to: 10,
> within: 3 * 60, only: [:create]`, ten attempts per client address every
> three minutes, then back to the form with "Try again later." until the
> window closes. Not generated: password reset, whose e-mail needs the app's
> SMTP settings (`Cybertrain::Mailer`,
> [Sending e-mail](external-services.md#sending-e-mail)), which the generator
> cannot know.

<!-- step 14 #attachments stage: You write · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Add a cover image

> [!WHY]
> An article can carry a picture. The same split as sign-in: the framework
> parses `multipart/form-data` and stores the bytes, and one command writes
> the rest as code the app owns, in place of Active Storage&rsquo;s
> `has_one_attached`.

```shell terminal — blog/
cybertrain generate attachment article cover   # a new model: generate scaffold NAME field:type ... cover:attachment
cybertrain db migrate                          # adds the cover_* columns to articles
```

It writes a migration that adds five columns to `articles` (`cover_key`,
`cover_filename`, `cover_content_type`, `cover_byte_size`, `cover_checksum`;
the file itself is not in SQLite) and a block in `Article` with `cover_file=`,
`cover_attached?`, `cover_url`, a validation and save and destroy callbacks.
In `ArticlesController` it adds a `cover` action behind
`before_action :set_article` and one line in `create` and in `update`:

```ruby app/controllers/articles_controller.rb (excerpt)
class ArticlesController < ApplicationController
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 13 wrote [:index, :show]; the generator added :cover
  before_action :set_article, only: [:show, :edit, :update, :destroy, :cover]

  # GET /articles/1/cover -- @article comes from before_action :set_article, so
  # the download is scoped exactly like show (and authentication applies).
  # send_blob is the one way to serve uploads: it sets the type from what the
  # server detected, nosniff, a locked-down CSP and Content-Disposition
  # (inline for images only, a download otherwise).
  def cover
    if @article.cover_attached? && Cybertrain::BlobStore.exist?(@article.cover_key)
      send_blob(Cybertrain::BlobStore.read(@article.cover_key), filename: @article.cover_filename, content_type: @article.cover_content_type)
    else
      head 404
    end
  end
  # ...
  def create
    @article = Article.new(article_params)
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.save
  # ...
  def update
    @article.cover_file = params.nested(:article).upload(:cover)
    if @article.update(article_params)
```

Step 13 made every page private, and the image on a public article page is
fetched from `/articles/1/cover`. The generator makes the download exactly as
public as the article page: since `allow_unauthenticated_access` lists
`:show`, it adds `:cover` to that list, as in the first line above, so
visitors who may read the article see its image. Where the article page needs
a signed-in user, so does the download. Whatever `set_article` does to limit
which articles a user may see limits the download too.

The generator also adds `get "/articles/:id/cover"` to `config/routes.rb`,
`multipart: true` and a file input to the form, above the submit button, and
the image to the show page, right after the `<h1>`:

```erb app/views/articles/_form.html.erb (excerpt)
<%= form_with(model: article, multipart: true) do |f| %>
  <%# ... %>
  <div class="field">
    <%= f.label :cover %>
    <%= f.file_field :cover, accept: "image/png,image/jpeg,image/gif,image/webp" %>
  </div>
```

```erb app/views/articles/show.html.erb (excerpt)
<h1>Article</h1>
<% if @article.cover_attached? %><p><img src="<%= @article.cover_url %>" alt="<%= @article.cover_filename %>"></p><% end %>
```

> [!RULE] Spinel rule: has_one_attached
> ### `has_one_attached` is written out
>
> Spinel cannot define methods at run time (no `define_method`), so there is no
> `has_one_attached` and no shared attachments table. The generator spells out
> what it would define as methods named after the field, in `Article`, and puts
> the metadata in five columns of `articles`. They are `NOT NULL`, with `""` and
> `0` meaning &ldquo;nothing attached&rdquo;: nullable columns cost Spinel its
> type inference. SQLite holds the metadata only (a text value stops at a NUL
> byte); the bytes are files.

### How files are served

<!-- list: points -->
- **Types.** By default only PNG, JPEG, GIF and WebP up to 2 MB are accepted
  (`COVER_TYPES` and `COVER_MAX_BYTES` in the model; `--any` accepts any
  type). The type is detected from the file&rsquo;s first bytes, never taken
  from the browser.
- **Storage.** The bytes go to `storage/uploads/<2 hex>/<32 hex key>`
  (`Cybertrain::BlobStore`, mode 0600). Replacing a file deletes the old one,
  and destroying the article deletes its file. Back up `storage/uploads/`
  together with the SQLite file.
- **Serving.** Files go out through `send_blob` in the controller, never from
  `public/`. The four image types are served inline; anything else is a
  download (`application/octet-stream`). Every response carries
  `X-Content-Type-Options: nosniff` and
  `Content-Security-Policy: default-src 'none'; sandbox`.
- **Params.** `params.nested(:article).upload(:cover)` is a
  `Cybertrain::UploadedFile`, or nil when no file was chosen. `permit` never
  returns files, so a file can only arrive through that explicit line. The
  CSRF token is read from multipart bodies like any form&rsquo;s. A broken or
  oversize body is a 400; `max_upload_bytes` and `max_multipart_parts` in
  `config/app.rb` set the limits, and `upload_root` the directory.

Start the server, edit an article and choose an image. The generator also
wrote `test/attachment_article_cover.rb`, which tests the whole flow and signs
in first now that the app has a `User`. Since `:cover` is public here, it
checks that a visitor can download the cover, and it fills the body with
`"A article."`, stretched to the 10-character minimum from
[step 05](#validations).

> [!NOTE]
> Run `cybertrain spin test` as in [step 12](#test); the test uses SQLite, so
> its snapshot comes from the compiled binary. `examples/blog` stops before
> this step. Not built yet: several files per field, S3 or other remote
> storage, image variants, and streaming large bodies to disk (the whole body
> is read into memory, up to `max_body_bytes`).

<!-- step 15 #ship stage: Run time · `dist/blog` -->
## Build for deployment

> [!WHY]
> One command builds the app into a deployable `dist/` folder, with every view
> embedded.

```shell terminal — blog/
cybertrain build
```

This writes `dist/`: the app binary with every view embedded, plus the files
it uses beside it. It runs `spin run gen -- --embed-views`, `spin build blog`
and `spin run gen` (which puts the committed, empty `gen/views.rb` back, even
after a failure or Ctrl-C), then assembles:

<ul class="ship-grid">
  <li class="ship-bin"><code>dist/blog</code><span>the compiled framework, controllers, models and template interpreter, with every view embedded</span></li>
  <li><code>dist/public/</code><span>static assets and error pages, or let a reverse proxy serve it</span></li>
  <li><code>dist/storage/</code><span>created empty; the SQLite file by default (a rebuild never empties it)</span></li>
  <li><code>dist/tmp/</code><span>created empty (a rebuild never empties it)</span></li>
</ul>

Copy `dist/` to a machine with the same OS and CPU (the binary links the
system SQLite) and run it there. A built binary is production by default
(`CYBERTRAIN_ENV` overrides). Set `CYBERTRAIN_SECRET_KEY_BASE`; for
illustration:

```shell terminal — production host
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` applies the migrations compiled into the binary, and
`./blog db status` shows their status; `PORT` sets the port. Keep the secret
the same across restarts: changing it ends every session.

`Cybertrain::Config` reads the environment first; `config/app.rb` overrides:

<div class="table-scroll" role="region" aria-label="Environment variables" tabindex="0" markdown="0">
<table class="env">
  <thead><tr><th scope="col">Variable</th><th scope="col">Attribute</th><th scope="col">Default</th></tr></thead>
  <tbody>
    <tr><td data-label="Variable"><code>CYBERTRAIN_ENV</code></td><td data-label="Attribute"><code>env</code></td><td data-label="Default"><code>"development"</code>; <code>"production"</code> in a binary from <code>cybertrain build</code> (also <code>"test"</code>)</td></tr>
    <tr><td data-label="Variable"><code>PORT</code></td><td data-label="Attribute"><code>port</code></td><td data-label="Default"><code>3000</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_DATABASE</code></td><td data-label="Attribute"><code>database_path</code></td><td data-label="Default"><code>storage/#{env}.sqlite3</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SECRET_KEY_BASE</code></td><td data-label="Attribute"><code>secret_key_base</code></td><td data-label="Default">required in production; dev/test auto-generate one into <code>tmp/secret_key</code></td></tr>
    <tr><td data-label="Variable"><code>SPINEL_WORKERS</code></td><td data-label="Attribute"><code>workers</code></td><td data-label="Default"><code>1</code></td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_HOST</code></td><td data-label="Attribute"><code>host</code></td><td data-label="Default"><code>"127.0.0.1"</code>; <code>0.0.0.0</code> listens on every interface (containers)</td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SESSION_SAME_SITE</code></td><td data-label="Attribute"><code>session_same_site</code></td><td data-label="Default"><code>"Lax"</code>; also <code>Strict</code> or <code>None</code> (<code>None</code> always adds <code>Secure</code>); anything else stops the server at boot</td></tr>
    <tr><td data-label="Variable"><code>CYBERTRAIN_SESSION_PARTITIONED</code></td><td data-label="Attribute"><code>session_partitioned</code></td><td data-label="Default"><code>false</code>; <code>1</code> or <code>true</code> adds <code>Partitioned</code> (and <code>Secure</code>)</td></tr>
  </tbody>
</table>
</div>

```ruby config/app.rb
# config/app.rb
Cybertrain.configure do |c|
  c.port = 3000
  c.workers = 1
end
```

<!-- list: points -->
- The server speaks plain HTTP/1.1: put nginx or Caddy in front for TLS and
  HTTP/2. The session cookie is `Secure` in production, so serve it over HTTPS
  (set `c.session_secure = false` in `config/app.rb` only if production really
  is plain http).
- Production refuses to start without `CYBERTRAIN_SECRET_KEY_BASE`.
- In production an exception answers 500, and a bare error response (the
  router's plain-text 404, `head :not_found`, `render plain:`) is replaced by
  `public/<status>.html` when that file exists; `cybertrain new` writes
  `404.html` and `500.html`.
- `SIGTERM` stops accepting, lets requests in flight finish and exits when
  they are done, or after the server's `drain_timeout` (10 s).
- The watcher and rebuild loop never run in production. A running
  `cybertrain server` skips its rebuilds while `cybertrain build` holds
  `tmp/cybertrain-build.lock`.

`cybertrain new` also writes a [Kamal 2](https://kamal-deploy.org) setup. The
`Dockerfile` runs `cybertrain setup` and `cybertrain build` in an Ubuntu build
stage and copies `dist/` into a slim stage of the same release, which migrates
on boot and then serves on `0.0.0.0:3000`. Beside it are `.dockerignore`,
`config/deploy.yml` (kamal-proxy with Let&rsquo;s Encrypt in front, the health
check on `public/up.html`, the SQLite file on a volume at `/app/storage`) and
`.kamal/secrets`, which reads `KAMAL_REGISTRY_PASSWORD` and
`CYBERTRAIN_SECRET_KEY_BASE` from the environment. Fill in the values marked
`CHANGE ME` in `config/deploy.yml`, commit, then:

```shell terminal — blog/
kamal setup    # first time: installs Docker and kamal-proxy on the server, builds, pushes and starts
kamal deploy   # every deploy after that
```

The binary is compiled inside the image, so it always matches the
image&rsquo;s OS; set `builder.arch` in `config/deploy.yml` to the
server&rsquo;s CPU. Deploy to one server: the database is a SQLite file on
that server&rsquo;s volume. Part 8 of
[`docs/deploy.md`](../../docs/deploy.md#第-8-部-kamal-でデプロイする) (Japanese; in
English, [`docs/deploy-kamal.md`](../../docs/deploy-kamal.md)) walks through
it, backups included.

The finished app, [`examples/blog`](../../examples/blog#deploying-with-kamal),
carries this setup with one difference: it builds against the framework in the
repository (`path = "../.."` in its `spin.toml`), so its `Dockerfile` runs
`cybertrain setup` and `cybertrain build` from the checkout instead of
installing the gem, and the build context is the repository root
(`builder.context: ../..`, with `Dockerfile.dockerignore` sending only the
framework and the app). CI
([`blog-image.yml`](../../.github/workflows/blog-image.yml)) builds that image
on every change, checks the health check, an article created through the form,
a clean stop and the database kept on its volume, and loads
`config/deploy.yml` with Kamal.

> [!NOTE]
> How these pieces fit together, and Kamal compared with a server behind
> Caddy, are on the [deploy page](site:deploy.html).

<!-- step + #things-to-know -->
## Things to know

> [!WHY]
> Limits and quirks worth knowing before they surprise you.

<!-- list: points know -->
- Sessions hold Strings only, in an HMAC-signed cookie.
- SQLite only, through Spinel&rsquo;s FFI.
- No backtraces: errors show class, message, request line and template
  name/line.
- A misspelled attribute in a view renders blank instead of raising; this is a
  known gap.
- Associations come from schema foreign keys only; no `has_many :through`,
  `includes`, `pluck`, `dependent:`, enums, STI or polymorphic associations.
- No `namespace`, `respond_to`/formats, `constraints` or `mount`;
  `render json:` is minimal.
- Only the first string field gets a default presence validation in a
  scaffolded model.
- The generator uses a lexical scan (regexes), not a parser, over
  `app/controllers` and `app/models`.
- Views are embedded at build time: a view-only change needs
  `cybertrain build` and a restart before it reaches production.
- Build `dist/` on the same OS and CPU as the machine that runs it: the binary
  links the system SQLite.
- `SPINEL_WORKERS` defaults to `1`.
- Only Spinel `2026.10.27.7020` is tested.

<!-- step + #differences -->
## Differences from Rails

> [!WHY]
> The full table from the README, in one place.

<!-- table: cmp -->
| Rails | CyberTrain |
|---|---|
| `rails console` | No console — Spinel has no `eval` |
| Edit code, the running app picks it up | Ruby needs a rebuild; `cybertrain server` in development does this for you (rebuild, stop, `execv`) |
| Edit a view, no reload needed | Same — views are parsed from disk per request in development |
| `def new` | `def new_action` (`new` would shadow `Klass.new(ctx)`) |
| `before_action { do_thing }` (implicit `self`) | `before_action { |c| c.do_thing }` — no `instance_exec` on a stored block, so callbacks take the controller/record explicitly |
| `resources :posts do resources :comments end` | `resources :posts do |posts| posts.resources :comments end` — nested blocks take the mapper explicitly |
| ERB compiles to a method; any object, any method | Interpreted against a fixed grammar/dispatch table |
| Session holds any marshalled object | Session values are Strings only, HMAC-signed cookie |
| Many database adapters | SQLite only, via FFI |
| `has_many :through`, `includes`, `pluck`, `dependent:`, enums, STI, polymorphic associations | Not implemented; associations come from schema foreign keys only |
| `namespace`, format/`respond_to`, `constraints`, `mount` | Not implemented — flat names, `render json:` only |
| Full backtrace on an exception | Class, message, request line, template name/line — Spinel exposes no backtraces |
| Rack, its middleware, and any gem in a `Gemfile` | No Rack compatibility; a small fixed middleware set; Spinel's own `spin-index`, limited to what compiles under its Ruby subset |
| minitest / RSpec | `Cybertrain::Test` — reflection-based runners can't work ahead-of-time |
| `bin/rails generate authentication`, `has_secure_password` | `cybertrain generate authentication` writes the same shape, plus a sign-up page since there is no console; `has_secure_password` is written out on the User model over `Cybertrain::Password` (PBKDF2); no password reset (it needs the app's SMTP settings for `Cybertrain::Mailer`) |
| Mailers, jobs, ActionCable, asset pipeline, i18n | Mail and jobs in a minimal form: `Cybertrain::Mailer` sends plain text over SMTP ([Sending e-mail](external-services.md#sending-e-mail)), `Cybertrain::Job` and `Cybertrain::Scheduler` run work later or every N seconds ([Background work](background-and-operations.md#background-work)). Not built (outside the MVP): an ActionCable server (WebSocket is outbound only), an asset pipeline (`public/` is served as static files) and i18n |
<!-- table-foot: Not exhaustive. -->

<!-- step → #where-next -->
## Where next

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — The finished app, with its tests.
- [**CyberTrain on GitHub**](https://github.com/saeki-mototsune/CyberTrain) — The source, the README and releases.
- [**API reference**](site:api/index.html) — Every class and method an app uses, with examples.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Spikes and the compiler constraints they found.
- [**Spinel**](https://github.com/matz/spinel) — matz's ahead-of-time Ruby compiler.
- [**CyberTrain home**](site:index.html) — Overview, features and how it works.
