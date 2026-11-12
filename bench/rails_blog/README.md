# rails_blog

[examples/blog](../../examples/blog), the Rails Guides' "Getting Started"
blog (articles with comments), written in Rails 8.1 so `bench/run` can
measure the two side by side. See [docs/benchmark.md](../../docs/benchmark.md).

It is a stock `rails new` app with the frameworks the blog does not use
left out, then Active Storage and Active Job put back for the cover image
(below):

```sh
rails new rails_blog --skip-git --skip-docker --skip-kamal --skip-thruster \
  --skip-action-mailer --skip-action-mailbox --skip-action-text --skip-active-job \
  --skip-active-storage --skip-action-cable --skip-hotwire --skip-jbuilder \
  --skip-test --skip-system-test --skip-rubocop --skip-brakeman --skip-bundler-audit \
  --skip-ci --skip-dev-gems --skip-solid --skip-javascript --skip-asset-pipeline \
  --skip-keeps --skip-decrypted-diffs --no-rc
bin/rails g model Article title:string body:text
bin/rails g model Comment commenter:string body:text article:references
```

then edited to match examples/blog file for file:

- `app/views/` started as a copy of examples/blog's, and `public/style.css`
  as the same stylesheet. examples/blog has grown since (a component, Turbo
  Streams, JSON, jobs, an admin namespace); of that, only the cover image is
  here.
- `config/routes.rb`, the two controllers and the two models are the
  examples/blog ones in Rails' spelling: `def new` instead of `new_action`,
  a nested `resources` block, `has_many :comments, dependent: :delete_all`
  and `belongs_to :article` instead of the associations CyberTrain derives
  from the foreign key.
- `ApplicationController` rescues `ActiveRecord::RecordNotFound` as
  examples/blog does, and drops the generated `allow_browser` line.
- `config/database.yml` gives production a database file,
  `storage/production.sqlite3`; the generated one has none.
- The generated credentials are removed: production reads
  `SECRET_KEY_BASE` from the environment.
- An article's cover image is Active Storage's `has_one_attached :cover`,
  where examples/blog has the columns and methods `cybertrain generate
  attachment` writes. `config/application.rb` loads `active_storage/engine`
  and `active_job/railtie` (Active Storage needs it), the migration is
  `bin/rails active_storage:install`'s, and `config/storage.yml` keeps the
  files on disk in `storage/uploads/`. `Article` applies examples/blog's
  limits, which Rails has no built-in validation for: PNG, JPEG, GIF or WebP,
  told from the file's bytes, up to 2 MB. The image is served the way Active
  Storage serves it by default, a redirect to a signed URL. `bench/run`
  requests no cover and seeds none.

Everything else is as generated, including `config/environments/production.rb`
(eager loading, `assume_ssl`/`force_ssl`, logging at `info` to STDOUT) and
`config/puma.rb` (3 threads; `WEB_CONCURRENCY` sets the number of worker
processes).

Run it by hand:

```sh
bundle install
export RAILS_ENV=production SECRET_KEY_BASE=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
bin/rails db:prepare
bin/rails server    # http://127.0.0.1:3000
```
