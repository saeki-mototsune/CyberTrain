---
path: tutorial.html
title: "Getting started: the blog"
description: "Build the Rails Getting Started blog, articles with comments, with CyberTrain: scaffold, migrate, nest routes, push live comments with Turbo, queue a job, test with Cybertrain::Test and build for deployment with cybertrain build."
og_title: "Getting started with CyberTrain: the blog"
og_description: "Mirrors Rails' own Getting Started: a blog with articles and comments, built with CyberTrain on Spinel."
og_image: tutorial.png
crumb: Tutorial
nav: tutorial
toc_title: "Steps 00–19"
meta:
  - term: You need
    text: 'Ruby 3.2+, `cc`, `make`, `git`, `curl`, SQLite 3, zlib and OpenSSL headers (Spinel is installed for you) <a class="meta-link" href="#requirements">Step 00</a>'
  - term: You start from
    text: "`gem install cybertrain`"
  - term: You finish with
    text: "`dist/blog`"
---

# Getting started: the&nbsp;blog

Mirrors Rails' own [Getting Started](https://guides.rubyonrails.org/getting_started.html):
a blog with articles and comments. You will scaffold articles, add
validations, nest comments under them, push new comments to every open page
with Turbo, queue a background job, answer JSON, write tests that drive the
app in-process, add sign-in, attach an uploaded image, and build the app into
a deployable `dist/` folder. The app this grows into is
[`examples/blog`](../../examples/blog), exercised by CI on Linux and macOS.

<!-- step 00 #requirements stage: Setup · Ruby, `cc`, SQLite -->
## Requirements

> [!WHY]
> CyberTrain compiles through Spinel to C, so it needs a C toolchain and the
> SQLite headers; the `cybertrain` command is a gem, so it needs Ruby.

<!-- list: checklist -->
- Ruby 3.2+ and RubyGems, for the `cybertrain` command only; applications
  never run on CRuby. On Ruby 3.2, also `gem install prism`.
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

The first line installs it from RubyGems. The rest is the whole tutorial at a
glance; the steps below take it one command at a time.

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

