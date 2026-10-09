# Benchmark: the blog, CyberTrain vs Rails

[examples/blog](../examples/blog) is the Rails Guides' "Getting Started"
blog built on CyberTrain. [bench/rails_blog](../bench/rails_blog) is the same
blog written in Rails 8.1. [bench/run](../bench/run) builds both, runs each in
production mode on the same machine and loads them with the same requests;
[bench/report](../bench/report) turns its JSON into the tables below. The
recorded run is [bench/results/2026-10-09.json](../bench/results/2026-10-09.json); the first one,
before the speedups described below, is [2026-10-07.json](../bench/results/2026-10-07.json).

On one CPU core, CyberTrain serves 2.6 to 12.2 times the requests per second
of Rails 8.1 (YJIT, Puma) for the same pages, answers a single page in 0.4 to
0.6 ms against 1.9 to 4.7 ms, uses a twelfth of the memory, starts in 0.02 s
against 1.3 s, and deploys as one 2.5 MB file against 109 MB of Ruby, gems and
source. With jemalloc in both, it is 2.8 to 14.6 times on one core. A second
core helps Rails more (Puma adds a whole process, which doubles it; CyberTrain's
second worker thread adds 9 to 58%), so on two cores the lead is 2.0 to 5.5
times, and 2.2 to 7.6 with jemalloc. The price is a compile of about three
minutes.

| 16 connections, req/s | 1 core: CyberTrain | Rails | | 2 cores: CyberTrain | Rails | |
| --- | --: | --: | --: | --: | --: | --: |
| `GET /articles` | 2,641 | 468 | 5.6x | 3,289 | 1,036 | 3.2x |
| `GET /articles/1` | 2,450 | 201 | 12.2x | 2,662 | 486 | 5.5x |
| `POST /articles/2/comments` | 1,507 | 390 | 3.9x | 2,379 | 870 | 2.7x |
| `GET /style.css` | 13,300 | 5,127 | 2.6x | 20,589 | 10,311 | 2.0x |
| *with jemalloc in both:* | | | | | | |
| `GET /articles` | 3,589 | 540 | 6.6x | 4,155 | 995 | 4.2x |
| `GET /articles/1` | 3,217 | 220 | 14.6x | 3,329 | 437 | 7.6x |
| `POST /articles/2/comments` | 1,983 | 436 | 4.5x | 2,369 | 819 | 2.9x |
| `GET /style.css` | 14,658 | 5,254 | 2.8x | 22,055 | 10,227 | 2.2x |

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
- **Typed `to_s` instead of `"#{v}"`.** Interpolation always allocates and
  copies, even for a String, and the polymorphic value `Html.escape` used to
  return made `html_text`, `html_arg` and `SafeString` polymorphic too, so
  the template's own strings travelled the boxed slow path. They are typed now
  (`v.to_s` returns a String's own bytes), which removed about 200 Strings
  from an article page.
- **One allocation per helper.** `button_to` and `hidden_fields` are single
  interpolations, not a `+""` buffer (a copy of the literal, a String object
  and a copy on return); attributes with a literal name are appended in
  place; `Crypto.hex` fills one String with `setbyte` instead of making a
  one-character String per digit (the session cookie's HMAC and the CSRF
  token did 64 each per request); form fields keep the Symbol the template
  passed rather than calling `String#to_sym`, which searches the whole symbol
  table.
- **Typed Template lookups.** `Engine` kept parsed Templates in a Hash, whose
  object values Spinel boxes, so every template, node and environment the
  interpreter touched was polymorphic. It keeps them in an Array, found
  through a String-to-index Hash. A `partial_file` memo per request, and
  `while` loops in the interpreter's hot paths, take out a Proc and closure
  cells per call.
- **Smaller things.** `Html.escape` allocates nothing when nothing needs
  escaping, ids skip the URL encoder, header lookups compare names without
  downcasing both sides, form attributes are built in one interpolation,
  generated `from_row` shares one empty Hash instead of building one per row.

What did not help: Spinel's collector settings (`SPINEL_GC_AGE`,
`SPINEL_GC_OBJ_BUDGET`, `SPINEL_GC_MINOR=0`, a larger `SPINEL_GC_THRESHOLD_KB`)
and `SPINEL_SCHED_POLL` were all within noise of the defaults or slower; and a
process-wide cache of route keys behind a `Mutex` stalled requests for
seconds with `SPINEL_WORKERS=2` (the two-core benchmark failed about one run
in two), so the key is remembered per request instead
([spikes/NOTES.md](../spikes/NOTES.md) rules 56 and 57).

