# rails_blog

[examples/blog](../../examples/blog), the Rails Guides' "Getting Started"
blog (articles with comments) grown into a small application, written in
Rails 8.1 so `bench/run` can measure the two side by side. See
[docs/benchmark.md](../../docs/benchmark.md).

It is a stock `rails new` app with Rails 8's defaults for what examples/blog
does (Propshaft, import maps, Turbo, Solid Cache, Solid Queue, Solid Cable,
the authentication generator) and the frameworks it does not use left out:

```sh
rails new rails_blog --skip-git --skip-docker --skip-kamal --skip-thruster \
  --skip-action-mailbox --skip-action-text --skip-jbuilder \
  --skip-test --skip-system-test --skip-rubocop --skip-brakeman --skip-bundler-audit \
  --skip-ci --skip-dev-gems --skip-keeps --skip-decrypted-diffs --no-rc
bin/rails generate authentication
bin/rails g model Article title:string body:text
bin/rails g model Comment commenter:string body:text article:references
bin/rails active_storage:install
```

then edited to match examples/blog on everything `bench/run` requests, file
for file where Rails has the same thing:

- **Pages.** `app/views/` follows examples/blog's: the layout (`<html lang>`,
  the title and brand from the dictionary, `csrf_meta_tags`, `csp_meta_tag`,
  the digested stylesheet, `javascript_importmap_tags`, the language links,
  the sign-in nav, the flash), the article list (the count, the date and
  order filter form, a comment count column), the article page (`time_tag`,
  the admin link, `turbo_stream_from @article`, the comments, the comment
  form), the forms, the sign-in page. A comment is a partial,
  `comments/_comment`, where examples/blog has a component; its author goes
  through the same application helper, `CommentsHelper#comment_author`. The
  HTML the two apps send for an article page differs in markup details (the
  tokens, where `button_to` puts its token field, `/>` against `>`, Rails'
  `accept-charset` on forms, the stream tag below, the import map's
  formatting and pins).
