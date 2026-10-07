# Benchmark: the blog, CyberTrain vs Rails

[examples/blog](../examples/blog) is the Rails Guides' "Getting Started"
blog built on CyberTrain. [bench/rails_blog](../bench/rails_blog) is the same
blog written in Rails 8.1. [bench/run](../bench/run) builds both, runs each in
production mode on the same machine and loads them with the same requests;
[bench/report](../bench/report) turns its JSON into the tables below. The
recorded run is [bench/results/2026-10-07.json](../bench/results/2026-10-07.json).

On one CPU core, CyberTrain serves 2.5 to 5.5 times the requests per second
of Rails 8.1 (YJIT, Puma) for the same pages, answers a single request in
about a fifth to a half of the time, uses a twelfth of the memory, starts in
0.02 s against 1.2 s, and deploys as one 2.5 MB file against 109 MB of Ruby,
gems and source. Given a second core, Rails nearly doubles (Puma adds a
process) while CyberTrain's second worker thread adds 9 to 30% to reads and
slows writes by a quarter, so on two cores the lead is 1.2 to 2.9 times. The
price is a 3-minute compile.

| 16 connections, requests/s | One core: CyberTrain | Rails | | Two cores: CyberTrain | Rails | |
| --- | --: | --: | --: | --: | --: | --: |
| `GET /articles` | 1,026 | 414 | 2.5x | 1,155 | 860 | 1.3x |
| `GET /articles/1` | 1,064 | 192 | 5.5x | 1,156 | 399 | 2.9x |
| `POST /articles/2/comments` | 926 | 324 | 2.9x | 703 | 607 | 1.2x |
| `GET /style.css` | 15,832 | 5,794 | 2.7x | 20,563 | 9,754 | 2.1x |

## What is compared

The two apps are the same application:

- **Same pages.** `bench/rails_blog/app/views/` is a copy of examples/blog's
  views (the two trees are byte-identical), with the same layout and
  `public/style.css`. The HTML both apps send for an article page differs only
  in markup details: the tokens themselves, where `button_to` puts its hidden
  token field, `/>` against `>`, and two attributes Rails adds to forms
  (`accept-charset`, `data-disable-with`).
- **Same code.** The routes, the two controllers and the two models are
  examples/blog's, in Rails' spelling (`def new`, a nested `resources` block,
  `has_many`/`belongs_to`); the validations, flash messages, redirects and
  `rescue_from` are the same. `db/schema.rb` is the same schema.
- **Same storage.** One SQLite file in WAL mode, foreign keys on. CyberTrain
  links the system's SQLite (3.45.1 here); the sqlite3 gem brings its own
  (3.53.2).
- **Same defaults.** Neither app is tuned. CyberTrain runs `dist/blog` from
  `cybertrain build` (views embedded, production by default). Rails runs
  `bin/rails server` with `RAILS_ENV=production`: eager loading, YJIT (Rails
  8 turns it on when the Ruby has it), Puma with its generated
  `config/puma.rb` (3 threads). Both log every request at the `info` level
  to STDOUT, which `bench/run` sends to `/dev/null`.

What each framework does per request by default is not identical, and the
numbers include that: Rails encrypts the session cookie (AES-256-GCM), signs a
separate CSRF token for each form (`per_form_csrf_tokens`) and computes an
`ETag` for every response (`Rack::ETag`), behind a longer middleware stack
(request id, remote IP, security headers, content security policy).
CyberTrain signs its session cookie (HMAC-SHA256) without encrypting it and
puts one CSRF token per session in every form.

## Method

- **Machine.** One cloud VM (details under Results). Each server is pinned
  with `taskset` to CPU 0 (the 1-CPU runs) or CPUs 0-1 (the 2-CPU runs); wrk
  is pinned to CPUs 2-3, so the load generator never takes the server's CPU.
  A shared cloud VM is noisy: repeated runs move by several
  percent, so read the ratios rather than the third digit.
