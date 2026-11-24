# Benchmark: the blog, CyberTrain vs Rails

[examples/blog](../examples/blog) is the Rails Guides' "Getting Started"
blog built on CyberTrain, grown since into a small application: sign-in, two
languages, a cache, jobs, live comments. [bench/rails_blog](../bench/rails_blog)
is the same blog written in Rails 8.1 with Rails 8's own defaults for each of
those ([What is compared](#what-is-compared)). [bench/run](../bench/run)
builds both, runs each in production mode on the same machine and loads them
with the same requests; [bench/report](../bench/report) turns its JSON into
the tables below. The recorded run is
[bench/results/2026-11-24.json](../bench/results/2026-11-24.json)
(cybertrain 0.4.2, Spinel 2026.11.23.7035), on a different machine from the
earlier runs and with both apps much bigger than they were then, so its
numbers are not comparable with theirs ([The apps today](#the-apps-today)).
The earlier runs stay in bench/results: [2026-11-05.json](../bench/results/2026-11-05.json)
(cybertrain 0.4.1, Spinel 2026.11.04.7026, the blog before sign-in),
[2026-10-09.json](../bench/results/2026-10-09.json) (cybertrain 0.2.1, Spinel
2026.09.12), the "after" of the speedups described below, and the first,
before them, [2026-10-07.json](../bench/results/2026-10-07.json).
bench/results also holds a run made earlier on 2026-11-24
([2026-11-24-first.json](../bench/results/2026-11-24-first.json), see
[Results](#results)), an earlier run of 0.2.1,
[2026-10-08.json](../bench/results/2026-10-08.json), and the results of a
check of the Spinel package 2026.10.09-7009 (edb9dd0) made on 2026-10-13
(`2026-10-13-spinel-ab.txt`, `2026-10-13-spinel-edb9dd0.json`;
[spinel-feedback.md](spinel-feedback.md) mentions that check); none of them
is tabulated here.

On one CPU core, CyberTrain serves 2.5 to 5.6 times the requests per second
of Rails 8.1 (YJIT, Puma) at 16 connections for the same pages, answers a
single request in 0.9 to 1.7 ms (median) against 4.6 to 6.2 ms, uses a sixth
of the memory (30 MB against 189 MB), starts in 0.04 s against 2.1 s, and
deploys as one 11.7 MB file against 114 MB of Ruby, gems and source. With
jemalloc in both, it is 2.1 to 5.7 times on one core. A second core helps
Rails more (Puma adds a whole process: 1.8 to 2.7 times its one-core rate on
the pages, while CyberTrain's second worker adds 37 to 55%), so on two cores
the lead is 1.2 to 4.3 times (1.7 to 4.7 with jemalloc). The comment POST is
CyberTrain's weak spot: on two cores it is 1.2 times Rails (1.7 with
jemalloc) and slower than on one core, and its 99th percentile is worse than
Rails' at one connection in every configuration and at 16 connections in
three of the four. The price is a compile of four and a half minutes
(271 s on this machine).

| 16 connections, req/s | 1 core: CyberTrain | Rails | | 2 cores: CyberTrain | Rails | |
| --- | --: | --: | --: | --: | --: | --: |
| `GET /articles` | 696 | 155 | 4.5x | 989 | 422 | 2.3x |
| `GET /articles/1` | 1,119 | 199 | 5.6x | 1,538 | 359 | 4.3x |
| `POST /articles/2/comments` | 417 | 98 | 4.3x | 274 | 221 | 1.2x |
| the digested stylesheet | 13,676 | 5,554 | 2.5x | 22,310 | 11,926 | 1.9x |
| *with jemalloc in both:* | | | | | | |
| `GET /articles` | 665 | 125 | 5.3x | 1,002 | 342 | 2.9x |
| `GET /articles/1` | 1,060 | 186 | 5.7x | 1,647 | 349 | 4.7x |
| `POST /articles/2/comments` | 418 | 122 | 3.4x | 360 | 218 | 1.7x |
| the digested stylesheet | 12,944 | 6,260 | 2.1x | 19,585 | 11,702 | 1.7x |

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
  went to 2,214 req/s, 1.5 times the one-core rate, p99 22 ms. (Since
  saeki-mototsune/CyberTrain#134 the wait for a statement is a green-thread
  `sleep` in Ruby, 100 us growing to 1 ms, so the lock holder can run on the
  same worker; the C handler only reports that SQLite asked to wait.
  design.md D10.)
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
the final one, on the 2.80 GHz host of the run of 2026-10-09; the VM runs the same
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

The two apps are the same application, and this section describes them as
they were at the run of 2026-11-24.
[bench/rails_blog/README.md](../bench/rails_blog/README.md) lists every
change from `rails new` and every difference left.

- **Same pages.** `bench/rails_blog/app/views/` follows examples/blog's: the
  layout (the language links, the sign-in link, the flash, the CSRF and CSP
  meta tags, the digested stylesheet, an import map), the article list (the
  number of articles, a date and order filter form, a comment count per
  article), the article page (the date in a `<time>`, the subscription to
  the article's stream, each comment with its author through an application
  helper and a delete button, the comment form). The HTML both apps send for
  an article page differs only in markup details: the tokens themselves,
  where `button_to` puts its hidden token field, `/>` against `>`, Rails'
  `accept-charset` on forms, the stream tag (`<turbo-stream-source>` over
  server-sent events against Action Cable's `<turbo-cable-stream-source>`)
  and the import map's pins (Turbo from jsDelivr against turbo-rails' own
  copy). A comment is a component in examples/blog and a partial in Rails.
- **Same code.** The routes, the controllers and the models are
  examples/blog's, in Rails' spelling: the validations (the title's
  uniqueness among them, a query on every save), `dependent: :destroy`, the
  list's `includes(:comments)` and its article count read from the cache
  for a minute, the locale picked from `?locale=`, a cookie or
  `Accept-Language`, a Content Security Policy with a fresh nonce on every
  response, and on a comment a job enqueued and the comment broadcast to the
  article's stream, rendered in the request, before the redirect.
- **Each framework's own way.** Signing in is `cybertrain generate
  authentication` against Rails 8's authentication generator; the
  stylesheet is digested by `cybertrain build` against Propshaft; the cache,
  the jobs and the stream messages are tables of examples/blog's one SQLite
  database against Solid Cache, Solid Queue and Solid Cable, Rails 8's
  defaults, each in its own SQLite file. examples/blog runs its jobs on a
  thread of the server process; Rails runs Solid Queue inside Puma in its
  `async` mode (threads of the Puma process), rather than in the three
  processes of the default `fork` mode, which the memory figures would
  count.
- **Same storage.** SQLite files in WAL mode, foreign keys on. CyberTrain
  links the system's SQLite (3.45.1 here); the sqlite3 gem brings its own
  (3.53.2).
- **Same defaults.** Neither app is tuned. CyberTrain runs `dist/blog` from
  `cybertrain build` (views embedded, digested assets in `dist/public/assets/`, production by default).
  Rails runs `bin/rails server` with `RAILS_ENV=production` after
  `bin/rails assets:precompile`: eager loading, YJIT (Rails 8 turns it on
  when the Ruby has it), Puma with its generated `config/puma.rb` (3
  threads). Both log every request at the `info` level to STDOUT, which
  `bench/run` sends to `/dev/null`.

What each framework does per request by default is still not identical, and
the numbers include that: both encrypt the session cookie (AES-256-GCM), but
Rails signs a separate CSRF token for each form (`per_form_csrf_tokens`) where
CyberTrain puts one token per session in every form, Rails computes an `ETag`
for every response (`Rack::ETag`, and the generated
`stale_when_importmap_changes`) behind a longer middleware stack (request id,
remote IP, security headers), and Rails asks Active Storage whether an
article has a cover (a query on the article page) where examples/blog reads
its own columns.

### The apps today

The run of 2026-11-05 compared the blog as it was then: articles and
comments, no users, a signed session, one language, `public/style.css`.
examples/blog has grown since (sign-in, an encrypted session, English and
Japanese, a CSP, the comment counts and the cached article count on the
list, a Turbo Stream subscription, a job and a broadcast on every comment, a
uniqueness validation, `dependent: :destroy`, a digested stylesheet, a cover
image), and before the run of 2026-11-24 `bench/rails_blog` was brought up
to it on everything a measured request does, as above. So the numbers below
measure a bigger application than those of 2026-11-05, in both frameworks,
and on another machine: they are not comparable with the earlier runs.

Left out of the Rails app, on no measured request: examples/blog's account
page, "keep me signed in", the idle timeout and the lockout after wrong
passwords, its first-run `/setup` page and `user` command, the jobs page and
its scheduled task (Solid Queue's generated `recurring.yml` is the nearest).
Both apps serve a cover image; neither is requested or seeded.

## Method

How the results below were measured.

- **Machine.** One cloud VM (details under Results). Each server is pinned
  with `taskset` to CPU 0 (the 1-CPU runs) or CPUs 0-1 (the 2-CPU runs); wrk
  is pinned to CPUs 2-3, so the load generator never takes the server's CPU.
  A shared cloud VM is noisy: repeated runs move by several
  percent, so read the ratios rather than the third digit. The recorded run
  started only once the machine was idle (a load average under 0.5 and no
  other process using a quarter of a CPU), and a sampler beside it saw no
  other busy process while it ran.
- **Workers.** On one CPU: CyberTrain `SPINEL_WORKERS=1` (its default) and
  Puma in single mode with 3 threads (Rails' default). On two CPUs:
  `SPINEL_WORKERS=2` and Puma with `WEB_CONCURRENCY=2` (two worker
  processes, 3 threads each). Each app runs its jobs in the server: a
  CyberTrain job thread; Solid Queue's threads in the Puma process (the
  master, in cluster mode).
- **malloc.** Each CPU configuration runs twice: with the system's malloc
  (glibc), which is what both frameworks get out of the box, and with
  jemalloc preloaded into both servers (`LD_PRELOAD`), which is what Rails'
  generated Dockerfile does in production and what `allocator = "jemalloc"`
  in an app's spin.toml does for CyberTrain (linking it measures the same as
  preloading it).
- **Data.** Each server starts on an empty database holding one user. It is
  seeded over HTTP through its own forms, as a browser would fill them in:
  the user signs in and writes 30 articles, then a visitor posts 10 comments
  on the first.
- **Requests.** `GET /articles` (the list: 30 articles, each with its comment
  count, the article count, the filter form), `GET /articles/1` (the
  article, its 10 comments and 12 forms: a `button_to` for the article and
  for each comment, and the comment form), the digested stylesheet
  `GET /assets/application-<digest>.css` (a static file, its path read from
  the list page each app serves) and `POST /articles/2/comments` (validates,
  inserts a comment, enqueues a job, broadcasts the comment, answers 303).
  Every request is the visitor's, carries the visitor's session cookie and a
  browser's `Accept` header (a plain form submission; Turbo would ask for a
  Turbo Stream), and the POST carries the comment form's CSRF token.
- **Load.** [wrk](https://github.com/wg/wrk) 4.1, keep-alive, 10 s per run:
  1 connection (one request at a time: the latency of a single request) and
  16 connections (2 wrk threads: throughput). Each endpoint gets 10 s of load
  at 16 connections that is not measured (YJIT compiles during it) just
  before its own runs, in the order above, so the GETs are measured on the
  seeded data and the POST, which adds thousands of comments, comes last.
  Each figure is the median of 3 runs. A run that sees a socket error or a
  status other than 2xx/3xx fails.
- **Memory.** `VmRSS` from `/proc`, summed over the server's processes
  (Puma's workers included), after seeding and after all the load runs;
  `Pss` too, which splits the pages processes share.
- **Startup.** From spawning the server to the first 200 for `GET /` (the
  list) on a fresh database holding only the user, 5 boots, median (Rails
  with a warm bootsnap cache).
- **What the server needs.** CyberTrain: `dist/blog`, one file that links
  against libc and the system SQLite. Rails: the app's source, the gems
  `bundle list` names outside the development and test groups, and the Ruby
  install without its gem directory (so the gems Ruby itself bundles are
  not counted for Rails).

## Results

Recorded 2026-11-24 at commit 7b77d370: Intel(R) Xeon(R) Processor @ 2.10GHz, 4 CPUs, 15.7 GB, Ubuntu 24.04.5 LTS (Linux 6.18.44-fc-v819).

The machine is not the one of the earlier runs: a 4-vCPU cloud VM (`nproc`
4) with an Intel(R) Xeon(R) Processor @ 2.10GHz (`/proc/cpuinfo` gives no
other model name), 15.7 GB, Linux 6.18.44-fc-v819; cybertrain 0.4.2 with
Spinel 2026.11.23.7035, against Rails 8.1.4.1 on Ruby 3.4.6 (YJIT, the
ruby/ruby-builder build) with Puma 8.1.2, Solid Queue 1.7.2, Solid Cache
1.0.10, Solid Cable 4.1.0 and Propshaft 1.3.2. The earlier runs were on
other hosts (2.10, 2.80 and 2.30 GHz Xeons) and measured smaller apps, so
none of their figures is comparable with these. Servers and wrk are pinned
as the method says (CPU 0 or 0-1, wrk on 2-3).

The same session made one run before this one, at commit 6bce6390, with the
same apps and method except that it timed the startup on the database the
last configuration had left, thousands of comments included (fixed in
7b77d370): [2026-11-24-first.json](../bench/results/2026-11-24-first.json),
not tabulated. Its request figures show how far one run moves from the next
on this VM: of the 64 medians, 32 are within 10% of this run's and 47 within
20%; most of the rest are Rails' list and static file and CyberTrain's comment
POST, 21 to 31% apart (Rails' list at 16 connections on one core: 225 req/s
there, 155 here), and CyberTrain's POST at 16 connections on one core is the
largest gap, 259 there and 417 here. Rails came out lower in this run on most
rows. With the system malloc, the ratios at 16 connections were 2.1 to 5.1
times on one core there (2.5 to 5.6 here) and 1.2 to 4.0 times on two (1.2 to
4.3 here).


| | CyberTrain | Rails |
| --- | --- | --- |
| Version | cybertrain 0.4.2, spinel 2026.11.23.7035 (86421ea5) | Rails 8.1.4.1, Puma 8.1.2, sqlite3 gem 2.9.6 |
| Runtime | native binary (cc 13.3.0, `-O2`), system SQLite 3.45.1 | ruby 3.4.6, YJIT on, SQLite 3.53.2 (the gem's own) |

### One CPU core, system malloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles, comment counts) | 1 | 691 | 187 | 3.7x | 1.48 / 2.58 ms | 5.01 / 10.9 ms |
| GET /articles (30 articles, comment counts) | 16 | 696 | 155 | 4.5x | 20.9 / 39.2 ms | 85.2 / 288.5 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 1,001 | 206 | 4.9x | 0.92 / 2.60 ms | 4.55 / 8.85 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 1,119 | 199 | 5.6x | 13.3 / 23.6 ms | 71.5 / 266.5 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 1 | 10,056 | 5,380 | 1.9x | 0.08 / 1.30 ms | 0.14 / 2.09 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 16 | 13,676 | 5,554 | 2.5x | 1.11 / 2.65 ms | 2.58 / 10.5 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 1 | 423 | 110 | 3.8x | 1.71 / 65.1 ms | 6.23 / 42.4 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 16 | 417 | 98 | 4.3x | 29.8 / 93.0 ms | 159.8 / 275.7 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 27.7 MB | 137.0 MB |
| After the load runs | 29.6 MB | 188.6 MB |
| After the load runs (PSS) | 27.6 MB | 186.4 MB |

### Two CPU cores, system malloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles, comment counts) | 1 | 540 | 190 | 2.8x | 1.77 / 3.78 ms | 4.96 / 11.2 ms |
| GET /articles (30 articles, comment counts) | 16 | 989 | 422 | 2.3x | 18.7 / 40.5 ms | 33.4 / 176.6 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 946 | 180 | 5.3x | 0.98 / 2.68 ms | 5.15 / 11.6 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 1,538 | 359 | 4.3x | 12.4 / 28.0 ms | 38.4 / 243.2 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 1 | 10,165 | 3,550 | 2.9x | 0.08 / 1.59 ms | 0.23 / 1.99 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 16 | 22,310 | 11,926 | 1.9x | 0.73 / 2.73 ms | 1.17 / 5.47 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 1 | 402 | 155 | 2.6x | 1.63 / 139.2 ms | 5.84 / 16.0 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 16 | 274 | 221 | 1.2x | 50.3 / 317.0 ms | 69.8 / 151.7 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 31.3 MB | 364.6 MB |
| After the load runs | 35.0 MB | 457.9 MB |
| After the load runs (PSS) | 33.0 MB | 361.2 MB |

### One CPU core, jemalloc: server on CPU 0 (CyberTrain `SPINEL_WORKERS=1`; Puma single mode, 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles, comment counts) | 1 | 625 | 179 | 3.5x | 1.54 / 3.26 ms | 5.24 / 11.4 ms |
| GET /articles (30 articles, comment counts) | 16 | 665 | 125 | 5.3x | 22.2 / 55.5 ms | 130.6 / 343.0 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 889 | 182 | 4.9x | 1.03 / 3.04 ms | 5.23 / 9.98 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 1,060 | 186 | 5.7x | 14.0 / 23.3 ms | 77.8 / 287.2 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 1 | 10,687 | 4,253 | 2.5x | 0.08 / 0.81 ms | 0.18 / 2.08 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 16 | 12,944 | 6,260 | 2.1x | 1.18 / 3.29 ms | 2.35 / 8.49 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 1 | 342 | 127 | 2.7x | 2.01 / 55.5 ms | 5.72 / 33.9 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 16 | 418 | 122 | 3.4x | 29.2 / 343.8 ms | 124.4 / 232.2 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 30.2 MB | 135.0 MB |
| After the load runs | 31.4 MB | 182.4 MB |
| After the load runs (PSS) | 29.4 MB | 180.1 MB |

### Two CPU cores, jemalloc: server on CPU 0,1 (CyberTrain `SPINEL_WORKERS=2`; Puma 2 workers x 3 threads; jemalloc preloaded into both)

| Request | Connections | CyberTrain req/s | Rails req/s | CyberTrain / Rails | CyberTrain p50 / p99 | Rails p50 / p99 |
| --- | --: | --: | --: | --: | --: | --: |
| GET /articles (30 articles, comment counts) | 1 | 534 | 164 | 3.3x | 1.80 / 3.99 ms | 5.84 / 12.6 ms |
| GET /articles (30 articles, comment counts) | 16 | 1,002 | 342 | 2.9x | 20.6 / 42.8 ms | 41.9 / 208.5 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 1 | 972 | 157 | 6.2x | 0.97 / 2.60 ms | 5.96 / 14.3 ms |
| GET /articles/1 (an article, 10 comments, 12 forms) | 16 | 1,647 | 349 | 4.7x | 11.7 / 26.0 ms | 40.4 / 249.4 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 1 | 10,628 | 3,079 | 3.5x | 0.08 / 1.17 ms | 0.28 / 2.59 ms |
| GET /assets/application-<digest>.css (the digested stylesheet) | 16 | 19,585 | 11,702 | 1.7x | 0.77 / 3.74 ms | 1.20 / 5.83 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 1 | 308 | 136 | 2.3x | 2.29 / 139.2 ms | 6.70 / 20.2 ms |
| POST /articles/2/comments (insert, job, broadcast, 303) | 16 | 360 | 218 | 1.7x | 37.9 / 272.6 ms | 69.7 / 155.0 ms |

| Memory (RSS, all processes) | CyberTrain | Rails |
| --- | --: | --: |
| After seeding, before load | 34.2 MB | 364.4 MB |
| After the load runs | 37.2 MB | 423.8 MB |
| After the load runs (PSS) | 35.1 MB | 310.0 MB |

| Startup (5 boots, median) | CyberTrain | Rails |
| --- | --: | --: |
| Spawn to first 200 for `GET /` | 0.041 s | 2.064 s |
| RSS then | 23.3 MB | 114.8 MB |

| What the server needs | CyberTrain | Rails |
| --- | --: | --: |
| The application | 11.7 MB binary (`dist/blog`) | 0.94 MB of source |
| Gems | none | 62.6 MB (79 gems) |
| Ruby | none | 50.5 MB |
| Total | 11.7 MB | 114.0 MB |
| Shared libraries | libm.so.6, libz.so.1, libsqlite3.so.0, libssl.so.3, libcrypto.so.3, libc.so.6, /lib64/ld-linux-x86-64.so.2 | (Ruby's own, and the gems' native extensions) |

`cybertrain build` took 271 s.

## Reading the results

These notes read the recorded run of 2026-11-24.

- **One core: 2.5 to 5.6 times the requests** at 16 connections (2.1 to 5.7
  with jemalloc in both). The gap is widest on the article page: 10 comments
  and 12 forms, each with a CSRF token (a separately signed one per form in
  Rails), and a signed stream name. CyberTrain now serves the article page
  faster than the list (1,119 and 696 req/s): the list preloads every
  article's comments for its counts, reads the article count from the cache
  table and renders the filter form. Rails serves the two at about the same
  rate (199 and 155).
- **Latency.** One request at a time, CyberTrain answers the pages and the
  POST in 0.9 to 1.7 ms (median) and Rails in 4.6 to 6.2 ms. With 16
  connections on one core, CyberTrain's 99th percentile on the pages is 24 to
  39 ms against 267 to 289 ms for Rails.
- **The comment POST** is where CyberTrain does worst. Each one inserts the
  comment, a job row and a stream message into examples/blog's one SQLite
  database, and the server's job thread runs the job, on the same CPUs; the
  Rails app writes the comment, the job and the message to three files
  (Solid Queue's and Solid Cable's own databases). One request at a time,
  CyberTrain's median is 3.6 times faster but its 99th percentile is worse in
  every configuration (55 to 139 ms against 16 to 42 ms for Rails). On two
  cores its throughput at 16 connections falls below its one-core figure (274
  against 417 req/s; 360 against 418 with jemalloc) and its 99th percentile
  reaches 317 ms against Rails' 152, so its lead there is 1.2 times (1.7 with
  jemalloc). It also moves the most from run to run (259 req/s on one core in
  the first run of the day, 417 here). The cause was not measured in this
  run; contention for the one database's write lock between the request
  threads and the job thread is the likely place to look. A check run
  (`--quick`, 1 s runs) found 118 of 910 CyberTrain jobs still queued when
  its server stopped, where Solid Queue had finished all 649 of its own.
- **Two cores.** Puma's second worker process gives Rails 1.8 to 2.7 times
  its one-core rate on the pages and 2.3 times on the POST. CyberTrain's
  second worker (`SPINEL_WORKERS=2`, for which the server has asked Spinel
  for one more worker since
  [saeki-mototsune/CyberTrain#128](https://github.com/saeki-mototsune/CyberTrain/pull/128),
  so that two OS threads serve requests; [spikes/NOTES.md](../spikes/NOTES.md)
  rule 22) adds 37 to 55% on the pages and 63% on the static file, and the
  POST loses a third. So the lead narrows to 1.2 to 4.3 times.
- **Static file.** Both apps serve the same 1,556-byte digested stylesheet:
  CyberTrain 13,700 req/s on one core and 22,300 on two, Rails 5,600 and
  11,900. In production both would usually sit behind a proxy that serves
  the assets itself ([deploy.en.md](deploy.en.md) puts Caddy in front), so
  these rows are there for completeness.
- **jemalloc.** In this run it moves both apps by amounts within the spread
  between runs on this VM (on one core CyberTrain's requests -5 to 0%,
  Rails' -19 to +24%), so it shows no clear effect either way.
- **Memory.** One CyberTrain process serving 16 connections, its job thread
  included, stays near 30 MB (31 MB with jemalloc). One Puma process with
  Rails, Solid Queue's threads included, is 189 MB after the load; on two
  cores (a master that also runs the jobs, and two workers) 458 MB by RSS,
  361 MB by PSS, against CyberTrain's 35 MB (33 MB).
- **Startup.** The binary answers its first request 0.041 s after it is
  spawned; Rails, which also starts Solid Queue, takes 2.1 s with bootsnap's
  cache warm.
- **Size.** The server needs one 11.7 MB file, which links libc, zlib,
  OpenSSL and the system SQLite (and libjemalloc when chosen), against Ruby,
  79 gems and the app: 114 MB. The binary was 4.0 MB on 2026-11-05: the
  framework and the blog have grown since, and the binary now links OpenSSL.
- **What it costs.** The binary has to be built: `cybertrain build` took
  271 s on this machine, and every Ruby change needs a rebuild
  (`cybertrain server` does it for you in development), where Rails runs its
  source as it is. And the comparison covers only the slice of Rails both
  apps use; CyberTrain's ORM and router are smaller (see
  [Differences from Rails](guide/how-it-works.md#differences-from-rails)).
- **The machine.** It is a shared cloud VM and not the same host from day to
  day: the runs of 2026-10-07 and 2026-10-08 were on a 2.10 GHz Xeon, that of
  2026-10-09 on a 2.80 GHz one, that of 2026-11-05 on a 2.30 GHz one, this one
  on a 2.10 GHz one, and the apps differ from run to run as well. Compare
  numbers within one run, not across runs; even within a day on one VM, the
  two runs of 2026-11-24 differ by 21 to 31% on a few rows, and by 61% on
  CyberTrain's one-core POST (see [Results](#results)).

## Running it

On Linux with at least 4 CPUs, from a checkout:

```sh
cybertrain setup                 # Spinel, for examples/blog
sudo apt-get install -y wrk libjemalloc2   # jemalloc for the -jemalloc configurations
cd bench/rails_blog && bundle install && cd ../..
BENCH_RAILS_RUBY=/path/to/ruby/bin/ruby bench/run   # about 45 minutes; --quick to check the setup
bench/report                     # the tables above, from the newest bench/results/*.json
```

`BENCH_RAILS_RUBY` is the Ruby that runs Rails (default: the `ruby` on
`PATH`); give it one built with YJIT, or the numbers undersell Rails (bench/run
warns). The recorded run used Ruby 3.4.6 from
[ruby/ruby-builder](https://github.com/ruby/ruby-builder) (the build
`setup-ruby` installs on GitHub Actions), unpacked where it expects to live,
`/opt/hostedtoolcache/Ruby/3.4.6/x64`. `bench/run --help` lists the knobs
(configurations, durations, runs); its scratch files go to `bench/tmp/`.
Start it on an idle machine: another build or test suite on the same VM takes
CPU time from the server and from wrk alike.
