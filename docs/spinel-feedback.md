# Feedback for Spinel

What building and speeding up CyberTrain found in Spinel itself (release
2026.09.12, 112bae85c1a2), written so each item can become an issue
upstream. Each says what happens, how it was seen, what CyberTrain does
about it today, and what would fix it in Spinel. The evidence is in
[spikes/NOTES.md](../spikes/NOTES.md) (rules 22 and 56 to 59),
[benchmark.md](benchmark.md) and [performance-next.md](performance-next.md).

Suggested order: 1, 2, then 3 to 5, then the rest.

## Correctness

### 1. A generated `new` can free its own arguments (use-after-free)

`Foo.new(<a String made in the argument>)` allocates the object first, which
may run a collection, and roots its arguments only after that. A String
that only the argument holds (an interpolation, `code.strip`, a `+""` buffer
converted to a String) can be swept; the object keeps a dangling pointer and
a later read crashes.

- Seen as a SIGSEGV in 4 to 17% of the benchmark's seeding runs; located
  with an AddressSanitizer build (`spinel app.rb --cc=<wrapper running cc
  -fsanitize=address -fno-sanitize-address-use-after-scope -g>`,
  `ASAN_OPTIONS=fast_unwind_on_malloc=0`). Changing allocation counts moves
  the window, so unrelated commits looked like fixes.
- Today: bind the String to a local first, or pass it through an ordinary
  method (`SafeString.of`), whose parameters are rooted on entry (rule 58).
- Fix: root the arguments of the generated `new` before it allocates.

### 2. A parameter used only through `to_s` is narrowed to one caller's type

`Html.escape(value)` was typed as taking an Integer because one caller
passed one; Strings passed by other callers came out as `"0"`. A parameter
of a caller that is otherwise unused is typed as an Integer the same way.

- Seen in the router tests (wrong output, no error).
- Today: keep a `case value when String` on the parameter and pass
  `x.to_s` from callers (rule 56).
- Fix: unify the types of every call site, or widen to untyped instead of
  picking one.

## Runtime cost

On examples/blog, one core, about a fifth of each request is thread
hand-offs and another fifth is collection and malloc/free; neither can be
changed from the application except by allocating less.

### 3. Parking a fiber goes through the monitor thread

A connection's fiber that parks on `wait_readable` is woken by the
scheduler's monitor thread and handed back: about 16 `futex` calls per
request.

- Seen with `strace -c` and perf. A `wait_readable(0)` before the real wait
  did not change `futex` or `epoll_wait` counts (the next request is never
  there yet), and a blocking `readpartial` would hold the only worker.
- Fix: continue without a hand-off when the descriptor is already ready,
  or let the worker check readiness itself when `SPINEL_WORKERS=1`.

### 4. A collection stops every thread even with one worker

- None of `SPINEL_GC_AGE`, `SPINEL_GC_OBJ_BUDGET`, `SPINEL_GC_MINOR=0`, a
  larger `SPINEL_GC_THRESHOLD_KB` or `SPINEL_SCHED_POLL` beat the defaults.
- Fix: skip the stop-the-world rendezvous when there is one worker.

### 5. The system allocator

Linking jemalloc (`allocator = "jemalloc"` in spin.toml, or `LD_PRELOAD`)
gives 1.3 to 1.4 times the requests on the dynamic pages. It is not the
default because it needs jemalloc's development package to build.

- Fix: ship or vendor a faster allocator, or a size-class pool for the
  runtime's own small objects.

### 6. A `Mutex` on the request path stalls for seconds

A `Mutex#synchronize` taken on every request (a process-wide cache) stalled
requests for seconds with `SPINEL_WORKERS=2`; the two-core benchmark failed
about one run in two with wrk timeouts or a dead server, and five of five
passed once the lock was gone (rule 57).

- Today: no locks on the per-request path.
- Fix: find why an uncontended lock between two workers can wait that long
  (a fiber holding it while parked, or a missed wake-up).

## Typing and code generation

Each made code slower than it reads; all are in rule 56. `spinel
--emit-types` and `-S` were how they were found.

| What happens | Cost | What would fix it |
| --- | --- | --- |
| `"#{v}"` allocates and copies even when `v` is a String | an object per call | skip the copy for a single String interpolation |
| `Array#clear` anywhere makes that Array `sp_PolyArray` | every element access is dynamic | keep the element type through `clear` |
| An Array of the class that holds it is `sp_PolyArray` | same | type self-referencing element Arrays |
| A Hash with object values boxes them | every lookup is polymorphic | infer the value type |
| A nullable object parameter is boxed, and so is what returns it | the method's result is polymorphic | a nullable object type |
| A block (`each`, `map`, `times`) allocates a Proc and closure cells per call | the template interpreter's loops had to become `while` | inline blocks of known methods |
| `each { return ... }` compiles to `setjmp` and a Proc | slow early exits | a non-local return without `setjmp` when the block is inlined |
| `String#to_sym` searches the symbol table linearly | O(symbols) per call | a hashed symbol table |
| `str << int` makes a one-character String | an object per byte | append the byte directly |

## FFI and tools

- **`ffi_source` shares a translation unit with the runtime** (rule 59). An
  `extern` there must use the types already emitted (`const char *` for
  `sqlite3_column_text`, `long` for a `:long` return) or the build stops
  with "conflicting types". Document it, or compile `ffi_source` on its
  own.
- **A `:str` return always copies.** About 30 objects per article page are
  SQLite text columns. A borrowed or into-buffer return would let a caller
  avoid them.
- **`--emit-types`** was the most useful tool; naming the call site that
  widened a method to untyped would make it quicker still.
- **`SPINEL_ALLOC_REPORT` / `SPINEL_ALLOC_SITES`** gave deterministic object
  counts, which is what made progress measurable on a VM with 5 to 15% run
  to run noise. Symbol names in the report instead of offsets (now
  `addr2line` on each) would help.
