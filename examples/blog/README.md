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
  and ends with the comment form (`comments/_form`,
  `form_with(model: [@article, @comment])`).

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
an element with the same id). The layout loads Turbo 8.0.12 from
jsDelivr with a `<script type="module">` tag (pinned, with its
`integrity` hash): the framework has no asset pipeline, and without Turbo
the `<turbo-stream-source>` element does nothing. To serve Turbo yourself,
copy `turbo.es2017-esm.js` into `public/` and change the `src`.

```sh
cybertrain db migrate  # spin run gen; spin run db -- migrate; spin run gen
cybertrain server      # http://127.0.0.1:3000 (`cybertrain server 4000`, or PORT=4000, to change it)
cybertrain build       # dist/blog (views embedded) + dist/public/
cybertrain spin test   # test/articles.rb, test/comments.rb against storage/test.sqlite3
```

Run `cybertrain spin run gen` after changing the schema, the routes or a
controller's instance variables and callbacks, and commit `gen/`
(`cybertrain spin run gen -- --check` reports stale files). Views under
`app/views/` are read at run time: edit them without rebuilding. A
production binary (`cybertrain build`, or `CYBERTRAIN_ENV=production`)
renders only the views embedded at build time.

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
