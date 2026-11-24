# bench/

The CyberTrain-vs-Rails benchmark: [docs/benchmark.md](../docs/benchmark.md)
has the method, the recorded results and how to run it.

- `run` builds [examples/blog](../examples/blog) (`cybertrain build`) and
  `rails_blog` (`bundle install`, `assets:precompile`), serves each in
  production mode pinned to its own CPUs, seeds both through their forms
  (signed in for the articles, as a visitor for the comments), loads them
  with wrk as that visitor, and writes `results/<date>.json`.
- `report` prints the Markdown tables of docs/benchmark.md from a result.
- `rails_blog/` is examples/blog in Rails 8.1, with Rails 8's defaults
  for what the blog does (the authentication generator, Propshaft, import
  maps, Turbo, Solid Cache, Solid Queue, Solid Cable); [its
  README](rails_blog/README.md) lists every change from `rails new` and what
  is left out.
- `results/` holds the recorded runs; `tmp/` (ignored) the scratch copies,
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
