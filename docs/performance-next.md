# Performance: what is left

Where CyberTrain's request path stands after the work in
[benchmark.md](benchmark.md), and what could still be done, with the
measurement behind each item so nobody has to repeat it. Last reviewed on
2026-11-05 against cybertrain 0.4.1 (dade561) and the pinned Spinel
2026.11.04.7026; every number says which build it is from, and a number
from an older build has not been re-measured unless it says so.

Requests per second are for [examples/blog](../examples/blog), one core, 16
connections, on the cloud VM described in benchmark.md; that VM runs the
same binary 10 to 15% apart from one run to the next, so anything under
about 5% in requests per second cannot be seen directly. Objects allocated
per page are counted instead (deterministic), with `SPINEL_ALLOC_REPORT`,
below.

## Where it stands now

Objects allocated per page, for a returning visitor on a keep-alive
connection, after the seeding bench/run does (30 articles, 10 comments on
the first):

| Build | `GET /articles/1` | `GET /articles` |
| --- | --: | --: |
| cybertrain 0.2.1 (d7d04e8), Spinel 2026.09.12, as counted on 2026-10-09 (Linux) | about 520 | about 525 |
| the same commit and Spinel, counted again on 2026-11-05 (macOS, arm64) | 498 | 510 |
| cybertrain 0.4.1 (dade561), Spinel 2026.11.04.7026, counted on 2026-11-05 (macOS, arm64) | 1,650 | 1,822 |
| the same with candidate 9 done, counted on 2026-11-05 (macOS, arm64) | 1,073 | 1,058 |

