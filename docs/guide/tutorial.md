---
path: tutorial.html
title: "Getting started: the blog"
description: "Build the Rails Getting Started blog, articles with comments, with CyberTrain: install, scaffold, validate, migrate, nest comments under articles and test the app with cybertrain test."
og_title: "Getting started with CyberTrain: the blog"
og_description: "Mirrors Rails' own Getting Started: a blog with articles and comments, built with CyberTrain on Spinel."
og_image: tutorial.png
crumb: Tutorial
nav: tutorial
toc_title: "Steps 00–12"
meta:
  - term: You need
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, SQLite 3, zlib and OpenSSL headers (Spinel is installed for you) <a class="meta-link" href="#requirements">Step 00</a>'
  - term: You start from
    text: "`gem install cybertrain`"
  - term: You finish with
    text: "A blog with articles, comments and tests"
---

# Getting started: the&nbsp;blog

Mirrors Rails' own [Getting Started](https://guides.rubyonrails.org/getting_started.html):
a blog with articles and comments. You will install the CLI, scaffold
articles, add validations, nest comments under them and run the tests, and
finish with a working blog on your machine. The
[advanced tutorial](advanced-tutorial.md) then takes the same blog further:
live comments with Turbo, a background job, JSON, sign-in, an uploaded image
and a deployable build.

<!-- step 00 #requirements stage: Setup · Ruby, `cc`, SQLite -->
## Requirements

> [!WHY]
> CyberTrain compiles through Spinel to C, so it needs a C toolchain and the
> SQLite headers; the `cybertrain` command is a gem, so it needs Ruby.

<!-- list: checklist -->
- Ruby 3.2+ and RubyGems, for the `cybertrain` command and the development
  server's CRuby preview (which needs Ruby's `fiddle`); a deployed
  application never runs on CRuby. On Ruby 3.2, also `gem install prism`.
- Spinel, at the release CyberTrain pins (`cybertrain doctor` prints it), of
  the [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) fork,
  which carries the fixes CyberTrain needs ahead of an upstream release;
  untested against other versions. You do not install it by hand: the first
  command that needs it builds that release into `~/.cybertrain` (a few
  minutes, once), unless a `spinel` of that release is already on `PATH`.
- A C toolchain (`cc`, or the compiler `CC` names) and `make`, plus `git` and
  `curl`, to build Spinel, which compiles every program to C.
