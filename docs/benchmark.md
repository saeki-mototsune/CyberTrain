# Benchmark: the blog, CyberTrain vs Rails

[examples/blog](../examples/blog) is the Rails Guides' "Getting Started"
blog built on CyberTrain. [bench/rails_blog](../bench/rails_blog) is the same
blog written in Rails 8.1. [bench/run](../bench/run) builds both, runs each in
production mode on the same machine and loads them with the same requests;
[bench/report](../bench/report) turns its JSON into the tables below. The
recorded run is [bench/results/2026-10-08.json](../bench/results/2026-10-08.json); the first one,
before the speedups described below, is [2026-10-07.json](../bench/results/2026-10-07.json).

On one CPU core, CyberTrain serves 2.7 to 7.5 times the requests per second
of Rails 8.1 (YJIT, Puma) for the same pages, answers a single page in 0.5 to
0.6 ms against 1.8 to 3.6 ms, uses a twelfth of the memory, starts in 0.02 s
against 1.1 s, and deploys as one 2.5 MB file against 109 MB of Ruby, gems and
source. With jemalloc in both, it is 2.8 to 9.6 times on one core. A second
core helps Rails more (Puma adds a whole process, which doubles it), so on two
cores the lead is 1.5 to 4.2 times, and 1.6 to 6.1 with jemalloc. The price is
a compile of two to three minutes.

| 16 connections, req/s | 1 core: CyberTrain | Rails | | 2 cores: CyberTrain | Rails | |
| --- | --: | --: | --: | --: | --: | --: |
| `GET /articles` | 2,117 | 523 | 4.1x | 2,517 | 1,041 | 2.4x |
| `GET /articles/1` | 1,948 | 258 | 7.5x | 2,218 | 523 | 4.2x |
| `POST /articles/2/comments` | 1,625 | 436 | 3.7x | 1,222 | 799 | 1.5x |
| `GET /style.css` | 17,887 | 6,560 | 2.7x | 26,918 | 12,873 | 2.1x |
| *with jemalloc in both:* | | | | | | |
| `GET /articles` | 2,611 | 576 | 4.5x | 3,773 | 1,115 | 3.4x |
| `GET /articles/1` | 2,689 | 279 | 9.6x | 2,989 | 494 | 6.1x |
| `POST /articles/2/comments` | 1,917 | 470 | 4.1x | 1,286 | 806 | 1.6x |
| `GET /style.css` | 19,489 | 6,950 | 2.8x | 30,325 | 12,962 | 2.3x |

## How CyberTrain got faster

