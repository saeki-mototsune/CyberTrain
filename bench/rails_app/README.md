# rails_app

The Rails side of the benchmark ([docs/benchmark.md](../../docs/benchmark.md)):
the application `rails new` writes with Rails 8.1's defaults, plus the
scaffold, as the CyberTrain side is the application `cybertrain new` writes
plus its scaffold. It was made with Rails 8.1.4.1 on Ruby 3.4.6 by:

```sh
rails _8.1.4.1_ new rails_app
cd rails_app
bin/rails generate scaffold Article title:string body:text
```

and then changed in only these ways:

- **The root route.** `config/routes.rb`: the generated comment
  `# root "posts#index"` became `root "articles#index"`, as the CyberTrain
  tutorial adds `root "articles#index"`.
- **No credentials.** `config/credentials.yml.enc` and `config/master.key`
  are not committed (the key cannot be, and the file is useless without
  it): production reads `SECRET_KEY_BASE` from the environment, which
  `bench/run` sets.
- **Not committed:** what `rails new` makes at run time and its own
  `.gitignore` leaves out (`.git/`, `log/`, `tmp/`, `storage/*.sqlite3`).
- **This README**, in place of the generated one.
- **Whitespace.** Two blank lines of the generated `.github/workflows/ci.yml`
  held indentation only; it is removed, for this repository's commit gate.
  (The workflow does not run: GitHub reads only the repository's own
  `.github/`.)

Nothing else is edited: `config/environments/production.rb` (eager loading,
logging at `info` to STDOUT, Solid Cache, Solid Queue, no `force_ssl`, any
host), `config/puma.rb` (3 threads; Puma reads `WEB_CONCURRENCY` for the
number of worker processes), `config/database.yml` (SQLite:
`storage/production.sqlite3`, and Solid Cache's, Solid Queue's and Solid
Cable's own files), the `ApplicationController` (`allow_browser versions:
:modern`, `stale_when_importmap_changes`), the layout (Propshaft's
`stylesheet_link_tag :app`, `javascript_importmap_tags` with Turbo and
Stimulus), and the scaffold's controller, model (no validations) and views.

`rails new` also writes a Dockerfile, Kamal, Thruster, RuboCop, Brakeman and
a CI workflow; they are kept as generated and are not used by `bench/run`,
which runs `bin/rails server` with `RAILS_ENV=production` after
`bin/rails db:prepare assets:precompile`. Solid Queue is not started (the
scaffold enqueues no job, and the generated `config/puma.rb` starts it only
when `SOLID_QUEUE_IN_PUMA` is set).

`bench/run` sends a current Chrome `User-Agent` with every request, so the
generated `allow_browser` check passes as it would for a real visitor.

Run it by hand:

```sh
bundle install
export RAILS_ENV=production SECRET_KEY_BASE=$(ruby -rsecurerandom -e 'print SecureRandom.hex(64)')
bin/rails db:prepare assets:precompile
bin/rails server    # http://127.0.0.1:3000
```
