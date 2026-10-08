# Benchmark: the blog, CyberTrain vs Rails

[examples/blog](../examples/blog) is the Rails Guides' "Getting Started"
blog built on CyberTrain. [bench/rails_blog](../bench/rails_blog) is the same
blog written in Rails 8.1. [bench/run](../bench/run) builds both, runs each in
production mode on the same machine and loads them with the same requests;
[bench/report](../bench/report) turns its JSON into the tables below. The
recorded run is [bench/results/2026-10-08.json](../bench/results/2026-10-08.json); the first one,
before the speedups described below, is [2026-10-07.json](../bench/results/2026-10-07.json).

On one CPU core, CyberTrain serves 3.0 to 9.7 times the requests per second
of Rails 8.1 (YJIT, Puma) for the same pages, answers a single page in 0.4 to
0.6 ms against 1.8 to 3.8 ms, uses a twelfth of the memory, starts in 0.02 s
against 1.2 s, and deploys as one 2.5 MB file against 109 MB of Ruby, gems and
source. With jemalloc in both, it is 2.9 to 12.1 times on one core. A second
core helps Rails more (Puma adds a whole process, which doubles it; CyberTrain's
second worker thread adds 16 to 51%), so on two cores the lead is 2.3 to 5.7
times, and 2.4 to 7.0 with jemalloc. The price is a compile of about two
minutes.

| 16 connections, req/s | 1 core: CyberTrain | Rails | | 2 cores: CyberTrain | Rails | |
| --- | --: | --: | --: | --: | --: | --: |
| `GET /articles` | 2,724 | 501 | 5.4x | 3,460 | 1,012 | 3.4x |
| `GET /articles/1` | 2,421 | 249 | 9.7x | 2,816 | 498 | 5.7x |
| `POST /articles/2/comments` | 1,659 | 406 | 4.1x | 2,504 | 758 | 3.3x |
| `GET /style.css` | 17,956 | 6,054 | 3.0x | 26,814 | 11,725 | 2.3x |
| *with jemalloc in both:* | | | | | | |
| `GET /articles` | 3,495 | 521 | 6.7x | 4,277 | 1,033 | 4.1x |
| `GET /articles/1` | 3,085 | 256 | 12.1x | 3,614 | 515 | 7.0x |
| `POST /articles/2/comments` | 1,844 | 436 | 4.2x | 2,476 | 770 | 3.2x |
| `GET /style.css` | 18,892 | 6,565 | 2.9x | 29,219 | 12,006 | 2.4x |

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

Measured back to back on the same data, 16 connections, the averages of two
runs (`before` is a binary built from the commit before these changes; the VM
runs the same binary 10 to 15% apart from one run to the next):

| req/s | `GET /articles` | `GET /articles/1` | `POST` comment | `POST`, 2 cores, `SPINEL_WORKERS=2` |
| --- | --: | --: | --: | --: |
| Before | 1,030 | 1,110 | 1,404 | 1,154 (p99 59 ms) |
| After | 2,794 (2.7x) | 2,537 (2.3x) | 1,705 (1.2x) | 2,511 (2.2x, p99 31 ms) |
| After, with jemalloc | 3,331 (3.2x) | 2,927 (2.6x) | | |

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

Recorded 2026-10-08 at commit 12613d1: Intel(R) Xeon(R) Processor @ 2.10GHz, 4 CPUs, 15.7 GB, Ubuntu 24.04.5 LTS (Linux 6.18.44-fc-v80).

