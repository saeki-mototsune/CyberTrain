# bench/

The CyberTrain-vs-Rails benchmark: [docs/benchmark.md](../docs/benchmark.md)
has the method, the recorded results and how to run it.

- `run` builds [examples/blog](../examples/blog) (`cybertrain build`) and
  `rails_blog`, serves each in production mode pinned to its own CPUs, seeds
  both through their forms, loads them with wrk, and writes
  `results/<date>.json`.
- `report` prints the Markdown tables of docs/benchmark.md from a result.
- `rails_blog/` is the same blog in Rails 8.1 ([its README](rails_blog/README.md)
  lists every change from `rails new`).
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
