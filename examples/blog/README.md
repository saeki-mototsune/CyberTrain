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
cybertrain spin test   # test/articles.rb, test/comments.rb against storage/test.sqlite3
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
  (`admin.jobs_page "/jobs", before_action: :require_admin`), which lists
  the jobs by state and retries, discards or deletes failed ones.
  `Admin::ArticlesController` does `include AdminGate`, a concern in
  `app/controllers/concerns/admin_gate.rb` whose `included do` block
  declares `before_action :require_admin` and `helper_method :admin?`
  (`spin run gen` splices it into the controller, `gen/concerns.rb`). The
  methods themselves are `ApplicationController`'s, so the jobs page's
  controller, which inherits from it, has the same gate; the article page
  shows a "Manage articles" link when `admin?` is true. The blog has no
  user accounts, so the gate is one shared secret, the environment
  variable `BLOG_ADMIN_TOKEN`:

  ```sh
  export BLOG_ADMIN_TOKEN="$(openssl rand -hex 32)"
  cybertrain server
  curl -H "x-admin-token: $BLOG_ADMIN_TOKEN" http://127.0.0.1:3000/admin/articles
  curl -H "x-admin-token: $BLOG_ADMIN_TOKEN" http://127.0.0.1:3000/admin/jobs
  ```

  The header opens the pages for reading only: the delete, retry and
  discard buttons are forms, which need the CSRF token of a browser session. A
  browser signs in at `/admin/login` with the token; the session then holds
  an HMAC of it (never the token itself), so setting a new token signs out
  every browser signed in with the old one. A request with neither the
  header nor that session gets 404, as if the pages did not exist, and so
  does every request to them and to `/admin/login` while
  `BLOG_ADMIN_TOKEN` is unset or empty, which is the default: the pages stay
  closed until you choose a token. On Kamal, add the variable to the
  secrets in `config/deploy.yml`:

  ```yaml
  env:
    secret:
      - CYBERTRAIN_SECRET_KEY_BASE
      - BLOG_ADMIN_TOKEN
  ```

  and this line to `.kamal/secrets`, then export the value where you run
  `kamal deploy`:

  ```sh
  BLOG_ADMIN_TOKEN=$BLOG_ADMIN_TOKEN
  ```

`test/comments.rb` checks the enqueue with `assert_enqueued_with` and runs
the job with `perform_enqueued_jobs` (`require "cybertrain/test/jobs"` in
`test/support/blog_test.rb`, which also empties the cache and the jobs
table before each test); `test/articles.rb` covers the cached count, the
formats, the assets, the import map and the CSP nonce, the admin
namespace, the gate and the login. [Background work](../../docs/guide/background-and-operations.md)
in the guide covers jobs and scheduled tasks in full.

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
