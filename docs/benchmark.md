# Benchmark: the blog, CyberTrain vs Rails

[examples/blog](../examples/blog) is the Rails Guides' "Getting Started"
blog built on CyberTrain. [bench/rails_blog](../bench/rails_blog) is the same
blog written in Rails 8.1. [bench/run](../bench/run) builds both, runs each in
production mode on the same machine and loads them with the same requests;
[bench/report](../bench/report) turns its JSON into the tables below. The
recorded run is [bench/results/2026-10-08.json](../bench/results/2026-10-08.json); the first one,
before the speedups described below, is [2026-10-07.json](../bench/results/2026-10-07.json).

On one CPU core, CyberTrain serves 2.3 to 8.2 times the requests per second
of Rails 8.1 (YJIT, Puma) for the same pages, answers a single page in 0.5 to
0.6 ms against 1.8 to 3.7 ms, uses a twelfth of the memory, starts in 0.02 s
against 1.2 s, and deploys as one 2.5 MB file against 109 MB of Ruby, gems and
source. With jemalloc in both, it is 2.8 to 10.1 times on one core. A second
core helps Rails more (Puma adds a whole process, which doubles it; CyberTrain's
second worker thread adds 18 to 84%), so on two cores the lead is 2.3 to 4.6
times, and 2.5 to 6.0 with jemalloc. The price is a compile of about two
minutes.

| 16 connections, req/s | 1 core: CyberTrain | Rails | | 2 cores: CyberTrain | Rails | |
| --- | --: | --: | --: | --: | --: | --: |
| `GET /articles` | 2,092 | 514 | 4.1x | 2,769 | 1,017 | 2.7x |
| `GET /articles/1` | 2,035 | 247 | 8.2x | 2,411 | 521 | 4.6x |
| `POST /articles/2/comments` | 1,494 | 416 | 3.6x | 2,214 | 798 | 2.8x |
| `GET /style.css` | 15,611 | 6,733 | 2.3x | 28,648 | 12,539 | 2.3x |
| *with jemalloc in both:* | | | | | | |
| `GET /articles` | 3,159 | 540 | 5.8x | 4,282 | 1,096 | 3.9x |
| `GET /articles/1` | 2,610 | 258 | 10.1x | 3,297 | 550 | 6.0x |
| `POST /articles/2/comments` | 1,752 | 476 | 3.7x | 2,545 | 825 | 3.1x |
| `GET /style.css` | 19,066 | 6,712 | 2.8x | 31,393 | 12,682 | 2.5x |

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
- **SQLite's busy wait.** `PRAGMA busy_timeout` makes a connection that
  finds the write lock taken sleep 1, 2, 5 ... 100 ms between tries, and under
  Spinel that sleep holds its OS worker. With `SPINEL_WORKERS=2` two inserts
  met on the lock all the time, and a comment POST on two cores was slower
  than on one (1,222 against 1,625 req/s, p99 52 ms). A busy handler written
  in C (`ffi_source`) retries every 100 us instead: the same POST on two cores
  went to 2,214 req/s, 1.5 times the one-core rate, p99 22 ms.
- **Less per record.** `Model#errors` is made on first use instead of in
  `initialize` (an `Errors`, a Hash and an Array for every loaded row), and
  generated models skip `assign_attributes`, and the Proc it allocates, for
  the empty Hash `from_row` passes.
- **Smaller things.** `Html.escape` allocates nothing when nothing needs
  escaping, ids skip the URL encoder, header lookups compare names without
  downcasing both sides, form attributes are built in one interpolation.

Measured back to back on the same data, 16 connections, the averages of two
runs (`before` is a binary built from the commit before these changes):

| req/s | `GET /articles` | `GET /articles/1` | `POST` comment | `POST`, 2 cores, `SPINEL_WORKERS=2` |
| --- | --: | --: | --: | --: |
| Before | 1,108 | 1,107 | 1,410 | 1,219 (p99 49 ms) |
| After | 2,396 (2.2x) | 1,938 (1.8x) | 1,427 | 2,527 (2.1x, p99 16 ms) |
| After, with jemalloc | 3,111 (2.8x) | 2,639 (2.4x) | | |

The one-core POST barely moves: its time is in SQLite's write and the
redirect, not in the code these changes touched.

