# Performance: what is left

Where CyberTrain's request path stands after the work in
[benchmark.md](benchmark.md), and what could still be done, with the
measurement behind each item so nobody has to repeat it. All numbers are
for [examples/blog](../examples/blog), one core, 16 connections, on the cloud
VM described in benchmark.md; that VM runs the same binary 10 to 15% apart
from one run to the next, so anything under about 5% in requests per second
cannot be seen directly. Objects allocated per page are counted instead
(deterministic), with `SPINEL_ALLOC_REPORT`, below.

## Where the time goes now

About 520 objects per article page and 525 per list page (about 1,100 at the
first recorded run). Per request, roughly:

| Share | What |
| --: | --- |
| about 1/5 | OS thread switches: the fiber of a connection parks on `wait_readable`, the scheduler's monitor thread wakes it, and the collector stops the world (about 16 `futex` calls per request) |
| about 1/5 | garbage collection and malloc/free, proportional to the objects above |
| the rest | the template interpreter, SQLite, the HTTP parser, sessions |

The first two are Spinel's runtime, not the framework. Nothing in the
application can change them directly; fewer objects is the only lever, and
that is what is left below.

## Candidates, with what is known

Each is an object count per article page unless it says otherwise.

1. **Partial output buffers, about 22 objects (4%).** `Interpreter#render`
   makes a `String.new` per partial and its result is converted to an
   immutable String on return (a second copy). Rendering a partial straight
   into the caller's `@out` when it sits in an output position
   (`<%= render ... %>`) would remove both. It needs `render_helper` and the
   `K_OUT` case of `exec_nodes` to agree, keeping the error prefix
   (`name:line:`) that `call_helper` adds and the `strict locals` check.
2. **Route building for nested records, about 23 + 11 (6%).**
   `button_to "...", [@article, comment]` builds the route name
   (`"article_comment_path"`) and an argument Array, and `Gen.segment` makes a
   String per id. A per-request memo of the route name for a model pair
   (like `model_key`) removes the first; an Integer-typed segment in the
   generated `path_for` (interpolating the id without `to_s`) removes the
   second but needs the generator to type its arguments.
3. **`Time` for every DATETIME column, about 22 (4%).** The text is no longer
   copied (epoch seconds are read in C), but `Time.at(...)` still boxes a
   Time per column. A model that kept the epoch Integer and made the Time on
   first read would remove it. Measured upper bound with the whole parse
   skipped: +1.5% (list) and +0.6% (article) in requests per second, before
   the C parse existed. It changes the attribute's typing (a nullable Time
   ivar that is filled lazily), which the generated models avoid on purpose
   (spikes/NOTES.md rules 7 and 43), so it needs a Spinel probe first.
4. **`Interpreter` environments, about 11 + 21.** `render_helper` copies the
   environment per partial (`env.dup`, about 11 Hashes) and `eval_kwargs`
   builds a Hash per call with keywords (about 21). Sharing the environment
   and restoring the names a partial assigns would remove the first, but a
   partial's own assignments must stay invisible to its caller, so the
   template compiler would have to list them (it already does for block
   locals). Measured upper bound with the copy removed altogether: +0.6%.
5. **`HttpParser.parse_head`, about 12.** Four Strings per header line
   (`line[0, colon]`, `downcase`, the value slice, `strip`). A byte-level
   parse would make one. Browsers send `Host`, `User-Agent` with capitals, so
   the downcase copy stays unless names are compared case-insensitively
   without being stored lowercase, which `Request#header` already does for
   lookups.
6. **Session cookie, about 8.** `Session.load` slices the cookie three times
   and `Crypto.hmac_digest` builds pads and concatenations; a streaming
   `Digest::SHA256` (update/finalize) would avoid `ipad + data.b`.
7. **Rows, about 30.** `read_row` makes one String per text column (an FFI
   `:str` return copies). Reading text columns lazily would need the
   statement to stay open, or a C helper that copies into a model-owned
   buffer; both change who owns the memory.

## Things that are not worth doing again

All measured, see benchmark.md and spikes/NOTES.md for the numbers.

- Spinel's collector settings (`SPINEL_GC_*`, `SPINEL_SCHED_POLL`): within
  noise of the defaults or slower.
- A park-free read (`wait_readable(0)` before the real wait): the next
  request is never there yet with this load, so `futex` and `epoll_wait` per
  request did not move.
- A `Static` that lists `public/` once: +19% for the static file, nothing for
  pages, and a file added later is not served until a restart.
- A process-wide cache behind a `Mutex`: stalls requests with
  `SPINEL_WORKERS=2` (rule 57).
- `Foo.new(<fresh String>)`: do not write it; bind the String to a local, or
  use `SafeString.of` (rule 58, a use-after-free).

## What would change the picture: Spinel

These are for the runtime, not for this repository; the full list, written
up as issues, is [spinel-feedback.md](spinel-feedback.md).

- A constructor that roots its arguments before it allocates (the cause of
  rule 58).
- Fiber parking without a hand-off to the monitor thread when the descriptor
  is ready, or readiness checked by the worker itself at `N=1`.
- A collection that does not stop every thread when there is one worker.
- `Array#clear` and Hash values of objects boxing their containers (rule 56).

## How to measure

- Objects and Strings per request:
  `SPINEL_ALLOC_REPORT=/tmp/alloc.txt SPINEL_ALLOC_SITES=1 ./blog`, then 200
  requests, then sum the last column of the report by type and by site
  (`addr2line -f -e ./blog <offset>` names a site).
- Who allocates: `gdb` with `break sp_str_concat`, `sp_str_dup`,
  `sp_String_new_len`, `sp_proc_new_meta` ... and `bt 3` on one warm request.
- Time: `bench/run`, and for a quick comparison alternate two binaries
  several times (the spread is 5 to 8%).
- Memory errors: an AddressSanitizer build is
  `spinel app.rb --cc=<script running cc -fsanitize=address
  -fno-sanitize-address-use-after-scope -fno-omit-frame-pointer -g>` with
  `ASAN_OPTIONS=detect_leaks=0:fast_unwind_on_malloc=0`.