Measured and left out: reading a request without parking the fiber when its
bytes are already there (a zero-timeout `wait_readable` before the real one,
with a cap so one client cannot hold the worker). Each park is a hand-off to
the scheduler's monitor thread and back, about 16 `futex` calls per request,
but with wrk's 16 connections the next request is never in yet when the fiber
comes back (`futex` and `epoll_wait` per request did not move; only an extra
`poll` appeared), and a plain blocking `readpartial` would hold the only
worker against the other connections ([NOTES](../spikes/NOTES.md) rule 20). A
`Static` that lists `public/` once and keeps the
small files in memory serves `GET /style.css` about 19% faster (17,060 to
20,370 req/s), but changes nothing measurable for the pages (the 3 `stat`
calls it saves are lost in the run-to-run spread of 5 to 8%), and a file
added to `public/` after the start would not be served until a restart, so
`Static` still looks at the disk on every request. Deferring the datetime
columns' parsing and sharing the environment between a partial and its
caller (instead of `env.dup`) were tried as upper bounds, by removing the
work altogether: +1.5% on the list, +0.6% on the article page, within the
spread, so neither was built.

Measured back to back on the same data, 16 connections, the averages of two
runs (`before` is a binary built from the commit before these changes, `after`
the final one, on the 2.80 GHz host of the recorded run; the VM runs the same
binary 10 to 15% apart from one run to the next):

| req/s | `GET /articles` | `GET /articles/1` | `POST` comment | `POST`, 2 cores, `SPINEL_WORKERS=2` |
| --- | --: | --: | --: | --: |
| Before | 1,064 | 1,154 | 1,275 | 1,114 (p99 59 ms) |
| After | 2,745 (2.6x) | 2,508 (2.2x) | 1,535 (1.2x) | 2,165 (1.9x, p99 20 ms) |
| After, with jemalloc | 3,359 (3.2x) | 3,040 (2.6x) | | |

The one-core POST moves least: its time is in SQLite's write and the
redirect, not in the code these changes touched.

An article page now allocates about 360 Strings, from about 1,100 at the first
run. What is left is spread over many sites at one or two Strings per comment
each (URLs, form tags, the rows themselves), and the collector and the thread
switches it causes (about a sixth of the time on one core) are still the
largest costs: that is Spinel's runtime rather than a function of the
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

Recorded 2026-10-09 at commit 0bb5cb8: Intel(R) Xeon(R) Processor @ 2.80GHz, 4 CPUs, 15.7 GB, Ubuntu 24.04.5 LTS (Linux 6.18.44-fc-v80).