About 770 Strings per article page are left, and the collector and the thread
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

Recorded 2026-10-08 at commit 5b996f7: Intel(R) Xeon(R) Processor @ 2.10GHz, 4 CPUs, 15.7 GB, Ubuntu 24.04.5 LTS (Linux 6.18.44-fc-v80).

| | CyberTrain | Rails |
| --- | --- | --- |
| Version | cybertrain 0.2.1, spinel 112bae85c1a2 (2026.09.12) | Rails 8.1.4, Puma 8.0.2, sqlite3 gem 2.9.6 |
| Runtime | native binary (cc 13.3.0, `-O2`), system SQLite 3.45.1 | ruby 3.4.6, YJIT on, SQLite 3.53.2 (the gem's own) |

### One CPU core, system malloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 1,945 | 509 | 3.8x | 0.46 / 2.02 ms | 1.78 / 4.45 ms |
| GET /articles (30 articles) | 16 | 2,092 | 514 | 4.1x | 7.00 / 13.6 ms | 29.6 / 47.3 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,643 | 247 | 6.6x | 0.56 / 1.61 ms | 3.66 / 8.42 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,035 | 247 | 8.2x | 7.47 / 13.0 ms | 58.3 / 183.7 ms |
| GET /style.css (public/) | 1 | 13,813 | 5,144 | 2.7x | 0.06 / 0.70 ms | 0.16 / 1.74 ms |
| GET /style.css (public/) | 16 | 15,611 | 6,733 | 2.3x | 0.96 / 2.51 ms | 2.24 / 7.09 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,399 | 451 | 3.1x | 0.64 / 2.01 ms | 1.99 / 6.44 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,494 | 416 | 3.6x | 9.96 / 17.3 ms | 35.5 / 76.8 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 9.6 MB | 111.2 MB |
| After the load runs | 10.5 MB | 131.4 MB |
| After the load runs (PSS) | 8.6 MB | 129.2 MB |

### Two CPU cores, system malloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 1,897 | 443 | 4.3x | 0.47 / 1.56 ms | 2.05 / 5.00 ms |
| GET /articles (30 articles) | 16 | 2,769 | 1,017 | 2.7x | 6.98 / 15.6 ms | 15.0 / 26.7 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,627 | 230 | 7.1x | 0.57 / 1.44 ms | 4.07 / 9.36 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,411 | 521 | 4.6x | 7.74 / 16.4 ms | 27.5 / 125.0 ms |
| GET /style.css (public/) | 1 | 13,515 | 4,033 | 3.4x | 0.07 / 0.65 ms | 0.21 / 1.58 ms |
| GET /style.css (public/) | 16 | 28,648 | 12,539 | 2.3x | 0.63 / 2.71 ms | 1.13 / 5.41 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,494 | 408 | 3.7x | 0.59 / 2.01 ms | 2.23 / 6.41 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,214 | 798 | 2.8x | 8.47 / 21.7 ms | 19.8 / 42.4 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 10.5 MB | 292.0 MB |
| After the load runs | 11.8 MB | 338.4 MB |
| After the load runs (PSS) | 9.9 MB | 257.7 MB |

### One CPU core, jemalloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,495 | 522 | 4.8x | 0.36 / 1.20 ms | 1.72 / 4.47 ms |
| GET /articles (30 articles) | 16 | 3,159 | 540 | 5.8x | 4.70 / 8.96 ms | 28.4 / 46.1 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,117 | 266 | 7.9x | 0.44 / 1.15 ms | 3.48 / 6.99 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,610 | 258 | 10.1x | 5.71 / 10.1 ms | 55.2 / 158.4 ms |
| GET /style.css (public/) | 1 | 14,814 | 5,558 | 2.7x | 0.06 / 0.33 ms | 0.15 / 1.58 ms |
| GET /style.css (public/) | 16 | 19,066 | 6,712 | 2.8x | 0.79 / 1.73 ms | 2.23 / 8.47 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,531 | 463 | 3.3x | 0.62 / 1.69 ms | 1.96 / 5.37 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,752 | 476 | 3.7x | 8.35 / 17.4 ms | 30.9 / 69.9 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 12.1 MB | 108.5 MB |
| After the load runs | 13.1 MB | 118.7 MB |
| After the load runs (PSS) | 10.3 MB | 115.7 MB |

### Two CPU cores, jemalloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,583 | 474 | 5.5x | 0.36 / 1.22 ms | 1.94 / 5.09 ms |
| GET /articles (30 articles) | 16 | 4,282 | 1,096 | 3.9x | 4.70 / 9.82 ms | 13.8 / 25.4 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,148 | 245 | 8.8x | 0.44 / 1.53 ms | 3.75 / 8.31 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,297 | 550 | 6.0x | 5.82 / 12.4 ms | 26.2 / 101.8 ms |
| GET /style.css (public/) | 1 | 15,211 | 4,573 | 3.3x | 0.06 / 0.67 ms | 0.18 / 1.82 ms |
| GET /style.css (public/) | 16 | 31,393 | 12,682 | 2.5x | 0.58 / 2.69 ms | 1.13 / 4.66 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,705 | 413 | 4.1x | 0.53 / 3.26 ms | 2.22 / 6.34 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,545 | 825 | 3.1x | 7.23 / 16.2 ms | 18.2 / 40.3 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 13.4 MB | 287.8 MB |
| After the load runs | 14.7 MB | 312.0 MB |
| After the load runs (PSS) | 12.0 MB | 222.3 MB |

| Startup (5 boots, median) | CyberTrain | Rails |
| --- | --: | --: |
| Spawn to first 200 for `GET /` | 0.016 s | 1.159 s |
| RSS then | 8.4 MB | 87.2 MB |

| What the server needs | CyberTrain | Rails |
| --- | --: | --: |
| The application | 2.5 MB binary (`dist/blog`) | 0.06 MB of source |
| Gems | none | 58.3 MB (69 gems) |
| Ruby | none | 50.5 MB |
| Total | 2.5 MB | 108.8 MB |
| Shared libraries | libm.so.6, libcrypt.so.1, libsqlite3.so.0, libc.so.6, /lib64/ld-linux-x86-64.so.2 | (Ruby's own, and the gems' native extensions) |

`cybertrain build` took 137 s.

## Reading the results

- **One core: 2.3 to 8.2 times the requests** (2.8 to 10.1 with jemalloc in
  both). The gap is widest on the article page, the request with the most view
  work: 10 partials and 12 forms, each with a CSRF token (a separately signed one
  per form in Rails). CyberTrain renders the list and the article page in about
  the same time; Rails takes twice as long for the article as for the list.
- **Latency.** One request at a time, CyberTrain answers the pages in 0.5 to
  0.6 ms (median) and Rails in 1.8 to 3.7 ms. With 16 connections on one core,
  CyberTrain's 99th percentile is 13 to 17 ms against 47 to 184 ms for the
  dynamic pages; on two cores 16 to 22 ms against 27 to 125 ms.
- **Two cores.** Puma's second worker process doubles Rails (1.9 to 2.1 times
  its one-core rate). `SPINEL_WORKERS=2` gives CyberTrain 18 to 32% more on the
  pages, 48% on the POST and 84% on the static file: less than a whole second
  process, so the lead narrows to 2.3 to 4.6 times. `SPINEL_WORKERS` stays 1 by
  default; on a server with more than one core, set it to the core count
  ([spikes/NOTES.md](../spikes/NOTES.md) rule 22 has the measurements).
- **jemalloc.** It gives CyberTrain 1.2 to 1.5 times on one core and Rails up
  to 1.15 times: CyberTrain spends more of its time in malloc.
- **Memory.** One CyberTrain process serving 16 connections stays near 11 MB
  (13 MB with jemalloc). One Puma process with Rails loaded is 131 MB after the
  load; two workers are 338 MB.
- **Startup.** The binary answers its first request 0.016 s after it is
  spawned; Rails takes 1.2 s with bootsnap's cache warm.
- **Size.** The server needs one 2.5 MB file, which links libc and the
  system SQLite (and libjemalloc when chosen), against Ruby, 69 gems and the
  app: 109 MB.
- **What it costs.** The binary has to be built: `cybertrain build` took
  137 s on this machine (183 s on 2026-10-07: the VM's speed varies), and
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