| | CyberTrain | Rails |
| --- | --- | --- |
| Version | cybertrain 0.2.1, spinel 112bae85c1a2 (2026.09.12) | Rails 8.1.4, Puma 8.0.2, sqlite3 gem 2.9.6 |
| Runtime | native binary (cc 13.3.0, `-O2`), system SQLite 3.45.1 | ruby 3.4.6, YJIT on, SQLite 3.53.2 (the gem's own) |

### One CPU core, system malloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,188 | 515 | 4.3x | 0.41 / 2.67 ms | 1.75 / 4.78 ms |
| GET /articles (30 articles) | 16 | 2,724 | 501 | 5.4x | 5.38 / 11.0 ms | 30.5 / 47.6 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,986 | 245 | 8.1x | 0.46 / 6.31 ms | 3.83 / 7.13 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,421 | 249 | 9.7x | 6.09 / 15.5 ms | 57.0 / 176.0 ms |
| GET /style.css (public/) | 1 | 13,883 | 5,265 | 2.6x | 0.06 / 0.52 ms | 0.16 / 1.83 ms |
| GET /style.css (public/) | 16 | 17,956 | 6,054 | 3.0x | 0.85 / 2.10 ms | 2.46 / 8.61 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,518 | 406 | 3.7x | 0.60 / 2.68 ms | 2.20 / 8.33 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,659 | 406 | 4.1x | 9.18 / 17.0 ms | 36.0 / 80.1 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 9.4 MB | 111.5 MB |
| After the load runs | 10.6 MB | 133.2 MB |
| After the load runs (PSS) | 8.7 MB | 128.3 MB |

### Two CPU cores, system malloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,229 | 446 | 5.0x | 0.39 / 1.53 ms | 2.07 / 4.71 ms |
| GET /articles (30 articles) | 16 | 3,460 | 1,012 | 3.4x | 5.61 / 12.0 ms | 15.4 / 27.4 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,016 | 242 | 8.3x | 0.46 / 1.71 ms | 3.87 / 7.76 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 2,816 | 498 | 5.7x | 6.37 / 14.0 ms | 29.1 / 140.2 ms |
| GET /style.css (public/) | 1 | 14,119 | 4,252 | 3.3x | 0.06 / 0.66 ms | 0.20 / 1.91 ms |
| GET /style.css (public/) | 16 | 26,814 | 11,725 | 2.3x | 0.67 / 3.14 ms | 1.21 / 5.45 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,523 | 382 | 4.0x | 0.58 / 2.37 ms | 2.42 / 9.71 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,504 | 758 | 3.3x | 7.35 / 17.4 ms | 19.8 / 44.0 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 10.5 MB | 292.5 MB |
| After the load runs | 11.9 MB | 334.0 MB |
| After the load runs (PSS) | 10.0 MB | 251.9 MB |

### One CPU core, jemalloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,811 | 484 | 5.8x | 0.32 / 1.85 ms | 1.85 / 5.07 ms |
| GET /articles (30 articles) | 16 | 3,495 | 521 | 6.7x | 4.32 / 8.34 ms | 29.3 / 48.0 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,713 | 245 | 11.1x | 0.34 / 1.52 ms | 3.75 / 7.41 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,085 | 256 | 12.1x | 4.81 / 10.9 ms | 55.6 / 152.1 ms |
| GET /style.css (public/) | 1 | 14,890 | 5,320 | 2.8x | 0.06 / 0.65 ms | 0.16 / 1.47 ms |
| GET /style.css (public/) | 16 | 18,892 | 6,565 | 2.9x | 0.80 / 1.95 ms | 2.28 / 7.14 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,652 | 441 | 3.7x | 0.56 / 2.20 ms | 2.07 / 7.18 ms |
| POST /articles/2/comments (insert, 303) | 16 | 1,844 | 436 | 4.2x | 8.01 / 17.7 ms | 34.0 / 74.6 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 12.0 MB | 108.5 MB |
| After the load runs | 13.3 MB | 118.1 MB |
| After the load runs (PSS) | 10.5 MB | 112.3 MB |

### Two CPU cores, jemalloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles) | 1 | 2,425 | 443 | 5.5x | 0.37 / 1.80 ms | 2.07 / 5.82 ms |
| GET /articles (30 articles) | 16 | 4,277 | 1,033 | 4.1x | 4.45 / 9.87 ms | 14.6 / 27.4 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 2,408 | 227 | 10.6x | 0.39 / 1.70 ms | 4.12 / 9.36 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 3,614 | 515 | 7.0x | 5.21 / 12.3 ms | 26.7 / 119.0 ms |
| GET /style.css (public/) | 1 | 14,500 | 4,311 | 3.4x | 0.06 / 0.54 ms | 0.20 / 2.26 ms |
| GET /style.css (public/) | 16 | 29,219 | 12,006 | 2.4x | 0.57 / 2.70 ms | 1.17 / 6.08 ms |
| POST /articles/2/comments (insert, 303) | 1 | 1,521 | 402 | 3.8x | 0.58 / 2.53 ms | 2.30 / 6.23 ms |
| POST /articles/2/comments (insert, 303) | 16 | 2,476 | 770 | 3.2x | 7.53 / 18.0 ms | 19.4 / 42.8 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 13.1 MB | 288.1 MB |
| After the load runs | 14.8 MB | 312.2 MB |
| After the load runs (PSS) | 11.9 MB | 220.5 MB |

| Startup (5 boots, median) | CyberTrain | Rails |
| --- | --: | --: |
| Spawn to first 200 for `GET /` | 0.015 s | 1.154 s |
| RSS then | 8.4 MB | 87.3 MB |

| What the server needs | CyberTrain | Rails |
| --- | --: | --: |
| The application | 2.5 MB binary (`dist/blog`) | 0.06 MB of source |
| Gems | none | 58.3 MB (69 gems) |
| Ruby | none | 50.5 MB |
| Total | 2.5 MB | 108.8 MB |
| Shared libraries | libm.so.6, libcrypt.so.1, libsqlite3.so.0, libc.so.6, /lib64/ld-linux-x86-64.so.2 | (Ruby's own, and the gems' native extensions) |

`cybertrain build` took 152 s.

## Reading the results

- **One core: 3.0 to 9.7 times the requests** (2.9 to 12.1 with jemalloc in
  both). The gap is widest on the article page, the request with the most view
  work: 10 partials and 12 forms, each with a CSRF token (a separately signed one
  per form in Rails). CyberTrain renders the list and the article page in about
  the same time; Rails takes twice as long for the article as for the list.
- **Latency.** One request at a time, CyberTrain answers the pages in 0.4 to
  0.6 ms (median) and Rails in 1.8 to 3.8 ms. With 16 connections on one core,
  CyberTrain's 99th percentile is 11 to 17 ms against 48 to 176 ms for the
  dynamic pages; on two cores 12 to 17 ms against 27 to 140 ms.
- **Two cores.** Puma's second worker process doubles Rails (1.9 to 2.0 times
  its one-core rate). `SPINEL_WORKERS=2` gives CyberTrain 16 to 27% more on the
  pages, 51% on the POST and 49% on the static file: less than a whole second
  process, so the lead narrows to 2.3 to 5.7 times. `SPINEL_WORKERS` stays 1 by
  default; on a server with more than one core, set it to the core count
  ([spikes/NOTES.md](../spikes/NOTES.md) rule 22 has the measurements).
- **jemalloc.** It gives CyberTrain 1.3 times on the two pages that render
  views, 1.1 on the POST and 1.05 on the static file, on one core, and Rails up
  to 1.08 times: CyberTrain spends more of its time in malloc, though less than
  before the allocation cuts above (1.2 to 1.5 times then).
- **Memory.** One CyberTrain process serving 16 connections stays near 11 MB
  (13 MB with jemalloc). One Puma process with Rails loaded is 133 MB after the
  load; two workers are 334 MB.
- **Startup.** The binary answers its first request 0.016 s after it is
  spawned; Rails takes 1.2 s with bootsnap's cache warm.
- **Size.** The server needs one 2.5 MB file, which links libc and the
  system SQLite (and libjemalloc when chosen), against Ruby, 69 gems and the
  app: 109 MB.
- **What it costs.** The binary has to be built: `cybertrain build` took
  152 s on this machine (183 s on 2026-10-07, 137 s earlier on 2026-10-08: the
  VM's speed varies), and
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