- SQLite 3, zlib and OpenSSL headers and libraries: `libsqlite3-dev`,
  `zlib1g-dev` and `libssl-dev` on Debian/Ubuntu. On macOS, SQLite and zlib
  come with Xcode's command line tools and OpenSSL from Homebrew
  (`brew install openssl@3`, then the two paths
  [Requirements](install.md#requirements) gives).

`cybertrain doctor` checks all of this and prints the install command for
whatever is missing. The full list and what is optional:
[Requirements](install.md#requirements); where Spinel goes and how to use
another install: [how Spinel is installed](install.md#how-spinel-is-installed).

> [!NOTE]
> No machine to install on? The [playground](site:playground.html) opens this
> blog in a GitHub Codespace with steps 02, 03, 04 and 07 already done.

<!-- step 01 #install stage: Setup · the `cybertrain` CLI -->
## Install the CLI

> [!WHY]
> `cybertrain` is the command that creates apps, scaffolds resources,
> migrates, serves and builds.

The first line installs it from RubyGems. The rest is the whole path at a
glance: the steps below take it one command at a time as far as
`cybertrain server`, and the [advanced tutorial](advanced-tutorial.md#ship)
ends with `cybertrain build`.

<figure class="code" data-lang="shell" markdown="0">
<figcaption><span class="code-path">terminal &mdash; any directory, then&nbsp;blog/</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="Code: terminal &mdash; any directory, then blog/"><code><span class="ln cmd">gem install cybertrain</span>
<span class="ln cmd">cybertrain new blog          <span class="c"># installs Spinel the first time (a few minutes)</span></span>
<span class="ln cmd">cd blog</span>
<span class="ln cmd">cybertrain g scaffold article title:string body:text</span>
<span class="ln cmd">cybertrain db migrate</span>
<span class="ln cmd">cybertrain server            <span class="c"># http://127.0.0.1:3000</span></span>
<span class="ln cmd">cybertrain build             <span class="c"># production: dist/blog, dist/public/, dist/storage/, dist/tmp/</span></span><span class="term-cursor" aria-hidden="true"></span></code></pre>
</figure>

[Every command](install.md#the-cybertrain-command), with its options, is listed
in the Installing guide.

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
release matching the CLI (X.Y.Z is what `cybertrain version` prints):

```toml spin.toml
[package]
name = "blog"
version = "0.1.0"

[dependencies]
cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }
```

Then it makes sure Spinel is installed (the first time, that means building
the pinned Spinel release into `~/.cybertrain`: a few minutes, once; see
[step 00](#requirements)) and runs `spin lock` (spin fetches the framework
into its cache, `~/.cache/spin/packages/`, and pins the commit in `spin.lock`)
and `SPIN_DEBUG=1 spin run gen` (gen built in spin's debug mode), much as
`rails new` runs `bundle install`, so
`cybertrain server` works right away. It ends by printing the next steps.
Nothing of the framework is copied into the app; commit `spin.toml` and
`spin.lock`.

> [!NOTE]
> If Spinel or one of the two `spin` steps fails, the files stay, `new` exits
> with 1 and prints what to run once the cause is fixed (for Spinel:
> `cybertrain setup`, then `cybertrain spin lock && SPIN_DEBUG=1 cybertrain
> spin run gen` in the new directory). `--skip-spin` only writes the files; `--path DIR`
> depends on a local checkout instead, `--git URL [--ref R]` on the framework
> at URL (at branch or tag R), and `--version V` on an index version once
> `cybertrain` is on a `spin-index`.

App names use lowercase letters, digits and `_`, starting with a letter. The
generated tree:

```text blog/
blog/
  spin.toml  config/app.rb  config/routes.rb  config/locales/en.yml  .env.example
  db/schema.rb  db/migrate/
  app/controllers/application_controller.rb  app/models/  app/views/  app/helpers/  app/jobs/
  app/assets/stylesheets/application.css  app/assets/images/
  app/javascript/application.js  config/importmap.rb
  public/  bin/blog.rb  bin/gen.rb  bin/db.rb
  gen/  storage/  tmp/  test/  .github/workflows/ci.yml
  Dockerfile  config/deploy.yml  .kamal/secrets
```

`bin/blog.rb` is the application's one entry point, the program
`spin build blog` compiles: `./blog` serves, `./blog migrate` and
`./blog db status` manage the database. `bin/gen.rb` runs the generator
(`spin run gen`), and `bin/db.rb` runs the migrator during development
(`cybertrain db migrate` uses it, since `bin/blog.rb` cannot compile until the
first migration has generated `gen/models/`). `gen/` already holds what
`spin run gen` wrote, `views.rb` among it: the committed, empty table of
embedded views.

Both `bin/blog.rb` and `bin/db.rb` start with `require "cybertrain/core"`:
the framework without its optional subsystems (jobs, Turbo Streams, the
mailer, the cache and the rest), which keeps every build shorter. The steps
of the advanced tutorial that use one add its line
([Subsystems](how-it-works.md#subsystems)).

The layout links `app/assets/stylesheets/application.css` with
`stylesheet_link_tag` and loads `app/javascript/application.js` through the
import map of `config/importmap.rb` with `javascript_importmap_tags`; `spin
run gen` writes both digested into `public/assets/`, which is git-ignored
(see [Assets](assets.md)). `.env.example` lists the variables the app reads,
`.github/workflows/ci.yml` runs the tests on GitHub
([Continuous integration](testing.md#continuous-integration)), and the last
line of the tree is the Kamal setup of
[step 19](advanced-tutorial.md#ship).

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

It writes a migration, a model, a controller, five views (`index`, `show`,
`new`, `edit`, `_form`), a fixture file and tests ([step 12](#test)), and inserts `resources :articles` into
`config/routes.rb`. Field types are `string`, `text`, `integer`, `float`,
`boolean`, `date`, `datetime`, `references` and `attachment` (an uploaded
file, [step 18](advanced-tutorial.md#attachments)); the default is `string`. The quick start's
`cybertrain g scaffold` is the same command.

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
  # jobs_page "/admin/jobs", before_action: :require_admin
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
  validates :title, uniqueness: true
  validates :body, presence: true, length: { minimum: 10 }
end
```

`class Article` has no superclass written: the `Cybertrain::Model` superclass,
columns and finders come from `gen/models/article.rb`. A failed save reports
messages such as "Title can't be blank", "Title has already been taken" and
"Body is too short (minimum is 10 characters)". The other validators
(`format`, `inclusion`, `numericality`, ...) are in
[Validations](models.md#validations).

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

  def new_action   # the `new` action: the generated routes call new_action
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

> [!RULE] new_action
> ### `new_action`, not `new`
>
> The `new` action is written `new_action`: the generated routes call it by
> that name. The rename was made when Spinel was recorded as unable to compile
> an instance method named `new` beside `ArticlesController.new(ctx)`; reduced
> programs of that shape compile on the pinned release, and the name stays as
> the API. The route `GET /articles/new` still maps to it; you only rename the
> method. The view is still `new.html.erb` and `render :new` is unchanged.

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
cybertrain db migrate    # spin run gen; spin run db -- migrate; spin run gen (gen and db in debug mode)
cybertrain server        # http://127.0.0.1:3000; Ruby edits show at once (CRuby), then compiled; views need neither
```

`spin run gen` reads `db/schema.rb` and `config/routes.rb`, scans `app/` and
writes `gen/`; `spin run db -- migrate` applies `db/migrate/*.rb` and rewrites
`db/schema.rb`. The order matters: the first `spin run gen` puts the new
migration into `gen/migrations.rb`, which `bin/db.rb` requires, and the second
builds the models from the rewritten `db/schema.rb`.

`cybertrain server` serves the app from CRuby within a second and builds it
with Spinel in the background. The first build compiles the whole app, which
takes a couple of minutes; until it is done the CRuby preview answers, and
every page says so in its bottom right corner:

```text output — cybertrain server
=> Booting cybertrain X.Y.Z
=> preview: CRuby 3.3.6
* Listening on http://127.0.0.1:3000
=> spinel: building (log: tmp/rebuild.log)
=> preview: CRuby (0.5s)
```

When the build is done the server prints `=> spinel: ready in …s; serving
the compiled binary`, and the compiled binary answers from then on. After a
Ruby edit it prints `Changed` and the file, answers from CRuby again at once
and builds again ([The development loop](how-it-works.md#the-development-loop)).
Ctrl-C stops it.

<!-- list: points -->
- Re-run `cybertrain spin run gen` and commit `gen/` after touching the
  schema, routes, a controller's or model's callbacks and ivars, a helper,
  component or job, or an asset. The development server does this for you,
  and `cybertrain spin run gen -- --check` lists what is stale without
  writing anything.
- Change the port with `cybertrain server 4000` (or `PORT=4000`).
- `cybertrain db` adds the `--` that `spin run db` needs before its arguments;
  `cybertrain db status` and the other database commands work the same way.

> [!RULE] Spinel rule: the console is not Ruby
> ### The console is not Ruby
>
> `rails console` has no exact counterpart: Spinel has no `eval`.
> `cybertrain spin run blog -- console` (`./blog console` once built)
> evaluates template expressions over the models, such as
> `Article.where(title: "x").count`, and `dbconsole` opens `sqlite3`
> ([The console](background-and-operations.md#the-console)). Ruby changes need a
> rebuild: in development `cybertrain server` answers them at once from a CRuby
> preview and hands the port to the compiled binary when its build finishes. In
> development views are parsed from disk per request, so editing one needs no
> rebuild; `cybertrain build` embeds them for production.

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
enough for `Article`/`Comment` to get their association: `spin run gen` reads
`Article#comments` and `Comment#article` off the foreign key. The resulting
schema:

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

> [!NOTE]
> A `cybertrain server` left running picks the scaffold's files up as soon as
> they are written, before the table exists. The new `Comment` model gets its
> columns from `gen/models/comment.rb`, which gen writes only once the table
> is in `db/schema.rb`, so the CRuby preview cannot load it (a
> `NoMethodError`): the server answers with its own 503 page naming the
> error, and the Spinel build fails too. Once `cybertrain db migrate` has
> rewritten `db/schema.rb`, the server serves again.

> [!EXAMPLE] Deleting an article with comments
> ### Deleting an article with comments
>
> The foreign key refuses to delete an article that still has comments.
> Declare the association, as in Rails, and `destroy` removes them first, in
> its transaction:
>
> ```ruby app/models/article.rb (excerpt)
>   # each comment's own destroy runs, callbacks included
>   has_many :comments, dependent: :destroy
> ```

<!-- step 09 #nested-routes stage: You write · `config/routes.rb` -->
## Nest the routes

> [!WHY]
> Rails' guide nests comments under articles.

```ruby config/routes.rb
Cybertrain::Routes.draw do
  root "articles#index"

  # A nested block takes the mapper as its argument: `articles.resources`,
  # not Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
  # jobs_page "/admin/jobs", before_action: :require_admin
end
```

> [!RULE] Explicit mapper
> ### Nested blocks take the mapper explicitly
>
> Write `resources :articles do |articles|` and `articles.resources :comments`,
> not a bare `resources :comments`. The form was introduced when Spinel was
> recorded as unable to compile a receiverless call in a block nested inside
> `instance_eval`; a reduced program of that shape compiles on the pinned
> release, and the explicit mapper stays the documented form, the one the
> generators and the tests write.

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
    @comment = @article.comments.find(params[:id])
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

The scaffold wrote the comment model with `belongs_to :article` and a
presence check on `commenter`, its first string field; add one for the body:

```ruby app/models/comment.rb
class Comment
  belongs_to :article
  validates :commenter, presence: true
  validates :body, presence: true
end
```

The `belongs_to` the scaffold declared also makes a comment without an article invalid
("Article can't be blank"), before the database would refuse it.

> [!NOTE]
> `Article#comments` is the comments' relation, so Rails'
> `@article.comments.find(params[:id])` works as written in `destroy`, and
> a comment under the wrong article returns 404.

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

Then render the comments and the form at the end of the article page, and
replace the scaffold's comment form:

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<h2>Comments</h2>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>

<h2>Add a comment:</h2>
<%= render "comments/form", comment: @comment %>

<%# app/views/comments/_form.html.erb %>
<%# locals: (comment:) %>
<%= form_with(model: [@article, comment]) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit %>
<% end %>
```

The comment partial:

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

### Where the form and the button point

Both `button_to ... [@article, comment]` and
`form_with(model: [@article, comment])` resolve through the same
`[parent, child]` rule: a new child routes to the nested collection
(`article_comments_path`), a persisted one to the nested member
(`article_comment_path`), both generated into `gen/routes.rb` from the nested
`resources` block above. The form takes its comment as a local, so that
[step 14](advanced-tutorial.md#turbo) can render it again with a fresh one.

> [!RULE] Views are a closed grammar
> ### Views are a closed grammar, not Ruby
>
> Spinel has no `eval`, so templates are interpreted against a fixed grammar.
> `link_to` has no `method:` option; use `button_to`. `each` takes one or two
> block parameters. A strict-locals comment such as `<%# locals: (comment:) %>`
> takes no default values. A partial gets a copy of the caller's environment, so
> `@article` is visible in `comments/_form`.

> [!EXAMPLE] The index with comment counts and a date filter
> ### The index with comment counts and a date filter
>
> examples/blog lists the newest articles first with their comment counts,
> in two queries however many articles there are, and filters them by date:
>
> ```ruby app/models/article.rb (excerpt) · app/controllers/articles_controller.rb (excerpt)
>   scope :recent, -> { order(created_at: :desc) }
>
>   def index
>     articles = Article.recent.includes(:comments)
>     from = Cybertrain::Cast.date_or_nil(params[:from])   # nil unless YYYY-MM-DD
>     unless from.nil?
>       articles = articles.where_between(:created_at, Time.utc(from.year, from.month, from.day), nil)
>     end
>     @articles = articles.to_a
>   end
> ```
>
> In the view, `article.comments.size` answers from the preloaded comments.
> Rails' `where(created_at: from..)` is `where_between` here, because Spinel
> builds no Range of Times ([Conditions and finders](models.md#conditions-and-finders)).

<!-- step 12 #test stage: Build time · `cybertrain test` -->
## Test it

> [!WHY]
> minitest and RSpec find tests by reflection, which an ahead-of-time compiler
> cannot do. The tests are Rails' classes all the same: `spin run gen`
> rewrites them into one program, which `cybertrain test` compiles and runs.

### What the generators wrote

The scaffolds of steps 03 and 08 wrote Rails' scaffold tests:
`test/fixtures/articles.yml` and `comments.yml` (the rows `one` and `two`
every test starts with), `test/models/article_test.rb` and
`comment_test.rb` ("the fixture is valid"), and
`test/controllers/articles_controller_test.rb` and
`comments_controller_test.rb` (one request per action), and `cybertrain
new` wrote `test/test_helper.rb`, which each file requires, and
`test/integration/health_test.rb`, a request to `/up`. Three of them need
the blog as it has grown since: the articles fixture and the two controller
tests.

### Fixtures that pass the validations

The scaffold's sample values (`MyString`, `MyText`) fail [step 05](#validations)'s
checks: two articles with one title, and bodies under ten characters. Give
the articles real ones:

```yaml test/fixtures/articles.yml
one:
  title: Hello Rails
  body: I am on Rails! This is my first article.

two:
  title: Second article
  body: Another article, with no comments.
```

The create test posts the fixture's own title, which is now taken; give it
a new one:

```ruby test/controllers/articles_controller_test.rb (excerpt)
  test "should create article" do
    assert_difference(-> { Article.count }, 1) do
      post articles_url, params: { article: { body: @article.body, title: "A new title" } }
    end

    assert_redirected_to article_url(Article.last)
  end
```

`comments.yml`'s rows belong to `article: one`. As in Rails, a fixture that
points at an article keeps the article from being deleted, so "should
destroy article" fails on the foreign key unless `Article` declares
`has_many :comments, dependent: :destroy` (the box at the end of
[step 08](#scaffold-comment)). Add it to `app/models/article.rb` if you
have not, as examples/blog does:

```ruby app/models/article.rb (excerpt)
  has_many :comments, dependent: :destroy
```

### Comments under their article

The scaffold's comments test requests the routes [step 09](#nested-routes)
nested under articles, whose helpers are now `article_comments_path` and
`article_comment_path`. Replace it:

```ruby test/controllers/comments_controller_test.rb
require "test_helper"

class CommentsControllerTest < ActionDispatch::IntegrationTest
  test "a comment is added to its article" do
    article = articles(:one)
    assert_difference(-> { Comment.count }, 1) do
      post article_comments_path(article), params: { comment: { commenter: "Dave", body: "First!" } }
    end
    assert_redirected_to article_path(article)
  end

  test "a destroyed comment leaves its article" do
    comment = comments(:one)
    assert_difference(-> { Comment.count }, -1) do
      delete article_comment_path(comment.article_id, comment)
    end
    assert_redirected_to article_path(comment.article_id)
  end
end
```

Forgery protection is off in tests, as in Rails, so a `post` needs no
token. The other assertions are in [Testing an app](testing.md#assertions).

### Run the tests

```shell terminal — blog/
cybertrain test
cybertrain test test/controllers/comments_controller_test.rb
cybertrain test -n /comment/
```

The first run compiles every test into one program, which takes minutes
(examples/blog's tests, 149 of them when measured on 2026-11-13, took about
nine on a 4-vCPU cloud machine). A
run with nothing changed does not compile the test program again: it may
rebuild gen once (`build gen`, some seconds), and then starts in well
under a second. A file or `-n` picks which tests run, not what is
compiled: editing any test compiles the program again. Each file prints a
heading, each test a line (`ok`, or `FAIL` and `ERR` with the test's line
and the message), then the totals, with whatever the code under test
prints itself (a command's output line, say) between them; the exit
status is 1 when one failed. At this step the blog has twelve tests.

> [!NOTE]
> Before each test every table is emptied and the fixtures inserted
> again, so tests do not depend on each other. `gen/tests.rb` and
> `gen/test/` are generated: commit them with the rest of `gen/`.

<!-- step → #where-next -->
## Where next

You have a blog with articles and comments, validated and tested, served by
`cybertrain server`. The advanced tutorial carries on from here with the same
app.

<!-- list: next-list -->
- [**Advanced tutorial**](advanced-tutorial.md) — Steps 13–19: a component and a helper, live comments with Turbo, a background job, JSON, sign-in, a cover image and a build for deployment.
- [**Things to know**](advanced-tutorial.md#things-to-know) — Limits and quirks worth knowing before they surprise you.
- [**`examples/blog`**](../../examples/blog) — The app the two tutorials grow into, with its tests.
- [**Guides**](index.md) — One page per topic: models, requests, templates, realtime, background work, testing.
- [**Models and the database**](models.md) — Migrations, queries, associations and every validator.
- [**Testing**](testing.md) — Fixtures, assertions and `cybertrain test` in full.
- [**API reference**](site:api/index.html) — Every class and method an app uses, with examples.
- [**CyberTrain on GitHub**](https://github.com/saeki-mototsune/CyberTrain) — The source, the README and releases.
- [**CyberTrain home**](site:index.html) — Overview, features and how it works.