At dade561 the pinned build allocated more than three times the objects of
the build this page was first written for; with candidate 9 done it is a
little over twice. The second row is there to show that the
count of 2026-11-05 (another machine, Ruby's Net::HTTP as the client) gives
what the first one gave. The framework and Spinel both changed between the
rows, and the same source was not built on both, so the growth is not
divided between them, except for the 576 closure cells below: the source
line behind most of them is the same in both commits, and the 2026.09.12
build allocates none. [spinel-feedback.md](spinel-feedback.md) E has an
earlier measurement of the same kind (852 objects against 511 for one
source, on 2026.10.09-7009).

The 1,650 objects of an article page on 2026.11.04.7026 at dade561, before
candidate 9 (which took 566 of the cells and 11 of the `(no-scan)` ones,
and left the other rows as they are):

| Objects | What |
| --: | --- |
| 576 | Closure cells: a heap cell for each local a block captures, allocated on entry to the method that holds the block, whether or not the call reaches the block. `Interpreter#eval_expr` 525, `Helpers#nested_url` 33, `Response#set_header` 8, `Interpreter#exec_each` 5, four others 5 (candidate 9) |
| 444 | `(no-scan)` in the report, allocations that hold no references: the bytes of Strings, mostly. `sp_String_new_inline_len` 119, `Integer#to_s` 26, `hidden_fields` 23, `nested_url` 22, `read_row` 22, `Time.at` 22, substrings 21 |
| 277 | `String` in the report. `button_to` 23, the rows' text columns 22, `helper_call` 18, `render_helper` 15, `HttpParser.parse_head` 15, `Inflector.underscore` 13 |
| 187 | Arrays of mixed values (`sp_PolyArray_new`); which calls make them is not identified |
| 166 | Hashes 81, `SafeString` 32, Arrays of Strings 21, the 12 records, and one each of the request's own objects |

The list page had 756 cells from `eval_expr` (41% of its objects), and has
97 of those Arrays and 60 each for `Time.at`, `read_row` and the rows' text
columns.

Requests per second, from the recorded runs (bench/run does not set
`SPINEL_GC_FULL_INTERVAL`, so these are with the collector's own cadence):

| One core, 16 connections | 2026-10-09 (0.2.1, Spinel 2026.09.12, 2.80 GHz host) | 2026-11-05 (0.4.1, Spinel 2026.11.04.7026, 2.30 GHz host) |
| --- | --: | --: |
| `GET /articles` | 2,641 req/s, 5.6 times Rails | 3,218 req/s, 4.5 times Rails |
| `GET /articles/1` | 2,450 req/s, 12.2 times Rails | 3,201 req/s, 8.8 times Rails |

The hosts differ, so the rates do not compare across the columns: Rails,
unchanged, ran 1.5 to 1.8 times as fast in the later run, and CyberTrain 1.2
to 1.3 times. That is why the lead is narrower; how much of it is the
objects above has not been measured.

Where the time went, per request, when it was last profiled (perf, on
2026.09.12, 2026-10-07 to 2026-10-09), and what is known since:

| Share on 2026.09.12 | What | Since |
| --: | --- | --- |
| about 1/5 | OS thread switches: the fiber of a connection parked on `wait_readable` was woken through the scheduler's monitor thread and the scheduler lock (about 16 `futex` calls per request), and the collector stops the world | Fixed on 2026.10.27.7020, where the park stays on the worker: 2 `futex` and 0.5 context switches per request, most of them the collector's sweeper hand-off and the rest the monitor's timer turns ([spinel-feedback.md](spinel-feedback.md) 4 and 5, measured 2026-10-30). Not re-measured on 2026.11.04.7026 |
| about 1/5 | garbage collection and malloc/free, proportional to the objects above | On 2026.10.27.7020, one CPU, collections are 13% of wall time, 83% of them full; `SPINEL_GC_FULL_INTERVAL=8` gives 16 to 17% more requests a second (spinel-feedback.md 5). Not re-measured on 2026.11.04.7026, whose collector has the same cadence rule |
| the rest | the template interpreter, SQLite, the HTTP parser, sessions | Not profiled again |

The first two rows are Spinel's runtime, not the framework. Two things reach them from outside: fewer
objects, which is what the candidates below are, and
`SPINEL_GC_FULL_INTERVAL=8`, which the Dockerfile `cybertrain new` writes,
examples/blog's and the environment file in [deploy.en.md](deploy.en.md)
set since 2026-10-30.

A profile of the pinned build, at dade561 and so before candidate 9: macOS
`sample` on an article page, 2,897 on-CPU samples, no `Set-Cookie` on the
responses. These are macOS shares on arm64, not comparable to the perf table
above:

| Share of on-CPU samples | What |
| --: | --- |
| 74%, inclusive | rendering the template |
| 45%, inclusive | helpers, 42 of it `render_helper` |
| 20% | the collector (`gc_collect`) |
| 16%, inclusive | the comment relation and SQLite |
| at most 11.6% | the interpreter's own work: `Interpreter` and the polymorphic Hash and value calls under it |
| 2.8 / 2.7 / 2.6 / 2 / 1.9% | `Session.load` / `eval_kwargs` / `HttpParser.parse_head` / `Logger` / `Inflector.pluralize` |

`SPINEL_GC_FULL_INTERVAL=8` measured on 2026.11.04.7026 (Linux arm64 in Docker
on a Mac, one process, wrk with 32 connections): `GET /articles` 8,050 to
10,400 req/s, `GET /articles/1` about 9,000 to 11,400, the POST about 5% up.
bench/run leaves it unset, so its published figures are below what a deployment
gets; compare within one setting.

## Candidates, with what is known

Each is an object count per article page unless it says otherwise. The
numbers stay as they were given out (other pages cite 8), so they are in
the order found, not by size: 9 was the largest by far, and is done. Counts
marked 2026.09.12 are from 2026-10-09 and were not re-derived; counts
marked 2026.11.04.7026 are from the reports of 2026-11-05, by the function
that allocates. The code each item names was checked against dade561.

1. **Partial output buffers, about 22 objects on 2026.09.12 (4%).**
   `Interpreter#render` makes a `String.new` per partial and its result is
   converted to an immutable String on return (a second copy). Rendering a
   partial straight into the caller's `@out` when it sits in an output
   position (`<%= render ... %>`) would remove both. It needs
   `render_helper` and the `K_OUT` case of `exec_nodes` to agree, keeping
   the error prefix (`name:line:`) that `call_helper` adds and the
   `strict locals` check. On 2026.11.04.7026: 13 in `Interpreter#render`
   and 19 in `render_helper`, not all of which are the copy.
2. **Route building for nested records, about 23 + 11 on 2026.09.12 (6%).**
   `button_to "...", [@article, comment]` builds the route name
   (`"article_comment_path"`) and an argument Array, and `Gen.segment` makes a
   String per id. A per-request memo of the route name for a model pair
   (like `model_key`) removes the first; an Integer-typed segment in the
   generated `path_for` (interpolating the id without `to_s`) removes the
   second but needs the generator to type its arguments. On
   2026.11.04.7026, after 9: `button_to` 34, `Integer#to_s` 26, `url_for`
   14, `path_for` 13, `nested_url` 11 and the generated URL resolver 11.
3. **`Time` for every DATETIME column, about 22 (4% on 2026.09.12; 22 on
   2026.11.04.7026 too, and 60 on the list page).** The text is no longer
   copied (epoch seconds are read in C), but `Time.at(...)` still boxes a
   Time per column. A model that kept the epoch Integer and made the Time on
   first read would remove it. Measured upper bound with the whole parse
   skipped: +1.5% (list) and +0.6% (article) in requests per second, before
   the C parse existed. It changes the attribute's typing (a nullable Time
   ivar that is filled lazily), which the generated models avoid on purpose
   (spikes/NOTES.md rules 7 and 43), so it needs a Spinel probe first.
   Probes of rules 7 and 43 pass on 2026.11.04.7026 (NOTES, "Status on
   2026.11.04.7026"); the lazily filled ivar itself has not been probed.
4. **`Interpreter` environments, about 11 + 21 on 2026.09.12.**
   `render_helper` copies the environment per partial (`env.dup`, about 11
   Hashes) and `eval_kwargs` builds a Hash per call with keywords (about
   21). Sharing the environment and restoring the names a partial assigns
   would remove the first, but a partial's own assignments must stay
   invisible to its caller, so the template compiler would have to list
   them (it already does for block locals). Measured upper bound with the
   copy removed altogether: +0.6%. On 2026.11.04.7026 the article page
   makes 81 Hashes in all; they are not attributed to these two.
5. **`HttpParser.parse_head`, about 12 on 2026.09.12.** Four Strings per
   header line (`line[0, colon]`, `downcase`, the value slice, `strip`). A
   byte-level parse would make one. Browsers send `Host`, `User-Agent` with
   capitals, so the downcase copy stays unless names are compared
   case-insensitively without being stored lowercase, which
   `Request#header` already does for lookups. On 2026.11.04.7026: 15 in
   `parse_head` itself for the headers Net::HTTP sends, not counting the
   slices the runtime's own functions make for it.
6. **Session cookie, about 8 on 2026.09.12.** `Session.load` slices the
   cookie three times and `Crypto.hmac_digest` builds pads and
   concatenations; a streaming SHA-256 (update/finalize) would avoid
   `ipad + data.b`. Spinel 2026.11.04.7026 has `Digest::SHA256.new` with
   `update`, but it keeps the bytes it is given and hashes them when the
   digest is asked for (packages/digest/digest.rb), so it saves nothing
   here: this needs the runtime's SHA-256 state exposed, or a C helper. On
   2026.11.04.7026: 7 in `Session.load`, 5 in `Crypto.hmac_digest`.
7. **Rows, about 30 on 2026.09.12.** `read_row` makes one String per text
   column (an FFI `:str` return copies). Reading text columns lazily would
   need the statement to stay open, or a C helper that copies into a
   model-owned buffer; both change who owns the memory. On 2026.11.04.7026
   each text value is two allocations, a String and its bytes: 44 on the
   article page (22 values), 120 on the list page.
8. **Idle keep-alive connections, CPU at rest (not objects): done
   2026-10-30.** Between requests `Server#head_readable?` waited in
   `ACCEPT_POLL` (0.1 s) slices so that a connection noticed `#stop`, and
   each slice was a park, a timer and a monitor turn. It now parks once for
   `read_timeout`, and the drain shuts the read side of the idle
   connections, which wakes their threads with EOF on CRuby and Spinel
   alike (a close would too, but would cut off a connection that had just
   taken its next request). One CPU, 10 s windows, Spinel 2026.10.27.7020:

   | Idle connections | Before | After |
   | --: | --: | --: |
   | 100 | 1.7% of the CPU, 289 switches/s | 0.6%, 193/s |
   | 1,000 | 8.8%, 2,361/s | 0.8%, 192/s |

   A TERM with 1,000 idle connections open now exits in 0.13 to 0.29 s
   (three runs). Requests a
   second under load did not drop (2,674 / 2,496 / 2,984 before, 2,817 /
   2,762 / 3,068 after, alternated on one CPU).
9. **Closure cells, 576 on 2026.11.04.7026 (35%); 525 of them in
   `Interpreter#eval_expr` (756 on the list page, 41%): found and done
   2026-11-05.** On this Spinel a method that holds a block allocates a
   heap cell for every local the block captures as the method is entered
   (`_cell_n = sp_gc_alloc(...)` at the top of the generated C), on every
   call. The Hash literal case of `eval_expr` was
   `n.ipairs.each_with_index { |key, i| hash[key] = eval_expr(n.ikids[i], env) }`,
   which captures `n`, `env` and `hash`: three cells for each of the 175
   calls of `eval_expr` an article page makes (252 on the list page),
   though neither page has a Hash literal. The line was there on
   2026-10-09, and the 2026.09.12 build allocates nothing for it. The same
   shape, a block on a path the usual call does not take, was in
   `Helpers#nested_url` (3 cells a call, 33 a page: the `each_with_index`
   after the two-item early return) and `Response#set_header` (4 a call, 8
   a request: the rebuild of a header stored under another spelling). The
   first two are `while` loops now and the third's rebuild is a method of
   its own (`respell_header`):

   | Objects per page | `GET /articles/1` | `GET /articles` |
   | --- | --: | --: |
   | Before (dade561) | 1,650 | 1,822 |
   | After | 1,073 | 1,058 |

   Requests per second were not measured. Ten cells a page are left:
   `Interpreter#exec_each` 5 (the block of its Hash case; once per loop,
   not per item), `Router#call` 2, and one each in `Flash.load`,
   `Interpreter#capture` and `Response#to_http`. For new code on the
   request path: a block that captures locals costs its method a cell per
   captured local on every call, so write a `while` loop, or keep the
   block in a method that is called only when it is needed.
10. **A second worker adds nothing to the pages on 2026.11.04.7026 (not
    objects).** In the run of 2026-11-05 `SPINEL_WORKERS=2` on two cores
    gives 0 to 2% more requests a second on the pages and 19% on the POST,
    against 9 to 25% and 58% on 2026-10-09. A check after that run found
    one CPU's worth of time used out of two, so the second worker mostly
    waits. The cause has not been looked for
    ([benchmark.md](benchmark.md), "Reading the results").
11. **Compiling templates to Ruby methods for production (held, not
    objects).** The interpreter's own work was at most 11.6% of the profile
    above, so removing all of it gives about 13% in requests per second. What
    fewer objects would add to that through the collector has not been
    measured, and candidate 9 has taken part of the interpreter's share since.
    The environment stays a Hash of polymorphic values, because what a template reads is decided by the
    controller, so generated code would not get fixed types. It would also
    add a second way of running a template beside the one development uses.
    Reopen it if a new profile puts the interpreter's own share well above
    what candidates 1 to 7 could recover.
12. **`includes`, a bulk `WHERE fk IN (...)` load (held, not objects).** The
    article page runs 2 queries, not one per comment, so examples/blog does
    not have the N+1 this would remove. It is a feature for applications
    that do. Reopen it when one does, with its query count; generated models
    would need a typed place to keep the preloaded records. Done
    2026-11-06 as a feature, not for examples/blog: `includes` / `preload`
    on the generated Relation (phase 2 data layer spec, section 8), the
    records kept in the per-model Relation and the readers' cache ivars.
13. **Several processes on one port (not objects): done 2026-11-05.**
    `SPINEL_WORKERS=2` adds nothing to the pages (candidate 10), and processes
    do. `CYBERTRAIN_REUSE_PORT` lets N processes share a port on Linux
    ([design.md](design.md) D35, [deploy.en.md](deploy.en.md)). Linux arm64 in
    Docker on a Mac, wrk with 32 connections, `GET /articles/1`, without
    `SPINEL_GC_FULL_INTERVAL`: 9,100 req/s with one process, 15,200 to 16,900
    with two, 27,300 to 28,000 with four; the POST stays at 5,000 to 6,000,
    since SQLite has one writer. With the interval set, one against two
    processes alternated over six rounds: median 10,055 and 16,702 req/s, 1.66
    times. These are not figures for the VM above.
14. **`Set-Cookie`, CPU rather than objects: done 2026-11-05.**
    `URI.encode_www_form_component` runs a regular expression per character,
    about 11% of the CPU on a page that writes the session on every response
    in a macOS profile. `Cookies.serialize` now skips it for a value of
    unreserved bytes (`Query.plain?`), and `Session.dump` no longer pads
    base64, which is what kept 2 of 3 session lengths on the slow path. Old
    cookies still load. Dump and serialize together went from 15.6 to 2.1 µs
    for a value of about 205 bytes. On a page that writes one such cookie, six
    alternated rounds gave a median of 1.24 times the requests against 1.03 for
    the control (Linux arm64 in Docker on a Mac). The gain on a real session
    POST could not be read: the comments table grew during the run.

Not attributed yet on 2026.11.04.7026, and each larger than candidates 1
to 7: the 187 Arrays from `sp_PolyArray_new` and the 119 allocations of
`sp_String_new_inline_len`. The report names the runtime function that
allocates, not the framework method that called it; a debugger does
(under "How to measure").

## Things that are not worth doing again

All measured, see benchmark.md and spikes/NOTES.md for the numbers.

- Spinel's collector settings (`SPINEL_GC_*`, `SPINEL_SCHED_POLL`): within
  noise of the defaults or slower on 2026.09.12. Not so on 2026.10.27.7020:
  on one CPU `SPINEL_GC_FULL_INTERVAL=8` gives +16 to 17% on both pages
  and `SPINEL_GC_CONC=0` +5%, because the default full cadence collapses
  to nearly every collection full (spinel-feedback.md 5). A larger
  `SPINEL_GC_THRESHOLD_KB` still does not help on its own. The deploy
  files set the interval (above); `SPINEL_GC_CONC=0` is left out, because
  it helps only on a one-CPU host. The interval's figures on
  2026.11.04.7026 are above, measured with one process; `SPINEL_GC_CONC=0`
  was not re-measured there.
- jemalloc for the pages: 1.3 to 1.4 times the requests on 2026.09.12
  (2026-10-09), -3 to +1% in the run of 2026-11-05 on 2026.11.04.7026 (the
  POST still gains 18% on one core). It stays an option in spin.toml, off
  by default.
- A park-free read (`wait_readable(0)` before the real wait): the next
  request is never there yet with this load, so `futex` and `epoll_wait` per
  request did not move. On 2026.10.27.7020 a park no longer leaves the
  worker (one `epoll_ctl` and one `epoll_wait`); not re-measured there.
- A `Static` that lists `public/` once: +19% for the static file, nothing for
  pages, and a file added later is not served until a restart. Embedding
  `public/` in the binary with a precomputed ETag has the same limit, and in
  the deployment in deploy.md Caddy serves `dist/public` before the request
  reaches the binary.
- ccache, `-O0`/`-O1` and mold or lld for dev builds: of about 8 s for one edit
  on examples/blog (2026-11-05), gen took 3.3 s, Spinel's analysis 3.9 s, and
  the C compiler and linker together 0.75 s, of which compiling the two changed
  units 0.2 s and linking 0.05 s. The optimization level made no difference to
  an edit, and `--incremental` already has a content-addressed object cache.
- A separate binary per model or per request, a thread per request, an external
  SQLite connection layer, or async queries: each adds a boundary or a thread
  switch to a request whose queries are already sub-millisecond, and a query on
  another thread leaves `DB.transaction`.
- HMAC or `read_row` in C by themselves: the Strings still have to be made, so
  the objects stay. Candidates 6 and 7 say what would actually remove them.
- Bundling the tests into fewer programs: whole-program typing means tests
  sharing a program change each other's types, and they would share process
  state. CI is sharded instead.
- An interpreted development mode on CRuby: it hides the Spinel differences a
  developer most needs to see, and needs a shim for every `ffi_func`.
- A process-wide cache behind a `Mutex`: stalls requests with
  `SPINEL_WORKERS=2` (rule 57, seen on 2026.09.12 and not tried since).
- `Foo.new(<fresh String>)`: do not write it; bind the String to a local, or
  use `SafeString.of` (rule 58, a use-after-free).

## What would change the picture: Spinel

These are for the runtime, not for this repository; the full list, written
up as issues, is [spinel-feedback.md](spinel-feedback.md).

- A full-collection cadence that does not fall to every cycle for a
  server's request garbage (spinel-feedback.md 5: 83% of collections are
  full; fixing the interval at 8 is worth 16 to 17% on one CPU), and no
  sweeper thread when the process has one CPU (5%). Open: measured on
  2026.10.27.7020, and the code behind it is the same on 2026.11.04.7026.
- Closure cells allocated where the block is made, not at method entry, so
  that a call which never reaches the block pays nothing (candidate 9,
  which CyberTrain now writes around in three methods). New on 2026-11-05;
  written up as spinel-feedback.md AA on 2026-11-13.
- A `:str` FFI return that does not copy (candidate 7; spinel-feedback.md,
  "FFI and tools").
- `Array#clear` and Hash values of objects boxing their containers (rule
  56; not re-checked on 2026.11.04.7026).
- Fiber parking without a hand-off to the monitor thread: done on
  2026.10.27.7020 (spinel-feedback.md 4).
- A constructor that roots its arguments before it allocates (the cause of
  rule 58): no longer asked for. No reduced program shows it on any build,
  and the workaround is accepted as how CyberTrain is written
  (spinel-feedback.md, "Accepted as Spinel constraints", 2026-10-28).

## How to measure

- Objects per request: build with `cybertrain build`, then run
  `SPINEL_ALLOC_REPORT=/tmp/alloc.txt SPINEL_ALLOC_SITES=1 ./blog` from
  `dist/`. The report is written when the server exits and counts
  everything since it started, the boot and the seeding included: run it
  twice with the same seeding, once with 200 requests for the page and
  once with 400, and divide the difference of each line by 200. Each line
  is a site, a type and a count. On macOS the site is already a function
  and an offset; on Linux `addr2line -f -e ./blog <offset>` names it. A
  type printed as `scan_0x...` is the address of a runtime scan function:
  subtract the load address (a site's address minus its function's in
  `nm`) and look it up in `nm` (`sp_cell_scan_rbval` and
  `sp_cell_scan_ptr` are closure cells). The address changes from run to
  run, so match such lines by site.
- What a method allocates on entry: `spinel bin/blog.rb -I ../.. -S`
  (from examples/blog, with the pinned Spinel) prints the C; look for
  `_cell_` and `sp_gc_alloc` at the top of the function.
- Who allocates: `gdb` with `break sp_str_concat`, `sp_str_dup`,
  `sp_String_new_len`, `sp_proc_new_meta` ... and `bt 3` on one warm
  request (the names are 2026.09.12's; on 2026.11.04.7026 the ones to
  break on are `sp_PolyArray_new` and `sp_String_new_inline_len`).
- Time: `bench/run`, and for a quick comparison alternate two binaries
  several times (the spread is 5 to 8%).
- Memory errors: an AddressSanitizer build is
  `spinel app.rb --cc=<script running cc -fsanitize=address
  -fno-sanitize-address-use-after-scope -fno-omit-frame-pointer -g>` with
  `ASAN_OPTIONS=detect_leaks=0:fast_unwind_on_malloc=0`. The object slab
  (on by default; 2026.09.12 had none) recycles freed slots itself, so
  with it on AddressSanitizer does not see a freed object being read. Run
  the build both ways: with `SPINEL_GC_SLAB=0`, which is how J was found
  (it fails on 2026.10.27.7020, fork master 49ccdced and 2026.11.04.7026),
  and with the slab on, the configuration that ships, which no
  AddressSanitizer run has cleared (spinel-feedback.md J).
- Collector behaviour: `SPINEL_GC_STATS=1` prints collections, how many
  were full and the share of wall time once a second; `SPINEL_GC_PHASES=1`
  prints the mark, the sweep, the stop-the-world wait and the slab release
  at exit. On a one-CPU server, pin it (`taskset -c 0`) and drive the load
  from the other CPUs, or the client is what gets measured.
