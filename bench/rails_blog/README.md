# rails_blog

[examples/blog](../../examples/blog), the Rails Guides' "Getting Started"
blog (articles with comments), written in Rails 8.1 so `bench/run` can
measure the two side by side. See [docs/benchmark.md](../../docs/benchmark.md).

It is a stock `rails new` app with the frameworks the blog does not use
left out:

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

- `app/views/` is a copy of examples/blog's (the two trees are identical),
  and `public/style.css` is the same stylesheet.
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
