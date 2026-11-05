# Benchmark: the blog, CyberTrain vs Rails

[examples/blog](../examples/blog) is the Rails Guides' "Getting Started"
blog built on CyberTrain. [bench/rails_blog](../bench/rails_blog) is the same
blog written in Rails 8.1. [bench/run](../bench/run) builds both, runs each in
production mode on the same machine and loads them with the same requests;
[bench/report](../bench/report) turns its JSON into the tables below. The
recorded run is [bench/results/2026-11-05.json](../bench/results/2026-11-05.json)
(cybertrain 0.4.1, Spinel 2026.11.04.7026); the one before it,
[2026-10-09.json](../bench/results/2026-10-09.json) (cybertrain 0.2.1, Spinel
2026.09.12), is the "after" of the speedups described below, and the first,
before them, is [2026-10-07.json](../bench/results/2026-10-07.json).

On one CPU core, CyberTrain serves 2.2 to 8.8 times the requests per second
of Rails 8.1 (YJIT, Puma) for the same pages, answers a single request in 0.3
to 0.4 ms against 1.3 to 2.6 ms, uses a tenth of the memory, starts in 0.015 s
against 0.75 s, and deploys as one 4.0 MB file against 121 MB of Ruby, gems
and source. With jemalloc in both, it is 2.1 to 8.5 times on one core. A
second core helps Rails more (Puma adds a whole process, which doubles it;
CyberTrain's second worker thread adds 0 to 19% here, for a reason in Spinel's
worker count that "Two cores" below explains), so on two cores the lead is
1.1 to 4.4 times, with jemalloc or without. The price is a compile of about a
minute (50 s here).

| 16 connections, req/s | 1 core: CyberTrain | Rails | | 2 cores: CyberTrain | Rails | |
| --- | --: | --: | --: | --: | --: | --: |
| `GET /articles` | 3,218 | 709 | 4.5x | 3,294 | 1,453 | 2.3x |
| `GET /articles/1` | 3,201 | 364 | 8.8x | 3,211 | 735 | 4.4x |
| `POST /articles/2/comments` | 2,081 | 576 | 3.6x | 2,478 | 1,089 | 2.3x |
| `GET /style.css` | 22,112 | 10,144 | 2.2x | 22,735 | 20,105 | 1.1x |
| *with jemalloc in both:* | | | | | | |
| `GET /articles` | 3,247 | 732 | 4.4x | 3,337 | 1,390 | 2.4x |
| `GET /articles/1` | 3,106 | 364 | 8.5x | 3,241 | 741 | 4.4x |
| `POST /articles/2/comments` | 2,446 | 568 | 4.3x | 2,456 | 1,035 | 2.4x |
| `GET /style.css` | 22,026 | 10,273 | 2.1x | 22,342 | 19,604 | 1.1x |

## How CyberTrain got faster

The first recorded run (2026-10-07) had CyberTrain at 1,026 and 1,064 requests
a second for the list and the article page on one core. Profiling it (perf with
DWARF call graphs, and Spinel's `SPINEL_ALLOC_REPORT`) showed no single hot
spot: about a fifth of the time in malloc and free, a fifth in the garbage
collector, a sixth in the kernel switching between the runtime's threads (which
the collector's stop-the-world drives), and the rest spread over the template
interpreter. An article page allocated about 1,100 Strings. What changed:

- **Typed byte loops.** `Html.escape` (every `<%= %>`), `Cast.parse_time`
  (every datetime column of every row) and the new `Query.plain?`
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
- **DATETIME columns as epoch seconds.** Model rows (`Relation#rows`, `reload`)
  read a column declared DATETIME through `Connection#execute_models`: a C
  function (`ffi_source`) parses the text SQLite already holds to UTC epoch
  seconds, so no Ruby String is made for it, and `Cast.time_or_nil` turns the
  Integer into a Time. The declared type and the column names are looked up
  once per SQL text and remembered with the prepared statement (they are read
  after the first `step`, so a column added under a running connection is
  seen). Text that is not a timestamp stays text and `Connection#execute` is
  unchanged. The list page went from 585 to 525 objects.
- **A crash the speedups exposed.** Making the helpers single interpolations
  put more `SafeString.new(<new String>)` calls in the render path, and
  Spinel's generated `new` allocates the object before it roots its argument:
  a collection inside it freed the String, and the seeding runs of `bench/run`
  crashed 4 to 17% of the time (a use-after-free, found with an
  AddressSanitizer build). `SafeString.of` goes through an ordinary method,
  whose parameters are rooted on entry, and the template lexer and parser bind
  the Strings they pass to locals: 0 of 150 runs crash
  ([spikes/NOTES.md](../spikes/NOTES.md) rule 58).
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
with a cap so one client cannot hold the worker). On 2026.09.12 each park
was a hand-off to the scheduler's monitor thread and back, about 16 `futex`
calls per request (on 2026.10.27.7020 the park makes none, and the 2
`futex` per request left are the collector's and the monitor's: see
[spinel-feedback.md](spinel-feedback.md) 4), but with wrk's 16 connections
the next request is never in yet when the fiber comes back (`futex` and
`epoll_wait` per request did not move; only an extra `poll` appeared), and a
plain blocking `readpartial` would hold the only worker against the other
connections ([NOTES](../spikes/NOTES.md) rule 20). A
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

