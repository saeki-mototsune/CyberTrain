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