The first recorded run (2026-10-07) had CyberTrain at 1,026 and 1,064 requests
a second for the list and the article page on one core. Profiling it (perf with
DWARF call graphs, and Spinel's `SPINEL_ALLOC_REPORT`) showed no single hot
spot: about a fifth of the time in malloc and free, a fifth in the garbage
collector, a sixth in the kernel switching between the runtime's threads (which
the collector's stop-the-world drives), and the rest spread over the template
interpreter. An article page allocated about 1,100 Strings. What changed:

- **Typed byte loops.** `Html.escape` (every `<%= %>`), `Cast.parse_time`
  (every datetime column of every row) and the new `Router.plain_segment?`
  read bytes of a String whose type Spinel knows. Their parameters were
  polymorphic, so each `getbyte` and each `==` was a dynamic call
  (`sp_poly_eq` alone was 5% of an article page). The generated C is the place
  to check this: `spinel bin/blog.rb -S`.
- **No String per character.** `Cast.parse_time` sliced six substrings and a
  one-character String per digit; `Inflector.underscore` (a model's and a
  controller's key on every request) built one per character. Both copy runs
  of bytes now; `Helpers` also remembers model and route keys per request.
- **No non-local `return` from a block.** `each { return ... }` compiles to a
  `setjmp` and a Proc per call under Spinel; the partial locals check and the
  callback chain (now built once per request) use `while` loops.
- **SQLite.** Column names are read once per statement instead of once per
  row and column, a second copy of every text value is gone (an FFI `:str`
  return already copies), and each connection keeps up to 64 prepared
  statements (reset and cleared after use, finalized on close).
- **Smaller things.** `Html.escape` allocates nothing when nothing needs
  escaping, ids skip the URL encoder, header lookups compare names without
  downcasing both sides, form attributes are built in one interpolation.

Measured back to back on the same data, one core, 16 connections (the
`before` binary built from the commit before these changes):

| | `GET /articles` | `GET /articles/1` | `GET /style.css` |
| --- | --: | --: | --: |
| Before | 1,147 | 1,094 | 16,979 |
| After | 2,175 (1.9x) | 1,939 (1.8x) | 17,472 |
| After, with jemalloc | 3,074 (2.7x) | 2,469 (2.3x) | 18,513 |

About 790 Strings per article page are left, and the collector and the thread
switches it causes are still the largest costs: what remains is mostly in the
interpreter and in Spinel's runtime rather than in one function of the
framework. jemalloc is not linked by default, because it needs its development
package to build; `cybertrain new` writes `allocator = "jemalloc"` into spin.toml
commented out, with that note.

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
- **malloc.** Each CPU configuration runs twice: with the system's malloc
  (glibc), which is what both frameworks get out of the box, and with
  jemalloc preloaded into both servers (`LD_PRELOAD`), which is what Rails'
  generated Dockerfile does in production and what `allocator = "jemalloc"`
  in an app's spin.toml does for CyberTrain (linking it measures the same as
  preloading it).
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

Recorded 2026-10-08 at commit 453339d: Intel(R) Xeon(R) Processor @ 2.10GHz, 4 CPUs, 15.7 GB, Ubuntu 24.04.5 LTS (Linux 6.18.44-fc-v80).

| | CyberTrain | Rails |
| --- | --- | --- |
| Version | cybertrain 0.2.1, spinel 112bae85c1a2 (2026.09.12) | Rails 8.1.4, Puma 8.0.2, sqlite3 gem 2.9.6 |
| Runtime | native binary (cc 13.3.0, `-O2`), system SQLite 3.45.1 | ruby 3.4.6, YJIT on, SQLite 3.53.2 (the gem's own) |

### One CPU core, system malloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 1,794 | 515 | 3.5x | 0.51 / 1.64 ms | 1.76 / 4.13 ms |
| GET /articles (30 articles) | 16 | 2,117 | 523 | 4.1x | 7.27 / 12.5 ms | 29.5 / 43.8 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,637 | 266 | 6.2x | 0.57 / 1.52 ms | 3.56 / 6.71 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 1,948 | 258 | 7.5x | 7.89 / 12.9 ms | 56.0 / 167.3 ms |
| GET /style.css (public/) | 1 | 14,892 | 5,727 | 2.6x | 0.06 / 0.42 ms | 0.14 / 1.51 ms |
| GET /style.css (public/) | 16 | 17,887 | 6,560 | 2.7x | 0.87 / 1.63 ms | 2.30 / 6.90 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,481 | 441 | 3.4x | 0.61 / 1.80 ms | 2.04 / 7.32 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,625 | 436 | 3.7x | 9.52 / 15.4 ms | 33.8 / 74.0 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 9.5 MB | 111.3 MB |
| After the load runs | 10.5 MB | 129.8 MB |
| After the load runs (PSS) | 8.6 MB | 127.6 MB |

### Two CPU cores, system malloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 1,636 | 488 | 3.4x | 0.55 / 2.10 ms | 1.87 / 4.58 ms |
| GET /articles (30 articles) | 16 | 2,517 | 1,041 | 2.4x | 7.75 / 16.5 ms | 14.5 / 33.0 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,550 | 245 | 6.3x | 0.61 / 1.68 ms | 3.77 / 7.63 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,218 | 523 | 4.2x | 8.43 / 18.5 ms | 27.4 / 134.1 ms |
| GET /style.css (public/) | 1 | 14,303 | 4,759 | 3.0x | 0.06 / 0.66 ms | 0.17 / 1.34 ms |
| GET /style.css (public/) | 16 | 26,918 | 12,873 | 2.1x | 0.58 / 3.02 ms | 1.11 / 4.91 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,344 | 413 | 3.3x | 0.65 / 2.14 ms | 2.20 / 6.49 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,222 | 799 | 1.5x | 14.5 / 52.2 ms | 18.6 / 41.2 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 10.5 MB | 292.7 MB |
| After the load runs | 12.3 MB | 335.4 MB |
| After the load runs (PSS) | 10.4 MB | 255.8 MB |

### One CPU core, jemalloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,364 | 567 | 4.2x | 0.39 / 1.54 ms | 1.60 / 4.04 ms |
| GET /articles (30 articles) | 16 | 2,611 | 576 | 4.5x | 5.55 / 11.4 ms | 27.0 / 41.8 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,887 | 278 | 6.8x | 0.48 / 1.71 ms | 3.37 / 6.36 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,689 | 279 | 9.6x | 5.59 / 9.99 ms | 52.8 / 126.8 ms |
| GET /style.css (public/) | 1 | 14,123 | 5,996 | 2.4x | 0.06 / 0.79 ms | 0.14 / 1.46 ms |
| GET /style.css (public/) | 16 | 19,489 | 6,950 | 2.8x | 0.78 / 4.49 ms | 2.18 / 6.47 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,700 | 469 | 3.6x | 0.54 / 1.98 ms | 1.94 / 6.07 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,917 | 470 | 4.1x | 7.82 / 13.4 ms | 31.5 / 69.2 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 12.1 MB | 108.6 MB |
| After the load runs | 13.2 MB | 119.2 MB |
| After the load runs (PSS) | 10.3 MB | 116.1 MB |

### Two CPU cores, jemalloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,345 | 481 | 4.9x | 0.40 / 1.19 ms | 1.90 / 4.71 ms |
| GET /articles (30 articles) | 16 | 3,773 | 1,115 | 3.4x | 4.96 / 10.8 ms | 13.9 / 25.8 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,949 | 246 | 7.9x | 0.49 / 1.99 ms | 3.76 / 7.80 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,989 | 494 | 6.1x | 6.25 / 13.7 ms | 29.1 / 142.3 ms |
| GET /style.css (public/) | 1 | 15,992 | 3,669 | 4.4x | 0.05 / 0.48 ms | 0.21 / 2.02 ms |
| GET /style.css (public/) | 16 | 30,325 | 12,962 | 2.3x | 0.57 / 2.84 ms | 1.10 / 5.03 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,814 | 413 | 4.4x | 0.50 / 1.43 ms | 2.21 / 7.26 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,286 | 806 | 1.6x | 13.7 / 54.5 ms | 18.4 / 39.7 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 13.5 MB | 287.9 MB |
| After the load runs | 15.3 MB | 315.1 MB |
| After the load runs (PSS) | 12.5 MB | 226.4 MB |

| Startup (5 boots, median) | CyberTrain | Rails |
| --- | --: | --: |
| Spawn to first 200 for `GET /` | 0.017 s | 1.096 s |
| RSS then | 8.6 MB | 87.1 MB |

| What the server needs | CyberTrain | Rails |
| --- | --: | --: |
| The application | 2.5 MB binary (`dist/blog`) | 0.06 MB of source |
| Gems | none | 58.3 MB (69 gems) |
| Ruby | none | 50.5 MB |
| Total | 2.5 MB | 108.8 MB |
| Shared libraries | libm.so.6, libcrypt.so.1, libsqlite3.so.0, libc.so.6, /lib64/ld-linux-x86-64.so.2 | (Ruby's own, and the gems' native extensions) |

`cybertrain build` took 134 s.

## Reading the results

- **One core: 2.7 to 7.5 times the requests** (2.8 to 9.6 with jemalloc in
  both). The gap is widest on the article page, the request with the most view
  work: 10 partials and 12 forms, each with a CSRF token (a separately signed one
  per form in Rails). CyberTrain renders the list and the article page in about
  the same time; Rails takes twice as long for the article as for the list.
- **Latency.** One request at a time, CyberTrain answers the pages in 0.5 to
  0.6 ms (median) and Rails in 1.8 to 3.6 ms. With 16 connections on one core,
  CyberTrain's 99th percentile is 12 to 15 ms against 44 to 167 ms for the
  dynamic pages.
- **Two cores.** Puma's second worker process doubles Rails (2.0 times its
  one-core rate on the pages). `SPINEL_WORKERS=2` adds 14 to 19% to
  CyberTrain's pages (45% for the list with jemalloc) and 50% to the static
  file, and costs a quarter on the POST, whose 99th percentile is then higher
  than Rails' (52 ms against 41 ms). One worker stays the right default for a
  server that writes; [spikes/NOTES.md](../spikes/NOTES.md) rule 22 keeps the
  measurement.
- **jemalloc.** It gives CyberTrain 1.2 to 1.4 times on one core and Rails 1.1
  times: CyberTrain spends more of its time in malloc.
- **Memory.** One CyberTrain process serving 16 connections stays near 11 MB
  (13 MB with jemalloc). One Puma process with Rails loaded is 130 MB after the
  load; two workers are 335 MB.
- **Startup.** The binary answers its first request 0.017 s after it is
  spawned; Rails takes 1.1 s with bootsnap's cache warm.
- **Size.** The server needs one 2.5 MB file, which links libc and the
  system SQLite (and libjemalloc when chosen), against Ruby, 69 gems and the
  app: 109 MB.
- **What it costs.** The binary has to be built: `cybertrain build` took
  134 s on this machine (183 s the day before: the VM's speed varies), and
  every Ruby change needs a rebuild (`cybertrain server` does it for you in
  development), where Rails runs its source as it is. And the comparison covers
  only the slice of Rails both apps use: CyberTrain has no jobs, mailers,
  Action Cable, asset pipeline or i18n, and its ORM and router are smaller (see
  "Differences from Rails" in the [README](../README.md#differences-from-rails)).
- **The machine.** Rails, unchanged, measured 20 to 25% faster on this VM on
  2026-10-08 than on 2026-10-07: compare numbers within one run, not across
  runs. The before/after table above was measured in one session.
- **Static files.** In production both apps would usually sit behind a proxy
  that serves `public/` itself ([deploy.md](deploy.md) puts Caddy in front),
  so the `GET /style.css` rows are there for completeness.

## Running it

On Linux with at least 4 CPUs, from a checkout:

```sh
cybertrain setup                 # Spinel, for examples/blog
sudo apt-get install -y wrk libjemalloc2   # jemalloc for the -jemalloc configurations
cd bench/rails_blog && bundle install && cd ../..
BENCH_RAILS_RUBY=/path/to/ruby/bin/ruby bench/run   # about 50 minutes; --quick to check the setup
bench/report                     # the tables above, from the newest bench/results/*.json
```

`BENCH_RAILS_RUBY` is the Ruby that runs Rails (default: the `ruby` on
`PATH`); give it one built with YJIT, or the numbers undersell Rails (bench/run
warns). The recorded run used Ruby 3.4.6 from
[ruby/ruby-builder](https://github.com/ruby/ruby-builder) (the build
`setup-ruby` installs on GitHub Actions). `bench/run --help` lists the knobs
(configurations, durations, runs); its scratch files go to `bench/tmp/`.