What is left, with the measurement behind each candidate, is in
[performance-next.md](performance-next.md).

An article page now allocates about 520 objects (300 of them Strings), from
about 1,100 Strings at the first run. What is left is spread over many sites at
one or two Strings per comment
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

Recorded 2026-11-05 at commit 0d8a942: Intel(R) Xeon(R) Processor @ 2.30GHz, 4 CPUs, 15.7 GB, Ubuntu 24.04.5 LTS (Linux 6.18.44-fc-v236).

| | CyberTrain | Rails |
| --- | --- | --- |
| Version | cybertrain 0.4.1, spinel 2026.11.04.7026 (a2d06115) | Rails 8.1.4, Puma 8.0.2, sqlite3 gem 2.9.6 |
| Runtime | native binary (cc 13.3.0, `-O2`), system SQLite 3.45.1 | ruby 3.4.6, YJIT on, SQLite 3.53.2 (the gem's own) |

### One CPU core, system malloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,746 | 703 | 3.9x | 0.32 / 0.82 ms | 1.28 / 2.68 ms |
| GET /articles (30 articles) | 16 | 3,218 | 709 | 4.5x | 4.87 / 8.30 ms | 22.1 / 32.8 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,739 | 366 | 7.5x | 0.32 / 0.84 ms | 2.62 / 4.60 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,201 | 364 | 8.8x | 4.93 / 8.44 ms | 41.9 / 70.4 ms |
| GET /style.css (public/) | 1 | 17,166 | 9,000 | 1.9x | 0.05 / 0.20 ms | 0.09 / 1.06 ms |
| GET /style.css (public/) | 16 | 22,112 | 10,144 | 2.2x | 0.72 / 1.19 ms | 1.48 / 4.75 ms |
| POST /articles/2/comments (insert, 303) | 1 | 2,147 | 595 | 3.6x | 0.44 / 1.38 ms | 1.54 / 4.73 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,081 | 576 | 3.6x | 7.38 / 12.1 ms | 25.6 / 55.8 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 12.8 MB | 111.8 MB |
| After the load runs | 13.9 MB | 132.8 MB |
| After the load runs (PSS) | 12.0 MB | 130.6 MB |

### Two CPU cores, system malloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,854 | 687 | 4.2x | 0.30 / 0.80 ms | 1.32 / 3.17 ms |
| GET /articles (30 articles) | 16 | 3,294 | 1,453 | 2.3x | 4.75 / 8.20 ms | 11.0 / 20.0 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,704 | 356 | 7.6x | 0.32 / 0.81 ms | 2.69 / 5.18 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,211 | 735 | 4.4x | 4.82 / 8.18 ms | 21.1 / 41.3 ms |
| GET /style.css (public/) | 1 | 19,668 | 6,753 | 2.9x | 0.05 / 0.22 ms | 0.12 / 1.24 ms |
| GET /style.css (public/) | 16 | 22,735 | 20,105 | 1.1x | 0.72 / 1.36 ms | 0.71 / 2.92 ms |
| POST /articles/2/comments (insert, 303) | 1 | 2,298 | 588 | 3.9x | 0.41 / 1.24 ms | 1.57 / 4.63 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,478 | 1,089 | 2.3x | 6.21 / 11.4 ms | 14.0 / 30.6 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 13.9 MB | 294.0 MB |
| After the load runs | 16.0 MB | 332.7 MB |
| After the load runs (PSS) | 14.1 MB | 253.9 MB |

### One CPU core, jemalloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,802 | 738 | 3.8x | 0.32 / 0.82 ms | 1.22 / 2.80 ms |
| GET /articles (30 articles) | 16 | 3,247 | 732 | 4.4x | 4.80 / 8.00 ms | 21.3 / 32.0 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,887 | 366 | 7.9x | 0.30 / 0.73 ms | 2.53 / 5.01 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,106 | 364 | 8.5x | 5.03 / 8.49 ms | 42.0 / 68.7 ms |
| GET /style.css (public/) | 1 | 16,258 | 8,516 | 1.9x | 0.06 / 0.23 ms | 0.10 / 1.11 ms |
| GET /style.css (public/) | 16 | 22,026 | 10,273 | 2.1x | 0.72 / 1.27 ms | 1.47 / 4.25 ms |
| POST /articles/2/comments (insert, 303) | 1 | 2,281 | 578 | 3.9x | 0.41 / 1.12 ms | 1.56 / 5.38 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,446 | 568 | 4.3x | 6.27 / 12.8 ms | 26.1 / 56.0 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 15.4 MB | 109.9 MB |
| After the load runs | 17.4 MB | 122.5 MB |
| After the load runs (PSS) | 14.5 MB | 119.5 MB |

### Two CPU cores, jemalloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,716 | 672 | 4.0x | 0.32 / 0.82 ms | 1.33 / 3.41 ms |
| GET /articles (30 articles) | 16 | 3,337 | 1,390 | 2.4x | 4.61 / 6.50 ms | 11.0 / 20.8 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,783 | 363 | 7.7x | 0.31 / 0.86 ms | 2.56 / 5.45 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,241 | 741 | 4.4x | 4.77 / 8.75 ms | 20.4 / 43.9 ms |
| GET /style.css (public/) | 1 | 17,667 | 6,556 | 2.7x | 0.05 / 0.18 ms | 0.13 / 1.23 ms |
| GET /style.css (public/) | 16 | 22,342 | 19,604 | 1.1x | 0.73 / 1.26 ms | 0.73 / 3.13 ms |
| POST /articles/2/comments (insert, 303) | 1 | 2,160 | 555 | 3.9x | 0.42 / 2.02 ms | 1.63 / 5.59 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,456 | 1,035 | 2.4x | 6.24 / 11.1 ms | 14.2 / 32.1 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 16.6 MB | 289.4 MB |
| After the load runs | 18.3 MB | 312.7 MB |
| After the load runs (PSS) | 15.4 MB | 222.5 MB |

| Startup (5 boots, median) | CyberTrain | Rails |
| --- | --: | --: |
| Spawn to first 200 for `GET /` | 0.015 s | 0.752 s |
| RSS then | 12.3 MB | 87.5 MB |

| What the server needs | CyberTrain | Rails |
| --- | --: | --: |
| The application | 4.0 MB binary (`dist/blog`) | 0.06 MB of source |
| Gems | none | 58.3 MB (69 gems) |
| Ruby | none | 62.4 MB |
| Total | 4.0 MB | 120.7 MB |
| Shared libraries | libm.so.6, libz.so.1, libsqlite3.so.0, libc.so.6, /lib64/ld-linux-x86-64.so.2 | (Ruby's own, and the gems' native extensions) |

`cybertrain build` took 50 s.

## Reading the results

- **One core: 2.2 to 8.8 times the requests** (2.1 to 8.5 with jemalloc in
  both). The gap is widest on the article page, the request with the most view
  work: 10 partials and 12 forms, each with a CSRF token (a separately signed one
  per form in Rails). CyberTrain renders the list and the article page in the
  same time (3,218 and 3,201 req/s); Rails takes twice as long for the article
  as for the list.
- **Latency.** One request at a time, CyberTrain answers the pages and the POST
  in 0.3 to 0.4 ms (median) and Rails in 1.3 to 2.6 ms. With 16 connections on
  one core, CyberTrain's 99th percentile is 8 to 12 ms against 33 to 70 ms for
  the dynamic requests; on two cores 8 to 11 ms against 20 to 41 ms.
- **Two cores.** Puma's second worker process doubles Rails (1.9 to 2.0 times
  its one-core rate). `SPINEL_WORKERS=2` gives CyberTrain 0 to 2% more on the
  pages, 19% on the POST and 3% on the static file, so the lead narrows to
  1.1 to 4.4 times. That is less than on 2026-10-09 (9 to 25% on the pages,
  58% on the POST). The cause is in how this Spinel counts workers, not in
  CyberTrain, SQLite or the collector. Since 2026.11.04.7026, an explicit
  `SPINEL_WORKERS=N` counts the main thread among the N and starts N-1 helper
  workers (2026.09.12 started N beside main). Main runs no request threads
  while helpers exist, and in the server it only waits, so `SPINEL_WORKERS=2`
  served every request from one OS thread. A check after the recorded run
  (`dist/blog` on CPUs 0-1, `wrk -t2 -c16 -d8s` on `GET /articles` from CPUs
  2-3) found one thread using 7.85 of the process's 8 CPU-seconds and main
  0.15. Spinel's own scheduler statistics (`SPINEL_SCHED_STATS=2`) showed one
  busy worker with 14 threads queued behind it, no thread waiting on a
  `Mutex`, and the collector's sweep threads at 0.07 s.
  [saeki-mototsune/CyberTrain#128](https://github.com/saeki-mototsune/CyberTrain/pull/128)
  makes the server ask Spinel for one more worker than `SPINEL_WORKERS` says.
  Measured in one later session (medians of 3 runs of 8 s, on another host),
  2 workers over 1 went from +10%, -3%, +2% and +4% (list, article, static
  file, POST) to +24%, +44%, +22% and +44%. The two-core rows above predate
  that change and were not re-recorded. `SPINEL_WORKERS` stays 1 by default
  ([spikes/NOTES.md](../spikes/NOTES.md) rule 22 has the measurements).
  The static file tops out near 22,000 req/s for CyberTrain on one core and on
  two in this run, and Rails reaches 20,000 on two. That looked like the limit
  of wrk on its two CPUs, but in the later session CyberTrain's static file
  reached 22,500 (median) and 26,800 (one run) on two cores with the same wrk
  settings, so the 22,000 here more likely is CyberTrain's single worker
  than wrk.
- **jemalloc.** In this run it moves CyberTrain's pages by -3 to +1% and its
  POST by +18% on one core, and Rails by -1 to +3%: mostly within the spread,
  where on 2026-10-09 it gave CyberTrain 1.3 to 1.4 times on the dynamic
  requests.
- **Memory.** One CyberTrain process serving 16 connections stays near 14 MB
  (17 MB with jemalloc). One Puma process with Rails loaded is 133 MB after the
  load; two workers are 333 MB.
- **Startup.** The binary answers its first request 0.015 s after it is
  spawned; Rails takes 0.75 s with bootsnap's cache warm.
- **Size.** The server needs one 4.0 MB file, which links libc, zlib and the
  system SQLite (and libjemalloc when chosen), against Ruby, 69 gems and the
  app: 121 MB. The binary was 2.5 MB on 2026-10-09; the framework has grown
  since. The Ruby counted here is a different install of 3.4.6 (built with
  ruby-build) from the one counted then.
- **What it costs.** The binary has to be built: `cybertrain build` took
  50 s on this machine (173 s on 2026-10-09, with an older Spinel on another
  host), and every Ruby change needs a rebuild (`cybertrain server` does it
  for you in development), where Rails runs its source as it is. And the
  comparison covers only the slice of Rails both apps use: CyberTrain has no
  Action Cable, asset pipeline or i18n, and its ORM and router are smaller (see
  [Differences from Rails](guide/how-it-works.md#differences-from-rails)).
- **The machine.** It is a shared cloud VM and not the same host from day to
  day: the runs of 2026-10-07 and 2026-10-08 were on a 2.10 GHz Xeon, the run
  of 2026-10-09 on a 2.80 GHz one, the run of 2026-11-05 on a 2.30 GHz one.
  Rails, unchanged, did 468 req/s on the list on 2026-10-09 and 709 on
  2026-11-05. Compare numbers within one run, not across runs. The
  before/after table above was measured in one session.
- **Static files.** In production both apps would usually sit behind a proxy
  that serves `public/` itself ([deploy.en.md](deploy.en.md) puts Caddy in front),
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
