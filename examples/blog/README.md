# Blog

The cybertrain acceptance app: the blog from the Rails Guides' "Getting
Started" (articles with comments), compiled to one binary by Spinel.

It was made with the CLI and then edited the way the guide edits it:

```sh
cybertrain new blog
cybertrain generate scaffold article title:string body:text
cybertrain generate scaffold comment commenter:string body:text article:references
```

- `config/routes.rb`: `root "articles#index"` and comments nested under
  articles (`only: [:create, :destroy]`); the standalone comment pages the
  scaffold wrote are gone.
- `Article` validates the title and a body of at least 10 characters, and
  deletes its comments before it is destroyed. `Article#comments` and
  `Comment#article` are generated from the `comments.article_id` foreign key.
- `articles/show.html.erb` lists the comments inside `<div id="comments">`
  and ends with the comment form (`comments/_form`, which takes the
  comment as a local, `form_with(model: [@article, comment])`, inside
  `<div id="comment_form">`).

The comment list is live. Each comment is a component,
`app/components/comment_component.rb` with its template beside it
(`<%= render component: "comment", comment: c %>`; its `id` is
`dom_id(comment)`), and shows its author through an application helper,
`comment_author` in `app/helpers/comments_helper.rb`, which builds a
`<strong>` with `Cybertrain::Html.tag`. The article page subscribes with
`<%= turbo_stream_from @article %>` (Server-Sent Events on the stream
`articles:<id>`), and `CommentsController#create`, once the comment is
saved, calls `Cybertrain::Stream.broadcast_append_to(@article, target:
"comments", component: CommentComponent.new(comment: @comment))`: every
open page of that article appends the new comment without a reload (a tab
that already has it, the one that posted, keeps one copy, as Turbo replaces
an element with the same id). A comment posted from that form, which
Turbo submits asking for a Turbo Stream, is answered by
`app/views/comments/create.turbo_stream.erb` (`respond_to do |format|
format.turbo_stream; format.html { redirect_to ... } end` in
`CommentsController#create`): the comment appended to `#comments` and an
empty form put back in `#comment_form`, without a reload. A plain form
post, or a comment that does not save, is redirected to the article (303)
as before.

## Assets, Turbo and the Content Security Policy

- **The stylesheet** is `app/assets/stylesheets/application.css` (it was
  `public/style.css`). `spin run gen` digests it, as Propshaft does, into
  `public/assets/application-<8 hex>.css` (git-ignored, with the logo from
  `app/assets/images/logo.svg`), and rewrites its `url("logo.svg")` to the
  logo's digested path; a `url()` is read from the stylesheet's logical
  directory, the root of the asset paths, so the logo is `"logo.svg"`, not
  `"../images/logo.svg"`. The layout's `<%= stylesheet_link_tag
  "application" %>` names the current digest, and a digested file is
  served with `Cache-Control: public, max-age=31536000, immutable`.
  `config/deploy.yml` sets Kamal's `asset_path: /app/public/assets`, so a
  page loaded before a deploy still finds the stylesheet it names.
- **Turbo** comes through the import map: `config/importmap.rb` pins
  `"application"` (`app/javascript/application.js`, which does `import
  "@hotwired/turbo"`) and `"@hotwired/turbo"` to Turbo 8.0.12 on jsDelivr,
  and the layout's `<%= javascript_importmap_tags %>` writes the map,
  the `modulepreload` links and `import "application"`. Without Turbo the
  article page's `<turbo-stream-source>` does nothing. To serve Turbo
  yourself, copy `turbo.es2017-esm.js` into `vendor/javascript/` and pin
  it with `to: "turbo.es2017-esm.js"`.
- **A Content Security Policy** (`config/app.rb`): scripts from this
  origin and `https://cdn.jsdelivr.net`, styles and images from this
  origin (images also `data:`), with a fresh nonce per response in
  `script-src` and `style-src`. The import map's inline scripts carry it,
  and `<%= csp_meta_tag %>` puts it in `<meta name="csp-nonce">` for
  scripts that add elements.