- **Workers.** On one CPU: CyberTrain `SPINEL_WORKERS=1` (its default) and
  Puma in single mode with 3 threads (Rails' default). On two CPUs:
  `SPINEL_WORKERS=2` and Puma with `WEB_CONCURRENCY=2` (two worker
  processes, 3 threads each).
- **Data.** Each server starts on an empty database and is seeded over HTTP
  through its own forms, as a browser would fill them in: 30 articles, then 10
  comments on the first.
- **Requests.** `GET /articles` (the list, 30 rows), `GET /articles/1` (the
  article, its 10 comments as partials and 12 forms: a `button_to` for the
  article and for each comment, and the comment form), `GET /style.css` (a static
  file from `public/`) and `POST /articles/2/comments` (validates, inserts a
  comment, answers 303). Every request carries the session cookie of a
  returning visitor; the POST carries the comment form's CSRF token.
- **Load.** [wrk](https://github.com/wg/wrk) 4.1, keep-alive, 10 s per run:
  1 connection (one request at a time: the latency of a single request) and
  16 connections (2 wrk threads: throughput). Each endpoint first gets 10 s
  of load at 16 connections that is not measured (YJIT compiles during it);
  each figure is the median of 3 runs. A run that sees a socket error or a
  status other than 2xx/3xx fails.
- **Memory.** `VmRSS` from `/proc`, summed over the server's processes
  (Puma's workers included), after seeding and after all the load runs;
  `Pss` too, which splits the pages processes share.
- **Startup.** From spawning the server to the first 200 for `GET /`,
  5 boots, median (Rails with a warm bootsnap cache).
- **What the server needs.** CyberTrain: `dist/blog`, one file that links
  against libc and the system SQLite. Rails: the app's source, the gems
  `bundle list` names outside the development and test groups, and the Ruby
  install without its gem directory (so the gems Ruby itself bundles are
  not counted for Rails).

## Results

Recorded 2026-10-07 at commit c2e4d1c: Intel(R) Xeon(R) Processor @ 2.10GHz, 4 CPUs, 15.7 GB, Ubuntu 24.04.5 LTS (Linux 6.18.44-fc-v77).

| | CyberTrain | Rails |
| --- | --- | --- |
| Version | cybertrain 0.2.1, spinel 112bae85c1a2 (2026.09.12) | Rails 8.1.4, Puma 8.0.2, sqlite3 gem 2.9.6 |
| Runtime | native binary (cc 13.3.0, `-O2`), system SQLite 3.45.1 | ruby 3.4.6, YJIT on |

### One CPU core: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 849 | 393 | 2.2x | 1.05 / 4.04 ms | 2.25 / 6.49 ms |
| GET /articles (30 articles) | 16 | 1,026 | 414 | 2.5x | 15.0 / 28.3 ms | 37.1 / 70.0 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 861 | 179 | 4.8x | 1.06 / 4.95 ms | 5.03 / 11.5 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 1,064 | 192 | 5.5x | 14.3 / 26.2 ms | 75.0 / 247.4 ms |
| GET /style.css (public/) | 1 | 11,512 | 4,321 | 2.7x | 0.07 / 1.84 ms | 0.18 / 4.16 ms |
| GET /style.css (public/) | 16 | 15,832 | 5,794 | 2.7x | 0.92 / 4.98 ms | 2.54 / 9.73 ms |
| POST /articles/2/comments (insert, 303) | 1 | 746 | 334 | 2.2x | 1.20 / 10.6 ms | 2.67 / 8.48 ms |
| POST /articles/2/comments (insert, 303) | 16 | 926 | 324 | 2.9x | 16.2 / 56.8 ms | 45.2 / 98.6 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 9.7 MB | 111.4 MB |
| After the load runs | 10.6 MB | 129.9 MB |
| After the load runs (PSS) | 8.7 MB | 127.7 MB |

### Two CPU cores: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 800 | 342 | 2.3x | 1.19 / 4.48 ms | 2.67 / 8.04 ms |
| GET /articles (30 articles) | 16 | 1,155 | 860 | 1.3x | 15.6 / 35.1 ms | 17.8 / 34.3 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 743 | 166 | 4.5x | 1.24 / 4.47 ms | 5.59 / 13.9 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 1,156 | 399 | 2.9x | 15.8 / 59.9 ms | 36.7 / 211.5 ms |
| GET /style.css (public/) | 1 | 10,696 | 2,898 | 3.7x | 0.08 / 1.81 ms | 0.27 / 3.79 ms |
| GET /style.css (public/) | 16 | 20,563 | 9,754 | 2.1x | 0.76 / 10.5 ms | 1.43 / 7.23 ms |
| POST /articles/2/comments (insert, 303) | 1 | 800 | 312 | 2.6x | 1.09 / 5.58 ms | 2.93 / 9.73 ms |
| POST /articles/2/comments (insert, 303) | 16 | 703 | 607 | 1.2x | 24.1 / 106.9 ms | 24.6 / 57.4 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 10.5 MB | 291.7 MB |
| After the load runs | 12.2 MB | 329.9 MB |
| After the load runs (PSS) | 10.3 MB | 249.0 MB |

| Startup (5 boots, median) | CyberTrain | Rails |
| --- | --: | --: |
| Spawn to first 200 for `GET /` | 0.018 s | 1.235 s |
| RSS then | 8.7 MB | 87.1 MB |

| What the server needs | CyberTrain | Rails |
| --- | --: | --: |
| The application | 2.5 MB binary (`dist/blog`) | 0.07 MB of source |
| Gems | none | 58.3 MB (69 gems) |
| Ruby | none | 50.5 MB |
| Total | 2.5 MB | 108.8 MB |
| Shared libraries | libm.so.6, libcrypt.so.1, libsqlite3.so.0, libc.so.6, /lib64/ld-linux-x86-64.so.2 | (Ruby's own, and the gems' native extensions) |

`cybertrain build` took 183 s.

## Reading the results

- **One core: 2.5 to 5.5 times the requests.** Every request costs the
  native binary less CPU. The gap is widest on the article page (5.5x), the
  request with the most view work: 10 partials and 12 forms, each with a CSRF
  token (a separately signed one per form in Rails). CyberTrain renders the
  list and the article page in about the same time, about 1 ms; Rails needs
  2.3 ms for the list and 5.0 ms for the article.
- **Latency.** One request at a time, CyberTrain answers the pages in
  1.05 to 1.2 ms (median) and Rails in 2.3 to 5.0 ms. With 16 connections on
  one core, CyberTrain's 99th percentile is lower on every request (26 to
  57 ms for the dynamic ones, against 70 to 247 ms). The exception is the
  POST one request at a time, whose 99th percentile is 10.6 ms against
  8.5 ms.
- **Two cores.** Puma's second worker process nearly doubles Rails (1.7 to
  2.1 times its one-core rate). `SPINEL_WORKERS=2` gives CyberTrain 9 to 13%
  more on the two pages and 30% more on the static file, and costs 24% on the
  POST; its 99th percentile at 16 connections is then higher than Rails' for
  the POST (107 ms against 57 ms) and the static file, about equal for the
  list, and still lower for the article page. This is the re-measurement that
  [spikes/NOTES.md](../spikes/NOTES.md) rule 22 asked for once templates and
  SQLite add CPU work: one worker is still the better default for writes, and
  a second core is worth little to one CyberTrain process.
- **Memory.** One CyberTrain process serving 16 connections stays near
  11 MB (12 MB with two worker threads). One Puma process with Rails loaded
  is 130 MB after the load, and two workers are 330 MB (249 MB PSS: the
  workers share part of the master's pages).
- **Startup.** The binary answers its first request 0.018 s after it is
  spawned; Rails takes 1.2 s with bootsnap's cache warm.
- **Size.** The server needs one 2.5 MB file, which links libc and the
  system SQLite, against Ruby, 69 gems and the app: 109 MB.
- **What it costs.** The binary has to be built: `cybertrain build` took
  183 s on this machine, and every Ruby change needs a rebuild
  (`cybertrain server` does it for you in development), where Rails runs its
  source as it is. And the comparison covers only the slice of Rails both
  apps use: CyberTrain has no jobs, mailers, Action Cable, asset pipeline or
  i18n, and its ORM and router are smaller (see "Differences from Rails" in
  the [README](../README.md#differences-from-rails)).
- **Static files.** In production both apps would usually sit behind a proxy
  that serves `public/` itself ([deploy.md](deploy.md) puts Caddy in front),
  so the `GET /style.css` rows are there for completeness.

## Running it

On Linux with at least 4 CPUs, from a checkout:

```sh
cybertrain setup                 # Spinel, for examples/blog
sudo apt-get install -y wrk      # or build wrk from source
cd bench/rails_blog && bundle install && cd ../..
BENCH_RAILS_RUBY=/path/to/ruby/bin/ruby bench/run   # about 25 minutes; --quick to check the setup
bench/report                     # the tables above, from the newest bench/results/*.json
```

`BENCH_RAILS_RUBY` is the Ruby that runs Rails (default: the `ruby` on
`PATH`); give it one built with YJIT, or the numbers undersell Rails (bench/run
warns). The recorded run used Ruby 3.4.6 from
[ruby/ruby-builder](https://github.com/ruby/ruby-builder) (the build
`setup-ruby` installs on GitHub Actions). `bench/run --help` lists the knobs
(configurations, durations, runs); its scratch files go to `bench/tmp/`.
