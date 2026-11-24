# bench/

The CyberTrain-vs-Rails benchmark: [docs/benchmark.md](../docs/benchmark.md)
has the method, the recorded results and how to run it.

- `run` generates the CyberTrain app from this checkout into
  `tmp/bench_app/` (`cybertrain new --path`, `generate scaffold article`,
  the root route, `db migrate`, `cybertrain build`) and prepares
  `rails_app` (`bundle install`, `assets:precompile`), serves each in
  production mode pinned to its own CPUs, seeds both through the scaffold's
  form as a visitor, loads them with wrk, and writes `results/<date>.json`.
- `report` prints the Markdown tables of docs/benchmark.md from a result.
- `rails_app/` is what `rails new` and `bin/rails generate scaffold Article
  title:string body:text` write in Rails 8.1, with the root route; [its
  README](rails_app/README.md) lists the exact commands and the few files
  that differ from what they wrote.
- `results/` holds the recorded runs (the scaffold's since
  `2026-11-24-scaffold.json`, examples/blog against a Rails rewrite of it
  before); `tmp/` (ignored) the scratch copies,
  server logs and the pages each app served.

The mixed-load measurement of the shared SQLite database is separate:
[docs/sqlite-shared-load.md](../docs/sqlite-shared-load.md) has the scenario,
the recorded runs and how to read them.

- `mixed` compiles `mixed_load.rb` with Spinel and runs it
  (`bench/mixed duration=5 workers=2`; the settings are listed at the top of
  `mixed_load.rb`).
- `mixed_load.rb` runs business writes and reads, jobs, the cache,
  rate-limit counters and stream broadcasts in one process on one database
  file under `tmp/mixed/`, each alone and then together, and prints one
  table.