## Formats

`ArticlesController#index` and `#show` answer HTML and JSON through
`respond_to`: `/articles.json` is the list (`render json:
@articles.map(&:as_json)`, the same order and date filter as the page),
`/articles/1.json` one article (`@article.as_json`; times in ISO 8601,
UTC), and a request whose `Accept` asks for `application/json` gets JSON
too. Another format (`/articles.xml`) is `406 Not Acceptable`. The index
also takes `?order=old` (a `select` beside the date filter; newest first
otherwise), and its counts go through `number_with_delimiter`
(`1,234 articles`); the article page dates the article with `time_tag`.

```sh
cybertrain db migrate  # spin run gen; spin run db -- migrate; spin run gen
cybertrain server      # http://127.0.0.1:3000 (`cybertrain server 4000`, or PORT=4000, to change it)
cybertrain build       # dist/blog (views embedded) + dist/public/
cybertrain spin test   # test/*.rb (the blog's and the generated authentication tests) against storage/test.sqlite3
```

Run `cybertrain spin run gen` after changing the schema, the routes or a
controller's instance variables and callbacks, a job class, a file under
`app/assets/` or `app/javascript/`, or `config/importmap.rb`, and commit `gen/`
(`cybertrain spin run gen -- --check` reports stale files). Views under
`app/views/` are read at run time: edit them without rebuilding. A
production binary (`cybertrain build`, or `CYBERTRAIN_ENV=production`)
renders only the views embedded at build time.

## Jobs, a scheduled task, a cache and the jobs page

- **A job class.** `app/jobs/notify_comment_job.rb` is a
  `Cybertrain::Job::Base` subclass; `CommentsController#create` calls
  `NotifyCommentJob.perform_later("comment_id" => @comment.id, "article_id"
  => @article.id)` once the comment is saved, and the process that runs jobs
  logs `new comment <id> on article <id>`. Its `retry_on StandardError, wait:
  30, attempts: 3` queues a failed run again 30 seconds later, three
  attempts in all. `spin run gen` writes the class's other half
  (`perform_later`, the retry as a `rescue` arm) into `gen/jobs.rb`.
- **A cron task.** Every comment leaves a `done` row in the jobs table, so
  `config/app.rb` registers `Cybertrain::Scheduler.cron("0 4 * * *", "prune
  done jobs")`: every day at 04:00 (`CYBERTRAIN_SCHEDULER_TZ`, UTC by default)
  it calls `Cybertrain::Job.prune_done` for the rows done more than 7 days
  ago. Failed and discarded rows stay for the jobs page (`./blog jobs prune`
  removes those).
- **A cache.** The index shows how many articles there are, from
  `Cybertrain::Cache.fetch_int("articles/count", expires_in: 60) {
  Article.count }`: a row in the `cybertrain_cache` table, so the count
  can lag a new article by up to a minute (the list itself does not).