| | CyberTrain | Rails |
| --- | --- | --- |
| Version | cybertrain 0.2.1, spinel 112bae85c1a2 (2026.09.12) | Rails 8.1.4, Puma 8.0.2, sqlite3 gem 2.9.6 |
| Runtime | native binary (cc 13.3.0, `-O2`), system SQLite 3.45.1 | ruby 3.4.6, YJIT on, SQLite 3.53.2 (the gem's own) |

### One CPU core, system malloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,286 | 461 | 5.0x | 0.38 / 1.27 ms | 1.92 / 5.12 ms |
| GET /articles (30 articles) | 16 | 2,641 | 468 | 5.6x | 5.83 / 9.85 ms | 33.1 / 64.2 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,132 | 198 | 10.8x | 0.42 / 1.23 ms | 4.74 / 8.99 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,450 | 201 | 12.2x | 6.32 / 10.8 ms | 73.8 / 262.9 ms |
| GET /style.css (public/) | 1 | 10,696 | 4,566 | 2.3x | 0.09 / 0.39 ms | 0.18 / 1.51 ms |
| GET /style.css (public/) | 16 | 13,300 | 5,127 | 2.6x | 1.18 / 2.06 ms | 2.94 / 8.84 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,549 | 351 | 4.4x | 0.58 / 1.79 ms | 2.60 / 7.81 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,507 | 390 | 3.9x | 10.1 / 18.8 ms | 38.3 / 84.5 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 9.3 MB | 111.5 MB |
| After the load runs | 10.6 MB | 125.9 MB |
| After the load runs (PSS) | 8.8 MB | 121.0 MB |

### Two CPU cores, system malloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,007 | 470 | 4.3x | 0.41 / 1.78 ms | 1.91 / 4.90 ms |
| GET /articles (30 articles) | 16 | 3,289 | 1,036 | 3.2x | 5.58 / 13.2 ms | 15.4 / 30.1 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,893 | 223 | 8.5x | 0.48 / 1.27 ms | 4.20 / 8.48 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,662 | 486 | 5.5x | 7.36 / 16.7 ms | 30.2 / 178.7 ms |
| GET /style.css (public/) | 1 | 10,411 | 3,771 | 2.8x | 0.08 / 0.86 ms | 0.23 / 1.60 ms |
| GET /style.css (public/) | 16 | 20,589 | 10,311 | 2.0x | 0.87 / 3.47 ms | 1.40 / 5.43 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,388 | 467 | 3.0x | 0.61 / 3.31 ms | 1.92 / 5.70 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,379 | 870 | 2.7x | 7.77 / 17.6 ms | 17.5 / 38.9 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 10.3 MB | 291.8 MB |
| After the load runs | 12.0 MB | 331.4 MB |
| After the load runs (PSS) | 10.2 MB | 249.1 MB |

### One CPU core, jemalloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 3,034 | 561 | 5.4x | 0.31 / 0.74 ms | 1.60 / 3.69 ms |
| GET /articles (30 articles) | 16 | 3,589 | 540 | 6.6x | 4.28 / 7.27 ms | 28.8 / 44.8 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,821 | 248 | 11.4x | 0.34 / 0.71 ms | 3.77 / 7.53 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,217 | 220 | 14.6x | 4.77 / 8.14 ms | 65.7 / 224.6 ms |
| GET /style.css (public/) | 1 | 11,432 | 4,463 | 2.6x | 0.08 / 0.32 ms | 0.20 / 1.48 ms |
| GET /style.css (public/) | 16 | 14,658 | 5,254 | 2.8x | 1.06 / 1.82 ms | 2.87 / 8.11 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,892 | 434 | 4.4x | 0.49 / 1.60 ms | 2.03 / 7.05 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,983 | 436 | 4.5x | 7.64 / 35.0 ms | 33.6 / 74.0 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 12.0 MB | 108.1 MB |
| After the load runs | 13.3 MB | 119.9 MB |
| After the load runs (PSS) | 10.4 MB | 114.1 MB |

### Two CPU cores, jemalloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,455 | 424 | 5.8x | 0.35 / 1.31 ms | 2.11 / 5.27 ms |
| GET /articles (30 articles) | 16 | 4,155 | 995 | 4.2x | 4.46 / 11.0 ms | 15.3 / 30.2 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,288 | 192 | 11.9x | 0.42 / 1.76 ms | 4.84 / 9.65 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,329 | 437 | 7.6x | 5.60 / 13.8 ms | 33.1 / 199.7 ms |
| GET /style.css (public/) | 1 | 10,178 | 3,387 | 3.0x | 0.09 / 0.63 ms | 0.26 / 1.76 ms |
| GET /style.css (public/) | 16 | 22,055 | 10,227 | 2.2x | 0.84 / 3.86 ms | 1.42 / 5.14 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,522 | 392 | 3.9x | 0.59 / 2.08 ms | 2.31 / 7.66 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,369 | 819 | 2.9x | 8.03 / 17.7 ms | 18.1 / 41.2 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 13.5 MB | 287.5 MB |
| After the load runs | 15.1 MB | 313.2 MB |
| After the load runs (PSS) | 12.3 MB | 222.5 MB |

| Startup (5 boots, median) | CyberTrain | Rails |
| --- | --: | --: |
| Spawn to first 200 for `GET /` | 0.016 s | 1.299 s |
| RSS then | 8.4 MB | 87.1 MB |

| What the server needs | CyberTrain | Rails |
| --- | --: | --: |
| The application | 2.5 MB binary (`dist/blog`) | 0.06 MB of source |
| Gems | none | 58.3 MB (69 gems) |
| Ruby | none | 50.5 MB |
| Total | 2.5 MB | 108.8 MB |
| Shared libraries | libm.so.6, libcrypt.so.1, libsqlite3.so.0, libc.so.6, /lib64/ld-linux-x86-64.so.2 | (Ruby's own, and the gems' native extensions) |

`cybertrain build` took 173 s.

## Reading the results

- **One core: 2.6 to 12.2 times the requests** (2.8 to 14.6 with jemalloc in
  both). The gap is widest on the article page, the request with the most view
  work: 10 partials and 12 forms, each with a CSRF token (a separately signed one
  per form in Rails). CyberTrain renders the list and the article page in about
  the same time; Rails takes twice as long for the article as for the list.
- **Latency.** One request at a time, CyberTrain answers the pages in 0.4 to
  0.6 ms (median) and Rails in 1.9 to 4.7 ms. With 16 connections on one core,
  CyberTrain's 99th percentile is 10 to 19 ms against 64 to 263 ms for the
  dynamic pages; on two cores 13 to 18 ms against 30 to 179 ms.
- **Two cores.** Puma's second worker process doubles Rails (2.0 to 2.4 times
  its one-core rate). `SPINEL_WORKERS=2` gives CyberTrain 9 to 25% more on the
  pages, 58% on the POST and 55% on the static file: less than a whole second
  process, so the lead narrows to 2.0 to 5.5 times. `SPINEL_WORKERS` stays 1 by
  default; on a server with more than one core, set it to the core count
  ([spikes/NOTES.md](../spikes/NOTES.md) rule 22 has the measurements).