- **Code.** The routes, the controllers and the models are examples/blog's
  in Rails' spelling: `def new` instead of `new_action`, nested `resources`
  blocks, `has_many`/`belongs_to`, `around_action` with `I18n.with_locale`.
  `Article` validates the title's presence and uniqueness (a query on every
  save) and the body's length, and destroys its comments one by one
  (`dependent: :destroy`); `Article.recent` orders the list. The list
  preloads each article's comments for the count column (`includes`),
  reads the number of articles through `Rails.cache` (one minute, as
  examples/blog's cache table), and answers JSON as well; so does the
  article page. `ApplicationController` rescues `ActiveRecord::RecordNotFound`
  as examples/blog does, and drops the generated `allow_browser` line (it
  would answer wrk 406).
- **Signing in.** `bin/rails generate authentication`: `User` with
  `has_secure_password` (bcrypt), `Session` rows, the `Authentication`
  concern, the sign-in and password-reset pages and their mailer (so Action
  Mailer is loaded). As in examples/blog, every action needs a signed-in
  user except reading the list and an article, and posting a comment;
  `users` has an `admin` column (`User#admin?`), and the article page links
  to `/admin/articles` for an admin. Not carried over, as no measured request
  reaches them: examples/blog's account page, "keep me signed in", the idle
  timeout, the lockout after wrong passwords, its first-run `/setup` page and
  its `user` command (`bench/run` creates the user with `bin/rails runner`).
  examples/blog keeps the signed-in session's id in its encrypted session
  cookie; the generator keeps it in a separate signed cookie. For a visitor
  (the measured requests' client) neither reads the database.
- **Session cookie.** Rails' default, encrypted (AES-256-GCM), as
  examples/blog's is now.
- **Languages.** English and Japanese (`config/locales/en.yml`, `ja.yml`,
  examples/blog's texts under Rails' keys). `ApplicationController` picks the
  locale as examples/blog does: `?locale=`, kept in a `locale` cookie; else
  that cookie; else the best match of `Accept-Language`; else English. The
  sign-in texts and the few validation messages its forms can show are in
  the two files (examples/blog takes them from CyberTrain's dictionary);
  there is no `rails-i18n` gem.
- **Content Security Policy.** examples/blog's policy (`default-src`,
  `script-src` and `style-src` 'self', `img-src` 'self' and `data:`) with a
  fresh nonce for every response on `script-src` and `style-src`
  (`config/initializers/content_security_policy.rb`); examples/blog also
  allows the jsDelivr path it loads Turbo from.
- **Stylesheet and scripts.** `app/assets/stylesheets/application.css` and
  `app/assets/images/logo.svg` are examples/blog's; Propshaft digests them
  (`bin/rails assets:precompile`, which `bench/run` runs) into
  `public/assets/`, which Rails serves as static files, as examples/blog
  serves the digested files of `cybertrain build` from `dist/public/assets/`.
  `public/style.css` is gone. The import map pins `application` and
  turbo-rails' own Turbo (examples/blog pins Turbo from jsDelivr; turbo-rails'
  build is the one that knows Action Cable streams); Stimulus, which the
  generator adds, is removed, as are the generated PWA files, icons and
  `bin/dev`/`bin/ci`.
- **Comments in real time.** The article page subscribes to the article's
  stream, `turbo_stream_from @article`: a `<turbo-cable-stream-source>` with
  a signed stream name (examples/blog: a `<turbo-stream-source>` over
  server-sent events). Posting a comment enqueues `NotifyCommentJob`, which
  logs it, and broadcasts the comment partial to the stream in the request
  (`Turbo::StreamsChannel.broadcast_append_to`, rendered then, as
  examples/blog renders its broadcast), then redirects, or answers a Turbo
  form with `create.turbo_stream.erb`. Jobs go to Solid Queue, broadcasts to
  Solid Cable, the cache to Solid Cache: Rails 8's defaults, each in its own
  SQLite file (`config/database.yml`: `storage/production.sqlite3` and
  `production_cache`, `_queue`, `_cable`), where examples/blog keeps its
  jobs, stream messages and cache in tables of its one database.
  `ApplicationCable::Connection` accepts visitors (the generated one rejects
  them), since examples/blog streams to anyone reading an article.
- **Where the jobs run.** examples/blog runs its jobs on a thread of the
  server process. Here Solid Queue runs inside Puma
  (`SOLID_QUEUE_IN_PUMA`, which `bench/run` sets) in its `async` mode:
  its supervisor, dispatcher and worker are threads of the Puma process (of
  the master in cluster mode), not the three processes the default `fork`
  mode adds, which would count three more Rails processes in the memory
  figures.
- **Admin.** `/admin/articles` (the list with delete buttons), for admins
  only. examples/blog's jobs page and its scheduled task have no counterpart
  here beyond Solid Queue's generated `config/recurring.yml`; nothing
  measured reaches them.
- **Cover image.** An article's cover is Active Storage's
  `has_one_attached :cover`, where examples/blog has the columns and methods
  `cybertrain generate attachment` writes; `config/storage.yml` keeps the
  files on disk in `storage/uploads/`. `Article` applies examples/blog's
  limits, which Rails has no built-in validation for: PNG, JPEG, GIF or
  WebP, told from the file's bytes, up to 2 MB. The image is served the way
  Active Storage serves it by default, a redirect to a signed URL. The
  article page asks Active Storage whether a cover is attached (a query);
  examples/blog reads its own columns. `bench/run` requests no cover and
  seeds none.
- **Production database files.** The generated `config/database.yml` names
  no production files; this one does (above).
- **No credentials.** The generated credentials are removed: production
  reads `SECRET_KEY_BASE` from the environment.

Everything else is as generated, including `config/environments/production.rb`
(eager loading, `assume_ssl`/`force_ssl`, logging at `info` to STDOUT, the
Solid adapters) and `config/puma.rb` (3 threads; `WEB_CONCURRENCY` sets the
number of worker processes), apart from the `solid_queue_mode :async` line.

Run it by hand:

```sh
bundle install
export RAILS_ENV=production SECRET_KEY_BASE=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
export SOLID_QUEUE_IN_PUMA=1
bin/rails db:prepare assets:precompile
bin/rails runner 'User.create!(email_address: "you@example.com", password: "a long password")'
bin/rails server    # http://127.0.0.1:3000
```