- **The admin namespace** (`namespace :admin do |admin| ... end` in
  `config/routes.rb`) holds `/admin/articles`, the newest 20 articles
  (`AdminGate`'s `per_page`) with a delete button each
  (`Admin::ArticlesController` in `app/controllers/admin/`, views in
  `app/views/admin/articles/`, `admin_articles_path` and
  `admin_article_path(article)`), and the jobs page at `/admin/jobs`
  (`admin.jobs_page "/jobs", before_action: :require_admin,
  skip_before_action: :require_authentication`), which lists the jobs by
  state and retries, discards or deletes failed ones. Both are for admin
  users only (see [Users and the admin](#users-and-the-admin)).
  `Admin::ArticlesController` does `include AdminGate`, a concern in
  `app/controllers/concerns/admin_gate.rb` whose `included do` block
  declares `before_action :require_admin` (`spin run gen` splices it into
  the controller, `gen/concerns.rb`).

`test/comments.rb` checks the enqueue with `assert_enqueued_with` and runs
the job with `perform_enqueued_jobs` (`require "cybertrain/test/jobs"` in
`test/support/blog_test.rb`, which also empties the cache, the jobs
table and the users before each test); `test/articles.rb` covers the
cached count, the formats, the assets, the import map and the CSP nonce,
the admin namespace and who may see it, and the two languages.
[Background work](../../docs/guide/background-and-operations.md) in the
guide covers jobs and scheduled tasks in full.

## Users and the admin

The blog has a single author, so its accounts come from `cybertrain
generate authentication --invite-only`: no sign-up page, a sign-in page at
`/session/new` (a "Sign in" link in every page's header), a password reset
by mail (`/passwords/new`) and an account page (`/account/edit`). The
generator wrote the `Authentication` concern
(`app/controllers/concerns/authentication.rb`, included by
`ApplicationController`), the `User` and `Session` models, their
controllers and views (`app/views/sessions/`, `passwords/`, `accounts/`,
`setup/`), the user command (`app/commands/user_command.rb`) and the tests
`test/authentication.rb`, `admin.rb`, `remember_me.rb`, `lockout.rb`,
`passwords.rb` and `accounts.rb`.

- **Who may do what.** Anyone reads the articles and posts comments
  (`allow_unauthenticated_access only: [:index, :show]` in
  `ArticlesController`, `only: [:create]` in `CommentsController`); writing,
  editing and deleting articles, and deleting comments, need a signed-in
  user, and a visitor is sent to sign in first (then back to the page
  they asked for). The admin pages need a user who is an admin
  (`User#admin?`): the concern's `require_admin` answers anyone else 404,
  as if the pages did not exist. The jobs page names `require_admin` alone,
  so a visitor gets that 404 too; `/admin/articles` sends a visitor to sign
  in first. The article page shows a "Manage articles" link to an admin
  (`ApplicationController#admin?`, a helper method).
- **The first user.** While no user exists, the server prints a warning at
  boot with a one-time link, `/setup?token=...`: open it on the machine the
  server runs on (it answers only to a loopback connection; set
  `BLOG_SETUP_OPEN=1` for a first run behind a proxy on another host, and
  unset it afterwards) to create the first account and be signed in. Or
  create it from the command line: `./blog user EMAIL` (the password is read
  from standard input; `./blog user EMAIL PASSWORD` also works, but leaves
  it in the shell history). In development, run the command through spin:

  ```sh
  cybertrain spin run blog -- user ann@example.com
  ```

- **The admin.** Neither way makes the user an admin. Make them one with
  `./blog user admin EMAIL` (`./blog user unadmin EMAIL` takes it back; a
  signed-in browser sees the change on its next request):

  ```sh
  cybertrain spin run blog -- user admin ann@example.com
  ```

  On Kamal, run the commands in the web container:
  `kamal app exec --reuse "./blog user admin ann@example.com"`. More
  writers are made the same way, with `./blog user EMAIL`; only the ones you
  make admins see `/admin`.
- **Mail.** The password reset mails a link (`deliver_later`, so the
  process that runs jobs sends it) through the `CYBERTRAIN_SMTP_*` settings.
  Set `BLOG_BASE_URL` (as in `https://blog.example.com`, `config/app.rb`)
  wherever the blog is served: links in mails start with it, and in
  production no reset mail is sent without it (or `CYBERTRAIN_HOSTS`).

## English and Japanese

Every page is in English or Japanese (`c.i18n_available_locales = [:en,
:ja]` in `config/app.rb`). The blog's own texts are in
`config/locales/en.yml` and `ja.yml`, which `spin run gen` compiles into
`gen/locales.rb`: the views look them up relative to themselves
(`<%= t(".title") %>` in `articles/index.html.erb` reads
`articles.index.title`), the controllers' flash messages relative to the
action (`t(".created")` in `ArticlesController#create`), and the models'
and attributes' names come from `activerecord.models` and
`activerecord.attributes`. The validation messages ("can't be blank",
"を入力してください"), the dates and numbers, and the sign-in pages' texts
come from the framework's own dictionaries.

`ApplicationController#set_locale` (a `before_action`) picks the language
of each request:

1. `?locale=en` or `?locale=ja`, which is then kept in a `locale` cookie,
   so that the plain links of the next pages stay in that language;
2. else the `locale` cookie;
3. else the browser's `Accept-Language` (`request.preferred_locale`);
4. else English.

A value that is not `en` or `ja`, in the parameter or in the cookie, is
ignored (and never written to the cookie). The header of every page links
to the same page in each language (`/articles/1?locale=ja`), and `<html
lang>` says which one it is in. The tests run with
`c.i18n_raise_on_missing`, so a key missing from both dictionaries fails
them instead of showing "translation missing" on a page.

## Deploying with Kamal

`config/deploy.yml`, `.kamal/secrets`, `public/up.html` and the
`Dockerfile` are what `cybertrain new` writes for
[Kamal 2](https://kamal-deploy.org), with one difference: this app compiles
against the framework in this checkout (`path = "../.."` in spin.toml), so
its `Dockerfile` runs the CLI from the checkout instead of installing the
gem, and the build context is the repository root (`builder.context: ../..`;
`Dockerfile.dockerignore` limits what is sent). Fill in the values marked
CHANGE ME in `config/deploy.yml`, then, from this directory:

```sh
export KAMAL_REGISTRY_PASSWORD=...                           # a token that can push to the registry
export CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)"  # once; keep it
kamal setup    # first time: Docker and kamal-proxy on the server, build, push, start
kamal deploy   # after that
```

The file has two roles from the one image: `web` (`./blog server`, behind
kamal-proxy with the `/up.html` health check) and `worker` (`./blog
worker`: the jobs and scheduled tasks, no HTTP), sharing the SQLite volume;
a `feeds` role for WebSocket subscriptions is there, commented out (the
blog has none). When you upgrade from a cybertrain release without job
heartbeats (0.4.x and earlier), stop every old process before the first new
one starts (`kamal app stop`, then `kamal deploy`): a new worker would
otherwise take an old worker's running job for abandoned and run it a
second time.

`bin/blog.rb` registers a job by hand, `touch`, to see the roles at work:
`./blog touch 1` enqueues it, and the process that runs jobs (`./blog
worker`, or `./blog server` unless `CYBERTRAIN_WORKER=0`) logs
`touch: article 1: <title>`. On Kamal: `kamal app exec --reuse "./blog touch 1"`,
then `kamal app logs --roles worker`.

With a context set, Kamal builds the working tree (uncommitted changes
included), not a clone of HEAD. To try the image without Kamal, from the
repository root:

```sh
docker build -f examples/blog/Dockerfile -t blog .
docker run --rm -p 127.0.0.1:3000:3000 -e CYBERTRAIN_SECRET_KEY_BASE="$(openssl rand -hex 32)" -v blog_storage:/app/storage blog
```

The [Blog image](../../.github/workflows/blog-image.yml) workflow builds this
image for every release, for pull requests that touch `examples/blog/` or
the workflow, and when run by hand, smoke-tests it (health
check, an article through the form, a clean SIGTERM stop, the database kept
on its volume) and loads `config/deploy.yml` with Kamal. Pull requests and manual
runs push nothing; for a release, once every check has passed on a
tag `vX.Y.Z`, the Release workflow has it push the tested image as
`ghcr.io/saeki-mototsune/cybertrain-blog:X.Y.Z` and `latest`.

[docs/deploy-kamal.md](../../docs/deploy-kamal.md) (part 8 of docs/deploy.md, in English) covers the rest:
DNS, the registry, `builder.arch`, backups of the SQLite volume.