- **jemalloc.** It gives CyberTrain 1.3 to 1.4 times on the three dynamic requests
  and 1.1 on the static file, on one core, and Rails up to 1.15 times: CyberTrain spends more of its time in malloc, though less than
  before the allocation cuts above (1.2 to 1.5 times then).
- **Memory.** One CyberTrain process serving 16 connections stays near 11 MB
  (13 MB with jemalloc). One Puma process with Rails loaded is 125 MB after the
  load; two workers are 331 MB.
- **Startup.** The binary answers its first request 0.016 s after it is
  spawned; Rails takes 1.3 s with bootsnap's cache warm.
- **Size.** The server needs one 2.5 MB file, which links libc and the
  system SQLite (and libjemalloc when chosen), against Ruby, 69 gems and the
  app: 109 MB.
- **What it costs.** The binary has to be built: `cybertrain build` took
  173 s on this machine (183 s on 2026-10-07, 137 to 152 s earlier on
  2026-10-08: the VM's speed varies), and
  every Ruby change needs a rebuild (`cybertrain server` does it for you in
  development), where Rails runs its source as it is. And the comparison covers
  only the slice of Rails both apps use: CyberTrain has no jobs, mailers,
  Action Cable, asset pipeline or i18n, and its ORM and router are smaller (see
  "Differences from Rails" in the [README](../README.md#differences-from-rails)).
- **The machine.** It is a shared cloud VM and not the same host from day to
  day: the runs of 2026-10-07 and 2026-10-08 were on a 2.10 GHz Xeon, the run
  of 2026-10-09 on a 2.80 GHz one, and Rails, unchanged, moved by 20 to 25%
  between the first two. Compare numbers within one run, not across runs. The
  before/after table above was measured in one session.
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
