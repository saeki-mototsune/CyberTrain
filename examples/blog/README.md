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
- `articles/show.html.erb` lists the comments (`comments/_comment`) and
  ends with the comment form (`comments/_form`,
  `form_with(model: [@article, @comment])`).

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
image on every change to the framework or the app, smoke-tests it (health
check, an article through the form, a clean SIGTERM stop, the database kept
on its volume) and loads `config/deploy.yml` with Kamal.

[docs/deploy-kamal.md](../../docs/deploy-kamal.md) (part 8 of docs/deploy.md, in English) covers the rest:
DNS, the registry, `builder.arch`, backups of the SQLite volume.