The layout links `app/assets/stylesheets/application.css` with
`stylesheet_link_tag` and loads `app/javascript/application.js` through the
import map of `config/importmap.rb` with `javascript_importmap_tags`; `spin
run gen` writes both digested into `public/assets/`, which is git-ignored
(see [Assets](assets.md)). `.env.example` lists the variables the app reads,
`.github/workflows/ci.yml` runs the tests on GitHub
([Continuous integration](testing.md#continuous-integration)), and the last
line of the tree is the Kamal setup of [step 19](#ship).

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
`boolean`, `date`, `datetime`, `references` and `attachment` (an uploaded
file, [step 18](#attachments)); the default is `string`. The quick start's
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
=> Booting cybertrain X.Y.Z
=> development environment (1 worker)
=> Watching app/, config/ and db/schema.rb for changes
* Listening on http://127.0.0.1:3000
Use Ctrl-C to stop
```

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
> A `cybertrain server` left running rebuilds as soon as the scaffold writes
> its files, before the table exists, and logs `Build failed; still serving
> the previous build (see tmp/rebuild.log)`. It rebuilds again once
> `cybertrain db migrate` has rewritten `db/schema.rb`.

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

Then add validations to the comment model:

```ruby app/models/comment.rb
class Comment
  validates :commenter, presence: true
  validates :body, presence: true

  belongs_to :article
end
```

The declared `belongs_to` also makes a comment without an article invalid
("Article can't be blank"), before the database would refuse it.

> [!NOTE]
> `Article#comments` is the comments' relation, so Rails'
> `@article.comments.find(params[:id])` works as written in `destroy`, and
> a comment under the wrong article returns 404.

<!-- step 11 #views stage: Run time · `app/views/`, read from disk in development, embedded by `cybertrain build` -->
## Views and partials

> [!WHY]
> The article page lists its comments and ends with a form that posts to the
> nested route.

First, delete the now-unreachable `index`, `show`, `new` and `edit` comment
views. Then render the comments and the form at the end of the article page,
and replace the scaffold's comment form:

```erb app/views/articles/show.html.erb · app/views/comments/_form.html.erb
<%# app/views/articles/show.html.erb %>
<h2>Comments</h2>
<% @article.comments.each do |comment| %>
  <%= render "comments/comment", comment: comment %>
<% end %>

<h2>Add a comment:</h2>
<%= render "comments/form" %>

<%# app/views/comments/_form.html.erb %>
<%= form_with(url: article_comments_path(@article), scope: :comment) do |f| %>
  <%= f.label :commenter %> <%= f.text_field :commenter %>
  <%= f.label :body %> <%= f.text_area :body %>
  <%= f.submit "Create Comment" %>
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

The form names its target with `url:` and its fields (`comment[commenter]`,
`comment[body]`) with `scope:`, so it needs no `Comment` record: a comment
that does not save is redirected back with the reason in the flash
([step 10](#comments-controller)), and the form is never rendered again with
its errors.

`button_to ... [@article, comment]` resolves through the `[parent, child]`
rule: a new child routes to the nested collection (`article_comments_path`), a
persisted one to the nested member (`article_comment_path`), both generated
into `gen/routes.rb` from the nested `resources` block above.
`form_with(model: [@article, @comment])` follows the same rule, and
`examples/blog` writes the form that way, with `@comment = Comment.new` in
`ArticlesController#show`. This tutorial leaves `show` as the scaffold wrote
it, empty, because the generator of [step 18](#attachments) asks for that.

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

<!-- step 12 #component stage: You write · `app/components/`, `app/helpers/` -->
## A component and a helper

> [!WHY]
> From the next step on a comment is rendered in two places: on the page, and
> in a broadcast that no request is behind. A component, a class with its
> template beside it, renders the same in both; a helper is a method every
> template can call.

```shell terminal — blog/
cybertrain generate component comment comment   # the name, then its attributes: one, also called comment
cybertrain generate helper comments
```

The first writes `app/components/comment_component.rb`, with one keyword per
attribute, and its template; the second writes an empty `CommentsHelper`.
Each also writes a test, which [step 16](#test) comes back to. The class is
already what the blog needs:

```ruby app/components/comment_component.rb
class CommentComponent < Cybertrain::Component
  def initialize(comment:)
    @comment = comment
  end
end
```

Replace the generated template with the comment's markup, and give the helper
its one method:

```erb app/components/comment_component.html.erb
<div class="comment" id="<%= dom_id(comment) %>">
  <p><%= comment_author(comment) %> wrote:</p>

  <p><%= comment.body %></p>

  <%= button_to "Destroy comment", article_comment_path(comment.article_id, comment), method: :delete %>
</div>
```

```ruby app/helpers/comments_helper.rb
module CommentsHelper
  # The commenter's name in a <strong>, escaped: <%= comment_author(c) %>
  def comment_author(comment)
    name = case comment
           when Comment then comment.commenter.to_s
           else ""
           end
    Cybertrain::Html.tag("strong", { class: "comment-author" }, name)
  end
end
```

Then render the component where the page rendered the partial, and delete
`app/views/comments/_comment.html.erb`:

```erb app/views/articles/show.html.erb (excerpt)
<% @article.comments.each do |comment| %>
  <%= render component: "comment", comment: comment %>
<% end %>
```

<!-- list: points -->
- The template sees the component's instance variables as locals (`comment`)
  and its public methods without parameters by name. It is given the comment
  only, not the page's `@article`, so the button's path is built from
  `comment.article_id`.
- `dom_id(comment)` is `comment_7` for the comment with id 7: the element id
  the next step's broadcasts aim at.
- A component is named as a partial is, by its snake-case name without
  `_component`: templates cannot name constants.
- `Cybertrain::Html.tag` escapes its content and returns a `SafeString`, which
  a template prints as it is; a plain `String` a helper returns is escaped.

> [!RULE] Spinel rule: helpers and components are generated dispatch
> ### Helpers and components are generated dispatch
>
> Templates cannot `send`, so `spin run gen` reads `app/helpers/` and
> `app/components/` as text and writes the dispatch into `gen/helpers.rb` and
> `gen/components.rb`. A helper's parameters are named (no `*rest`, no
> `**opts`), and its arguments arrive as the template's values, which is why
> `comment_author` narrows its argument with `case ... when Comment`. The rest
> is in [Application helpers](template-language.md#application-helpers) and
> [Components](template-language.md#components).

<!-- step 13 #turbo stage: Run time · Turbo Streams over Server-Sent Events -->
## Live comments with Turbo

> [!WHY]
> A comment posted in one browser should appear on every open page of that
> article without a reload. As in a Rails 8 app, that is Turbo Streams, and
> there is nothing to install or to start beside the server.

### Load Turbo

`cybertrain new` left both lines commented out; uncomment them:

```ruby config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
```

```javascript app/javascript/application.js
import "@hotwired/turbo"
```

The layout's `javascript_importmap_tags` writes the import map and
`import "application"`, so every page now runs Turbo
([The import map](assets.md#the-import-map)).

### Subscribe the page

Give the list and the form an id each, and subscribe the page to the
article's stream:

```erb app/views/articles/show.html.erb (excerpt)
<h2>Comments</h2>

<%= turbo_stream_from @article %>

<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render component: "comment", comment: comment %>
  <% end %>
</div>

<h2>Add a comment:</h2>

<div id="comment_form">
  <%= render "comments/form" %>
</div>
```

### Broadcast and answer

`create` broadcasts the saved comment, then answers the browser that posted
it; `destroy` tells the other pages to drop the element:

```ruby app/controllers/comments_controller.rb (excerpt)
  def create
    @comment = Comment.new(comment_params)
    @comment.article_id = @article.id
    unless @comment.save
      flash[:alert] = "Comment could not be saved: #{@comment.errors.full_messages.join(", ")}"
      redirect_to article_path(@article), status: :see_other
      return
    end

    # Every page subscribed with turbo_stream_from @article appends the comment.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
    respond_to do |format|
      format.turbo_stream   # app/views/comments/create.turbo_stream.erb
      format.html do
        flash[:notice] = "Comment was successfully created."
        redirect_to article_path(@article), status: :see_other
      end
    end
  end

  def destroy
    @comment = @article.comments.find(params[:id])
    target = Cybertrain::Html.dom_id(@comment)   # read before destroy clears the id
    @comment.destroy
    Cybertrain::Stream.broadcast_remove_to(@article, target: target)
    flash[:notice] = "Comment was successfully destroyed."
    redirect_to article_path(@article), status: :see_other
  end
```

```erb app/views/comments/create.turbo_stream.erb
<%= turbo_stream.append "comments", html: render(component: "comment", comment: @comment) %>
<%= turbo_stream.update "comment_form", partial: "comments/form" %>
```

Open one article in two windows and post a comment in one: it appears in
both, and the form that sent it comes back empty.

### What happens

<!-- list: points -->
- `turbo_stream_from @article` writes a `<turbo-stream-source>` element for
  the stream `articles:<id>`, with a signed token. Turbo opens it as an
  `EventSource` on `/cybertrain/stream`, which the server already serves.
- A broadcast is a row in `cybertrain_messages`, a table the framework creates
  itself. Each server process polls it and hands the row to the pages it
  holds, within about a tenth of a second.
- Turbo submits the form asking for a Turbo Stream, so `format.turbo_stream`
  renders `create.turbo_stream.erb`, without a layout. A plain form post, with
  JavaScript off, takes `format.html` and is redirected as before.
- The window that posted gets the comment twice, in the answer and in the
  broadcast, and shows it once: Turbo replaces an element that has the same
  id.

More, including WebSocket and streams for your own JavaScript:
[Realtime](realtime.md#turbo-streams).

> [!NOTE]
> Turbo is fetched from jsDelivr here. To serve it yourself, copy
> `turbo.es2017-esm.js` into `vendor/javascript/` and pin it with
> `to: "turbo.es2017-esm.js"`. If you turn on the Content Security Policy
> `config/app.rb` has commented out, its `script_src` must allow whichever
> origin serves Turbo
> ([Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts)).

<!-- step 14 #job stage: You write · `app/jobs/` -->
## A background job

> [!WHY]
> Work that should not hold up the response, such as a notification, runs
> after it. As with Active Job on Solid Queue, a job is a class in
> `app/jobs/` and a row in the application's own database: no other service.

```shell terminal — blog/
cybertrain generate job notify_comment --retry StandardError:30:3
```

It writes `app/jobs/notify_comment_job.rb`, with the `retry_on` line the
option asked for and an empty `perform`, and a test. Fill `perform` in; this
one only logs, where a real application would send a mail:

```ruby app/jobs/notify_comment_job.rb
class NotifyCommentJob < Cybertrain::Job::Base
  retry_on StandardError, wait: 30, attempts: 3

  def perform(args)
    comment_id = Cybertrain::Cast.int(args["comment_id"])
    article_id = Cybertrain::Cast.int(args["article_id"])
    Cybertrain.logger.info("new comment #{comment_id} on article #{article_id}")
    nil
  end
end
```

Queue it from `create`, once the comment is saved:

```ruby app/controllers/comments_controller.rb (excerpt)
    NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id" => @article.id)
    # Every page subscribed with turbo_stream_from @article appends the comment.
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           component: CommentComponent.new(comment: @comment))
```

Post a comment, and the server's log shows the job running after the
response:

```text output — cybertrain server
[INFO] Started POST "/articles/1/comments" for 127.0.0.1
[INFO] Completed 200 in 2ms
[INFO] new comment 1 on article 1
[INFO] job 1 (NotifyCommentJob) done
```

<!-- list: points -->
- `args` is the Hash given to `perform_later`, stored as JSON and read back
  with String keys: pass ids, not records, and narrow the values with
  `Cybertrain::Cast`. `perform_in(seconds, args)` and `perform_at(time, args)`
  queue it for later.
- Jobs are rows of `cybertrain_jobs`, run by three job threads of the serving
  process, or of a separate one started with `./blog worker`
  ([Process roles](background-and-operations.md#process-roles)).
- `retry_on StandardError, wait: 30, attempts: 3` queues a failed run again
  30 seconds later, three attempts in all; the row is then `failed` and kept
  ([Retries and discards](background-and-operations.md#retries-and-discards)).
- A job can run more than once (a process that dies in the middle of one has
  it run again), so write `perform` to be safe to repeat.
- Failed jobs are listed, retried and discarded with `./blog jobs`, or on the
  page the commented `jobs_page` line in `config/routes.rb` mounts
  ([The jobs page](background-and-operations.md#the-jobs-page-and-the-jobs-command)).

> [!RULE] Spinel rule: job policies are read as text
> ### Job policies are read as text
>
> `spin run gen` reads each class under `app/jobs/` and writes its other half
> into `gen/jobs.rb`: `perform_later`, and each `retry_on` as a `rescue` arm.
> So `retry_on`, `discard_on` and `limits_concurrency` take one line each with
> literal values: `wait: 30`, not `wait: 30.seconds` or a lambda.

> [!EXAMPLE] Deleting finished jobs every night
> ### Deleting finished jobs every night
>
> Every comment leaves a `done` row behind. `config/app.rb` ends with a
> scheduled task, commented out, that deletes the ones a week old; uncomment
> it:
>
> ```ruby config/app.rb (excerpt)
> Cybertrain::Scheduler.cron("0 4 * * *", "prune done jobs") do
>   Cybertrain::Job.prune_done(Time.now.to_i - 7 * 86_400)
> end
> ```
>
> The cron expression is read in `CYBERTRAIN_SCHEDULER_TZ` (UTC by default),
> and one process at a time runs the schedule
> ([Scheduled tasks](background-and-operations.md#scheduled-tasks)).

<!-- step 15 #json stage: You write · `app/controllers/` -->
## Answer JSON

> [!WHY]
> One action can serve the page and an API: `respond_to`, as in Rails.

```ruby app/controllers/articles_controller.rb (excerpt)
  def index
    @articles = Article.all.to_a
    respond_to do |format|
      format.html
      format.json { render json: @articles.map(&:as_json) }
    end
  end
```

```console terminal — blog/
$ curl http://127.0.0.1:3000/articles.json
[{"id":1,"title":"Hello Rails","body":"I am on Rails! This is my first article.","created_at":"2026-11-12T10:22:45.852Z","updated_at":"2026-11-12T10:22:45.852Z"}]
```

<!-- list: points -->
- The format comes from the extension (`/articles.json`) or, without one,
  from the `Accept` header. A format the action does not list, such as
  `/articles.xml`, is answered `406 Not Acceptable`.
- `format.html` without a block renders the action's template, as before.
- `as_json` is the record's columns, times in ISO 8601, UTC. JSON has no
  templates: an action answers it with `render json:`.
- Keep the block to its `format.` lines: when a request falls back to html
  the block runs a second time.

`show` takes the same block, with `render json: @article.as_json`, and
`examples/blog` has it. Add it after [step 18](#attachments), whose generator
wants `show` empty when it runs. Everything about formats:
[Formats and `respond_to`](requests.md#formats-and-respond_to).

<!-- step 16 #test stage: Build time · `cybertrain spin test` -->
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
`assert_includes`, `assert_raises("Class") { }`, `flunk`. The client adds
`assert_response` and `assert_redirected_to`.

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

### The job, the Turbo Stream and the component

The test client starts no job thread, so a queued job stays queued until the
test runs it. A third argument to `post` sets request headers, here the
`Accept` Turbo sends with a form:

```ruby test/comments.rb (snippet)
require_relative "support/blog_test"   # also loads cybertrain/test/jobs

def post_comment(client, article, headers = {})
  client.get(BlogTest.article_path(article))
  client.post("#{BlogTest.article_path(article)}/comments",
              { "authenticity_token" => BlogTest.form_token(client),
                "comment[commenter]" => "Dave", "comment[body]" => "First!" }, headers)
end

test "a comment queues its notification" do
  BlogTest.reset
  post_comment(Cybertrain::Test::Client.new(BLOG), BlogTest.article)
  assert_enqueued_with "NotifyCommentJob", { "comment_id" => Comment.last.id }
  assert_equal 1, perform_enqueued_jobs
  assert_no_enqueued_jobs
end

test "a form Turbo submits is answered with a Turbo Stream" do
  BlogTest.reset
  res = post_comment(Cybertrain::Test::Client.new(BLOG), BlogTest.article,
                     { "accept" => "text/vnd.turbo-stream.html, text/html" })
  assert_response res, :ok
  assert_includes res.body, "<turbo-stream action=\"append\" target=\"comments\">"
end
```

[Step 12](#component) wrote `test/comment_component.rb`, which renders the
component with a String where the template now expects a comment. Replace its
content:

```ruby test/comment_component.rb
require_relative "support/blog_test"
require "cybertrain/test/views"   # Cybertrain::Test.render_component

test "the comment component names its author" do
  BlogTest.reset
  comment = BlogTest.comment(BlogTest.article, "Alice", "Great post!")
  html = Cybertrain::Test.render_component(CommentComponent.new(comment: comment))
  assert_includes html, "<strong class=\"comment-author\">Alice</strong> wrote:"
end

Cybertrain::Test.run!
```

`render_component` renders as a broadcast does, with no request. The other
helpers, and how to read a stream in a test:
[Testing jobs](testing.md#testing-jobs) and
[Testing streams and components](testing.md#testing-streams-and-components).

> [!COMPILE] What the snippets leave out
> ### What the snippets leave out
>
> - `support/blog_test` is
>   [`examples/blog/test/support/blog_test.rb`](../../examples/blog/test/support/blog_test.rb):
>   copy it into your app&rsquo;s `test/support/`, where files are required, not
>   run. It migrates a fresh `storage/test.sqlite3`, boots the app as `BLOG`,
>   loads `Cybertrain::Test`, its client and the job helpers, and gives you
>   `BlogTest.form_token` (the CSRF token of the last rendered form),
>   `BlogTest.article_path`, `BlogTest.article` and `BlogTest.comment` (a saved
>   record each) and `BlogTest.reset` (empty tables, cache and job queue).
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
Files in `test/support/` are required, not run. The tests the generators
wrote in steps 12 and 14 (`test/comments_helper.rb`,
`test/notify_comment_job.rb`) run with the rest. To write a snapshot:

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

<!-- step 17 #authentication stage: You write · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
## Add sign-in

> [!WHY]
> So far anyone can edit or delete an article. Like Rails 8&rsquo;s
> `bin/rails generate authentication`, one command adds email-and-password
> sign-in, written as code the app owns rather than installed as an engine.

```shell terminal — blog/
cybertrain generate authentication
cybertrain db migrate    # creates the users and sessions tables
```

It writes the `users` and `sessions` migrations and models, the
`Authentication` concern, which it includes into `ApplicationController`,
controllers and views for signing in, signing up, resetting a password and
the account page, a mailer, the `./blog user` command, and tests. It also
adds the routes, a `sessions/_nav` partial at the top of the layout, and a
`base_url` setting in `config/app.rb`, where links in mails start. Every
file is listed in [Authentication](authentication.md#generating-it).

```ruby app/controllers/concerns/authentication.rb (excerpt)
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :resume_session          # sets @current_user and @current_session
    before_action :require_authentication  # 303 to /session/new unless signed in
    helper_method :authenticated?
  end
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

  <div id="comment_form">
    <%= render "comments/form" %>
  </div>
<% end %>
```

The comment component keeps its "Destroy comment" button for everyone: a
broadcast renders it once for all viewers, with no request and so no current
user. A visitor who clicks it is sent to the sign-in page, since
`CommentsController` opens no action; new comments still reach a visitor's
page, because the stream is not an action of a controller.

Start the server and open `http://127.0.0.1:3000/sign_up` to create the first
user. Rails&rsquo; generator has no sign-up page and leaves that to the
console; CyberTrain writes `RegistrationsController`, so the first user signs
up in the browser. For an invitation-only app, run the generator with
`--invite-only` instead: there is no sign-up page, and the first user comes
from `./blog user EMAIL` or from a `/setup` page only the server's own
machine can open
([Sign-up, or invite-only](authentication.md#sign-up-or-invite-only)).

The sign-in page also links to a password reset by mail, and the nav to an
account page; the [Authentication](authentication.md) guide covers them,
with lockout, "keep me signed in", `--confirmable` and admin users. A reset
mail needs the SMTP settings and, in production, `BLOG_BASE_URL`
([Links in mails](authentication.md#links-in-mails)).

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

### Update the tests

Any [step 16](#test) test that expects a form, submits one, or reaches an
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
> Run `cybertrain spin test` as in [step 16](#test); `test/authentication.rb`,
> the other tests the generator wrote and this one use SQLite, so their
> snapshots come from the compiled binaries. Sign-in attempts are rate
> limited as in Rails' generator, ten per client address every three
> minutes, counted in the application's database so that every process
> counts together; behind a reverse proxy, configure
> [trusted proxies](requests.md#rate-limiting-and-the-client-address).
> `examples/blog` takes this step with `--invite-only` and makes its
> `/admin` pages admin-only.

<!-- step 18 #attachments stage: You write · `app/`, `db/migrate/`, `config/routes.rb`, `test/` -->
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
  allow_unauthenticated_access only: [:index, :show, :cover]   # step 17 wrote [:index, :show]; the generator added :cover
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

Step 17 made every page private, and the image on a public article page is
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

> [!NOTE]
> The generator copies the access rules of `show` to the download, and only
> when it can read them: `show` must be the scaffold's empty action behind
> `before_action :set_article`. With code inside `def show`, or a
> second `before_action` that lists `:show` without the new action, it stops with
> `cannot preserve show's authorization for :cover` and writes nothing. That
> is why `show` stayed empty until now. From here on it can grow (the JSON
> answer of [step 15](#json), a `@comment` for the form); keeping `cover` as
> restricted as `show` is then yours to do.

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
> Run `cybertrain spin test` as in [step 16](#test); the test uses SQLite, so
> its snapshot comes from the compiled binary. `examples/blog` stops before
> this step. Not built yet: several files per field, S3 or other remote
> storage, image variants, and streaming large bodies to disk (the whole body
> is read into memory, up to `max_body_bytes`).

<!-- step 19 #ship stage: Run time · `dist/blog` -->
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
(`CYBERTRAIN_ENV` overrides). Set `CYBERTRAIN_SECRET_KEY_BASE`
(`cybertrain secret` prints one too); for illustration:

```shell terminal — production host
cd dist
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"
./blog migrate && ./blog
```

`./blog migrate` applies the migrations compiled into the binary, and
`./blog db status` shows their status; `PORT` sets the port. Keep the secret
the same across restarts: changing it ends every session. `./blog help` lists
the binary's other commands, among them `worker`, `jobs`, `console` and
`db backup`.

`Cybertrain::Config` reads the environment first; `config/app.rb` overrides.
The variables a first deploy meets (all of them:
[Configuration](configuration.md#configuration-and-environment-variables)):

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
  is plain http). Behind such a proxy, `CYBERTRAIN_FORCE_SSL=1` redirects http
  to https and `CYBERTRAIN_HOSTS` names the hosts the app answers to
  ([hosts and `force_ssl`](requests.md#content-security-policy-force_ssl-and-hosts)).
- The serving process also runs the jobs, the scheduled tasks and the stream
  poller of steps 13 and 14: one process is a whole deployment. `./blog
  worker` moves the jobs into a process of their own
  ([Process roles](background-and-operations.md#process-roles)).
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
for every release, checks the health check, an article created through the form,
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
- Sessions hold Strings only, in an encrypted cookie.
- SQLite only, through Spinel&rsquo;s FFI.
- No backtraces: errors show class, message, request line and template
  name/line.
- A misspelled attribute in a view raises (`undefined method 'titel' for
  Article`); a column that holds `nil` renders empty.
- Associations come from foreign keys or one-line declarations; no
  `has_many :through`, nested `includes`, enums, STI or polymorphic
  associations.
- No `constraints` or `mount`; JSON is answered with `render json:` (there
  are no JSON templates).
- Only the first string field gets a default presence validation in a
  scaffolded model.
- The generator uses a lexical scan (regexes), not a parser, over
  `app/controllers`, `app/models`, `app/helpers`, `app/components` and
  `app/jobs`.
- Jobs run at least once, and a broadcast reaches only the pages open when it
  is sent, or reconnecting within a minute.
- Views are embedded at build time: a view-only change needs
  `cybertrain build` and a restart before it reaches production.
- Build `dist/` on the same OS and CPU as the machine that runs it: the binary
  links the system SQLite.
- `SPINEL_WORKERS` defaults to `1`.
- Only the pinned Spinel release (`Cybertrain::SPINEL_TAG`) is tested.
- More differences from Rails, in one table: [Differences from Rails](how-it-works.md#differences-from-rails).

<!-- step → #where-next -->
## Where next

<!-- list: next-list -->
- [**`examples/blog`**](../../examples/blog) — The app this tutorial grows into, with its tests.
- [**Authentication**](authentication.md) — Password reset, confirmation, lockout, remember me, the account page and admin users.
- [**Internationalization**](i18n.md) — Dictionaries, `t` and `l`, and a locale per request.
- [**Guides**](index.md) — One page per topic: models, requests, templates, realtime, background work, testing.
- [**CyberTrain on GitHub**](https://github.com/saeki-mototsune/CyberTrain) — The source, the README and releases.
- [**API reference**](site:api/index.html) — Every class and method an app uses, with examples.
- [**`spikes/NOTES.md`**](../../spikes/NOTES.md) — Spikes and the compiler constraints they found.
- [**Spinel**](https://github.com/matz/spinel) — matz's ahead-of-time Ruby compiler.
- [**CyberTrain home**](site:index.html) — Overview, features and how it works.
