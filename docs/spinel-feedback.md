# Feedback for Spinel

What building and speeding up CyberTrain found in Spinel itself, written so
each item can become an issue upstream. Each says what happens, how it was
seen, what CyberTrain does about it today, and what would fix it in Spinel.

Seven builds are covered:

- **2026.09.12** (112bae85c1a2), matz/spinel's release, which CyberTrain
  was pinned to until 2026-10-26. Items 1 to 7 and the tables were found on
  it. Rebuilt from source on 2026-10-30 to measure 4 and 5 beside
  2026.10.27.7020, and to run J's program.
- **2026.10.25-7018** (0e3ccff, `spinel --version`: `unreleased
  (0e3ccffa8)`), a package of the
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) fork
  (`ghcr.io/saeki-mototsune/spinel`), checked on 2026-10-25 against
  CyberTrain 0a0d99e. `spin test` passed 88 of 98, and examples/blog did not
  get past `spin run gen`. The regressions are A to G at the end; an
  earlier package (2026.10.09-7009, edb9dd0) was checked on 2026-10-13.
- **2026.10.26.7019** (80b2f98), the fork's release tag carrying the fixes
  for A, C, F, G and 3, which CyberTrain was pinned to until 2026-10-28.
  With the
  toolchain `cybertrain setup` builds from that tag, `spin test` passes 98 of
  98 (test/template_engine.rb with its argument built where the call sees
  it, see C), and examples/blog's `spin run gen` writes files identical to
  the committed ones and its tests pass. The package
  `ghcr.io/saeki-mototsune/spinel:2026.10.26-7019`, built from the same
  commit, gave the same results.
- **matz/spinel master 9b9972399** (2026-10-28 01:58 +0900), built from
  source and checked on 2026-10-27. The fork's fixes are no longer only in
  the fork: they are merged into matz/spinel (all by SaekiMototsune, merged
  2026-10-26), #10254 (A), #10255 (B), #10256 (`OpenSSL::Digest#to_s` and
  `#hexdigest` typed), #10257 (3), #10258 and #10259 (the two shapes of C),
  #10260 (F), #10261 (the `VERSIONS` refusal under C), #10262 (G) and
  #10263 (`String#hex` and `#oct` past the word under
  `--int-overflow=promote`, see D), and #10316 ("An
  empty {} handed on through a parameter takes the Hash kind its callee
  wants", the fork's `fix/empty-hash-through-param`).
- **matz/spinel master 003ceda5d** (2026-10-28 05:13 +0900), built from
  source and checked on 2026-10-27, after the fixes for what 9b9972399
  still got wrong were merged (2026-10-27): #10415 (H), #10416 and #10417
  (the two shapes found in review). H's two programs and the three PRs'
  tests print Ruby's result there, and so do the reduced programs of 3, A,
  F and G; D's still raises `RangeError` in the default mode, by design.
  Items not listed were not re-checked on it.
- **2026.10.27.7020** (d37f38a), the fork's release tag carrying matz/spinel
  master up to #10415 to #10417, and the build CyberTrain is pinned to now
  (`Cybertrain::SPINEL_TAG`, `Cybertrain::SPINEL_REPOSITORY`; since
  2026-10-28). With the toolchain `cybertrain setup` builds from that tag,
  `spin test` passes 106 of 106 (checked on 2026-10-28), including
  test/db_with_value.rb's use of a DB.with block's own value, which H made
  raise on 2026.10.26.7019 (issue #90). Items 4 and 5 were re-measured on
  it on 2026-10-30 (see "Runtime cost"): 4 is fixed, and J was found on it.
- **fork master 49ccdced** (2026-10-30, "Merge branch 'matz:master'"),
  built from source and checked on 2026-10-30. It does not build CyberTrain
  (I, new; bisected to matz/spinel#10527); a minimal keep-alive server
  built with it gives 4 the same counts as 2026.10.27.7020, and J's program
  fails on it as on 2026.10.27.7020. Nothing else was checked on it.

The evidence is in [spikes/NOTES.md](../spikes/NOTES.md) (rules 22 and 56 to
59, 62), [benchmark.md](benchmark.md) and
[performance-next.md](performance-next.md).

Suggested order for what is still open: the refusal under C (the one
workaround left that a change in Spinel could remove; see "The refusal in
test/template_engine.rb" under C), then I (a regression on master that
would block the next pin; reduced and bisected), then J (a use-after-free
shown with the slab off, reduced; whether the default is affected is
open), then 5 (measured, with two concrete fixes), then 6 and 7 (4 is
fixed on 2026.10.27.7020, see 4), then the rest. B, D and 1
are not on that list: they are accepted as Spinel's constraints (see
"Accepted as Spinel constraints"). 2's workaround in `Html.escape` is dropped on
2026.10.27.7020 (see 2). H and the two shapes found in review are fixed on
master 003ceda5d (#10415 to #10417), and the fork's 2026.10.27.7020, which
CyberTrain is now pinned to, carries #10415: H's workaround is dropped
(issue #90). (B and D are settled as by design:
since 2026.10.26.7019 B is a build error, see B; D's `RangeError` is the
default `raise` mode's intended behaviour, and the experimental
`--int-overflow=promote` parses CRuby's Bignum, see D.)

## Status at a glance

"Not re-checked" means no one has tried it on that build; it is not a claim
that it is fixed.

| Item | 2026.09.12 | 2026.10.25-7018 | 2026.10.26.7019 | master 9b9972399 | master 003ceda5d | 2026.10.27.7020 | fork master 49ccdced |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1. A generated `new` frees its own arguments | yes | not re-checked | not re-checked | not reproduced (arguments rooted at the call site; no ASan run) | not re-checked | not reproduced under ASan, but neither on 2026.09.12 in that shape (workaround kept) | not re-checked |
| 2. A `to_s`-only parameter narrowed to one caller's type | yes | not re-checked | not re-checked | not reproduced (47 of 47 related test files pass without the workaround) | not re-checked | not reproduced (106 of 106 and examples/blog pass without the workaround; dropped) | not re-checked |
| 3. An Array assigned to a wider local is copied | yes | yes | **fixed** | **fixed** (#10257) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked |
| 4. Parking a fiber goes through the monitor thread | yes (re-measured on 2026-10-30: 9.9 `futex` per request) | not re-measured | not re-measured | not re-checked | not re-checked | **fixed** (2.1 `futex` per request, none on the park path; #8702, #10024) | same counts as 2026.10.27.7020 on a minimal server; examples/blog does not build (I) |
| 5. At one worker, most collections are full, and the sweep is handed to another thread | yes (as "a collection stops every thread") | not re-measured | not re-measured | not re-checked | not re-checked | **yes**, re-measured: the stop costs nothing at one worker, but 83% of collections are full (`SPINEL_GC_FULL_INTERVAL=8`: +16%) and the sweeper thread costs 5% on one CPU | not re-checked |
| 6 and 7. Runtime cost | yes | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured |
| `String#to_sym` searches linearly | yes | **fixed** (hashed) | fixed | not re-checked | not re-checked | not re-checked | not re-checked |
| `"#{v}"` copies a String | yes | yes | yes | not re-checked | not re-checked | not re-checked | not re-checked |
| A. Block call inside `instance_eval` is `NoMethodError` | no | **yes** | **fixed** | **fixed** (#10254) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked |
| B. `ffi_func` declared under another name | no | yes (worked around) | by design: an undeclared call is a build error; CyberTrain declares it | by design (#10255) | not re-checked | not re-checked | not re-checked |
| C. Generated C that does not compile | no | yes, other shapes | **fixed** (not seen) | **fixed** (#10258, #10259); the template_engine.rb refusal is still made | not re-checked | not re-checked | not re-checked |
| D. `String#to_i` raises `RangeError` on overflow | yes (re-checked on 2026-10-28; not a regression, see D) | yes (worked around) | yes (worked around, re-checked) | by design (raise mode); promote (experimental) parses a Bignum | by design (still raises `RangeError` in raise mode) | not re-checked | not re-checked |
| E. More allocation per request | no | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured | not re-measured |
| F. A call whose result is always nil is dropped | no | **yes** | **fixed** | **fixed** (#10260) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked |
| G. `<<` of a binary String keeps UTF-8, then a Regexp raises | no | **yes** | **fixed** | **fixed** (#10262) | **fixed** (its program prints Ruby's result) | not re-checked | not re-checked |
| H. A forwarded block's value loses an application class | no | not checked (predates b6ca774) | **yes** (new; worked around) | **yes** | **fixed** (#10415) | **fixed** (test/db_with_value.rb uses the block's own value) | not re-checked |
| I. A constant written `Array.new(n) { Obj.new }` is refused | no | no | no | not checked | not checked | no | **yes** (new; from 8594f2be2, matz/spinel#10527) |
| J. With the slab off, AddressSanitizer finds a thread's captured variables freed before it runs | no (no slab; passes under AddressSanitizer) | not checked | not checked | not checked | not checked | **yes** with `SPINEL_GC_SLAB=0`; the default is unknown | **yes** with `SPINEL_GC_SLAB=0` |
| `OpenSSL::Digest#to_s` is untyped | no (the package has none) | yes (why 3 shows in test/http_client.rb) | **fixed** (returns a String) | **fixed** (#10256) | not re-checked | not re-checked | not re-checked |
| Two shapes found in review (a Hash through a chain of locals into a constant; a `case` of 17 or more Array arms) | not checked | not checked | not checked | **yes** | **fixed** (#10416, #10417) | not re-checked | not re-checked |

## What CyberTrain still works around

Re-checked on 2026-10-27 against matz/spinel master 9b9972399, built from
source; CyberTrain itself was then pinned to 2026.10.26.7019 (`spinel
2026.10.26.7019 (80b2f988)`), where the rows were checked on 2026-10-26
(the H row on 2026-10-27, when it was added). Since 2026-10-28 it is
pinned to 2026.10.27.7020; the H row and the workarounds for 1 and 2
were re-checked there (2026-10-28). The regressions that release
fixes (A, the generated C of C, F, G, and 3) never had a workaround in
CyberTrain: it stayed on 2026.09.12, where they do not happen, until it
moved to 2026.10.26.7019. The refusal listed under C is separate: every
build checked still makes it (2026.10.26.7019, master 9b9972399 and
2026.10.27.7020), and CyberTrain's workaround for it stays. The first
four rows below are still needed on master 9b9972399; the last one did not
reproduce there, but is kept (see 1). The workaround for 2 in
`Html.escape` used to be in that row; it is dropped on 2026.10.27.7020
(see 2). Master
003ceda5d fixes H (#10415), and the H row is no longer needed now that
CyberTrain is pinned to 2026.10.27.7020, which carries it (issue #90):

| Workaround | Item | On 2026.10.26.7019 | On master 9b9972399 |
| --- | --- | --- | --- |
| `extern` declarations in the `ffi_source` of cybertrain/db/sqlite_ffi.rb | B | required: an undeclared call is now a build error | required (#10255) |
| `Request#content_length` refuses more than 18 digits before `to_i` (cybertrain/http/request.rb) | D | `"99999999999999999999".to_i` still raises `RangeError` | still raises `RangeError`, by design in the default `raise` mode; kept (`--int-overflow=promote`, experimental, parses it as a Bignum; see D) |
| test/template_engine.rb settles the layout Hash's value types where it is built (`layout_env`) | refusal under C | the earlier form, through a local, is still refused | still refused at line 49, with #10316 merged; still refused on 2026.10.27.7020 (see "The refusal in test/template_engine.rb") |
| `DB.with`'s comment, and test/db_with_value.rb: an application object computed in a DB.with block goes through a local declared before it (rule 77) | H | required: the block's own value raises NoMethodError on a method call | required: both programs of H still raise `NoMethodError`; fixed on master 003ceda5d (#10415). Dropped on 2026.10.27.7020: `DB.with`'s comment no longer asks for the local, and test/db_with_value.rb also covers the block's own value |
| `SafeString.of` and binding arguments to locals (rule 58) | 1 | not re-checked, kept | not reproduced in the shapes checked, which 2026.09.12 roots as well (see 1); kept |

Every fix the fork carried is now in matz/spinel master, not only in the
fork (#10254 to #10263, and #10316). #10316 is the fork's
`fix/empty-hash-through-param`, which this document used to name for the
refusal under C; it is merged, and it does not remove that refusal (see C).
The H row's workaround is dropped: CyberTrain is pinned to 2026.10.27.7020,
which carries #10415 (issue #90); the row stays as a record.
The row for D stays as long as CyberTrain builds in the default `raise`
mode, where the `RangeError` is by design (see D).

## Accepted as Spinel constraints

Decided on 2026-10-28: the workarounds for B, D and 1 are how CyberTrain is
written for Spinel, not debts to pay off. They are not targets for future
fixes, in CyberTrain or upstream: do not try to remove them, do not open
upstream issues or pull requests for them, and do not re-check them on
each new Spinel release. Revisit one only if Spinel itself changes the
behaviour behind it (its release notes or docs say so).

- **B, `extern` declarations in `ffi_source`.** Spinel's documented rule
  (docs/FFI.md): a fragment declares what it calls. Declaring
  `ffi_func`s under their C names inside Spinel would bring back the
  conflicting-types errors, so this is the intended way to write FFI code.
- **D, `Request#content_length` refusing more than 18 digits.** The
  `RangeError` is the default `raise` mode's intended behaviour (Matz,
  412a2200c). The guard is also correct HTTP input validation on its own: no
  real body is that long, so the request is refused either way.
- **1, `SafeString.of` and binding a String to a local before `new`.** No
  reduced program shows the bug on any build, so there is nothing to send
  upstream, and the idioms cost nothing. New code keeps following rule 58.

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

Re-checked on 2026-10-27 on matz/spinel master 9b9972399: for
`Foo.new("v#{i}".strip)` and `Foo.new("x#{i}" + "y")` the generated C roots
each argument at the call site (`SP_GC_ROOT(_t7)` before
`sp_Foo_new(_t7)`). Not reproduced in that shape; there was no
AddressSanitizer run, so this is not a claim that it is fixed in general.

Re-checked on 2026-10-28 on 2026.10.27.7020, and against 2026.09.12 for
comparison: the same two shapes, 200,000 times each in a loop, built with
AddressSanitizer, report no use-after-free on either build, and
2026.09.12's generated C roots each argument at the call site too
(`SP_GC_ROOT(_t6)` before `sp_Foo_new(_t6)`). So this shape never showed
the bug, and the check above says nothing about whether it is fixed; the
shape the benchmark crashed on has not been reduced. CyberTrain keeps
`SafeString.of` and the locals: they cost nothing, and the crash was rare
and moved with allocation counts. That check ran with the object slab on,
which hides a freed object from AddressSanitizer (the slab recycles its
slots itself; 2026.09.12 has no slab): on 2026.10.27.7020 a check has to
run with `SPINEL_GC_SLAB=0`, which found J.

### 2. A parameter used only through `to_s` is narrowed to one caller's type

`Html.escape(value)` was typed as taking an Integer because one caller
passed one; Strings passed by other callers came out as `"0"`. A parameter
of a caller that is otherwise unused is typed as an Integer the same way.

- Seen in the router tests (wrong output, no error). A two-caller program
  (`esc(1)`, `esc("abc")`) does not show it on either build; it takes the
  router tests' shapes.
- Today: callers pass `x.to_s` (rule 56); the `case value when String`
  that `Html.escape` kept on the parameter is dropped on 2026.10.27.7020.
- Fix: unify the types of every call site, or widen to untyped instead of
  picking one.

Re-checked on 2026-10-27 on matz/spinel master 9b9972399: with
`Html.escape`'s `case value when String ... else "#{value.to_s}" end`
replaced by `str = value.to_s`, the 47 CyberTrain test files that mention it
or the router (`grep -lE "Html|escape|router|Router" test/*.rb`, 843 `test`
blocks between them) all pass under `spin test`. Not
reproduced; the workaround can be reconsidered, but this check does not
prove the general case.

Dropped on 2026-10-28, on 2026.10.27.7020: with `str = value.to_s`, `spin
test` passes 106 of 106 and examples/blog's tests pass. In
test/template_integration.rb (the whole framework), `--emit-types` keeps
`value` untyped and types `str` as a String, so the byte loops still
compile to plain C. The callers' `x.to_s` (`SafeString#+`) stays.

### 3. An Array assigned to a local of a wider element type is copied

When pushes through a local make its element type wider than the Array
assigned to it, the assignment converts: `sp_PolyArray_from_int_array(...)`
makes a new Array, and every later `<<` goes to the copy. Ruby code that
picks one of two Arrays and appends to it loses the appends, silently.

```ruby
def pick(x) = x
pick("s")              # pick returns an untyped value
def f(gap)
  head = Array.new(0) { 0 }
  tail = Array.new(0) { 0 }
  tail << 1
  groups = gap ? tail : head
  groups << pick(2)    # a boxed value: groups becomes a PolyArray copy
  tail.size
end
puts f(true)           # 1 on 2026.09.12 and 2026.10.25-7018; 2 on 2026.10.26.7019 and in Ruby
```

**Fixed in 2026.10.26.7019**, together with the untyped
`OpenSSL::Digest#to_s` below, and test/http_client.rb passes there. Both
fixes are merged into matz/spinel (#10257, and #10256 for the Digest).
A `case` of 17 or more arms still copied on master 9b9972399; #10417 fixes
it, see the next section.

- Seen on 2026.10.25-7018 in test/http_client.rb: `::ffff:127.0.0.1` was
  classified as "reserved" instead of "loopback", because
  `IpAddress.parse_ipv6`'s dotted-IPv4 tail went into the copy. It surfaced
  only there because on that build `parse_ipv4`'s `s = text.to_s` is boxed
  in that program: the openssl package's `OpenSSL::Digest#to_s` returns an
  untyped value, which leaves the result of every `x.to_s` on a boxed
  receiver untyped (rule 62's remedy then no longer narrows), and the bytes
  pushed into `groups` came out boxed.
- Today: nothing; the IPv6 parser works on 2026.09.12 because the bytes
  stay typed there, and on 2026.10.26.7019 because the copy is gone.
- Fix: keep aliasing. Either widen the Array where it is made (the
  assignment shares its storage), or refuse the program at compile time
  instead of copying.

### Two shapes master 9b9972399 got wrong

Found in review of the upstream fixes, and still wrong on matz/spinel
master 9b9972399 (2026-10-27). **Fixed** by matz/spinel#10416 (the chain of
locals) and #10417 (the `case` of 17 or more arms), merged 2026-10-27:
on master 003ceda5d both print Ruby's result. As far as known neither
affected CyberTrain's own tests.

- **A Hash literal handed through a long chain of locals into a
  constant.** `a = {"x"=>1}; b = a; c = b; d = c; e = d; f = e; DEEP = f`,
  then a method that stores `DEEP["y"] = "s"`, raises `TypeError` at run
  time: "cannot store a String key with a String value into a hash Spinel
  typed as String-keyed with Integer values".
- **A `case` of 17 or more arms yielding Arrays**, assigned to a local that
  is then pushed to, loses the push: the Array is copied, as in 3.

## Runtime cost

On examples/blog, one core, about a fifth of each request was thread
hand-offs and another fifth collection and malloc/free on 2026.09.12;
neither can be changed from the application except by allocating less.
Measured on 2026.09.12; 2026.10.25-7018 was not measured (examples/blog
does not build on it, see A). 4 and 5 were re-measured on 2026-10-30 on
2026.10.27.7020, with 2026.09.12 rebuilt from source beside it (the method
is under 4): 4 is fixed. What remains of its `futex` count is the
collector's sweeper hand-off (see 5) and the monitor's time-based turns.

### 4. Parking a fiber goes through the monitor thread

**Fixed in 2026.10.27.7020** (re-measured on 2026-10-30). On 2026.09.12 a
connection's fiber that parks on `wait_readable` is woken through the
scheduler's monitor thread and the scheduler lock: about 16 `futex` calls
per request on the benchmark machine, 10 on the one below.

Both builds compiled from source on one 4-vCPU cloud VM, examples/blog in
production mode, `SPINEL_WORKERS=1`, `GET /articles`, 16 keep-alive
connections, 8,000 requests from a Python client that tops out near 2,700
requests a second, so the rates are not comparable here and the counts
are. Syscalls from `strace -f -c`, context switches from
`/proc/<pid>/task/*/status` without strace, threads told apart with
`strace --seccomp-bpf -f -e trace=futex` and the `futex` addresses
resolved against `nm` with ASLR off. The per-thread row is from its own
run under `strace --seccomp-bpf`, which stops the server only at the
traced calls: on 2026.10.27.7020 that run sums to 1.49 `futex` per
request against 2.08 under `strace -f -c`, which stops it at every
call and so makes the threads meet on their locks more often. The
thread that runs the connections is the helper worker on 2026.09.12
and main on 2026.10.27.7020, where main is the only worker.

| Per request | 2026.09.12 | 2026.10.27.7020 |
| --- | --: | --: |
| `futex` | 9.85 | 2.08 |
| OS thread context switches | 2.1 | 0.50 |
| `epoll_ctl` / `epoll_wait` / `poll` | 1.05 / 1.03 / 1.00 | 1.03 / 1.03 / 2.01 |
| `futex` by thread, from a second run (below) | helper worker 4.2, monitor 4.1, main 1.7 (10.0 in all) | GC sweeper 0.72, main 0.45, monitor 0.32 (1.49 in all) |

- What it was, on 2026.09.12: at `SPINEL_WORKERS=1` the connections ran
  on one helper OS thread beside main and the monitor. Every park woke the
  monitor (`g_sysmon_cv`), and every park and wake passed `g_sched_lock`
  between the three threads, each hand-over a `futex` wait and wake. The
  monitor made 7,492 turns for 8,032 parks (`SPINEL_SCHED_STATS=1`, on a
  minimal server). A `wait_readable(0)` before the real wait did not
  change the counts (the next request is never there yet), and a blocking
  `readpartial` would hold the only worker.
- What fixed it, upstream: per-worker readiness sets (#4306, in
  2026.09.12 already), the scheduler's hand-offs leaving the global lock
  and a park nudging the monitor only for an earlier deadline (#8702,
  2026-10-14), and a thread start waking the monitor only when its wait
  would end too late (#10024, 2026-10-23). On 2026.10.27.7020 a park is
  one `epoll_ctl` (a one-shot re-arm in the worker's own set) and one
  `epoll_wait` on the worker, no `futex`; the monitor made 630 turns for
  8,070 parks, and the worker thread switched out 92 times in 8,000
  requests. The two `poll` calls are the zero-timeout readiness checks
  before the `readpartial` and before the write. A minimal keep-alive
  server (one green thread per connection, `wait_readable(5)` before
  `readpartial`) goes from 7.5 `futex` per request on 2026.09.12 to 0.3,
  on 2026.10.27.7020 and on the fork's master 49ccdced alike.
- What is left: of the 1.49 `futex` per request in the per-thread run,
  the sweeper's 0.72 and most of main's 0.45 are the collector's
  concurrent-sweep hand-off (see 5), and the monitor's 0.32 are its
  time-based turns (about 215 a second under load), each taking
  `g_sched_lock`. None is on the park path.
- Also seen: an idle keep-alive connection costs more in CyberTrain than
  in that minimal server, because `head_readable?` re-parks it every
  `ACCEPT_POLL` (0.1 s) with a new deadline so that `#stop` is noticed.
  Each re-park is a timer expiry and a monitor turn under
  `g_sched_lock`. With the server on one CPU and the connections open
  for 10 s, 100 idle connections cost 1.6% of the CPU and 1,000 cost
  8.6% (2,349 context switches a second), growing with the connections;
  a server that parks each connection once with a 30 s timeout costs
  0.4 to 0.5% (about 140 switches a second, the monitor's and the
  trimmer's own) at either count. That is CyberTrain's design, not a
  Spinel issue: on 2026.10.27.7020 a `close` from another thread wakes a
  thread parked in `wait_readable(t)` on that socket at once, with
  `IOError` ("stream closed in another thread", as in CRuby; checked at
  `SPINEL_WORKERS=1` and 2), so the drain could close idle connections
  instead of each one polling the flag. See
  [performance-next.md](performance-next.md).
- Today: nothing; the pinned release has the fix.
- Fix: done.

### 5. At one worker, most collections are full, and the sweep is handed to another thread

Re-measured on 2026-10-30 on 2026.10.27.7020. The title this item had on
2026.09.12, "a collection stops every thread even with one worker", no
longer describes a cost: at `SPINEL_WORKERS=1` the stop-the-world waits
for nobody (`SPINEL_GC_PHASES=1`: 0.001 s waiting for workers to park over
2,852 collections). What costs at one worker now is when the collector
does a full mark, and that it hands the sweep to a sweeper thread.

Setup, beside 4's: examples/blog on 2026.10.27.7020, `SPINEL_WORKERS=1`,
the server pinned to one CPU (`taskset -c 0`, as bench/run's one-CPU
configuration does), and the load from three Python processes on the
other three CPUs, 16 keep-alive connections in all, 16,000 requests a run.
The server used 97 to 98% of its CPU in every run, so requests a second
measure it. Settings were alternated run by run, three runs each unless
noted; the spread between runs of one setting is 3 to 6%.

| `GET /articles`, one CPU | Requests a second | Server CPU per request | p99 latency | Full collections |
| --- | --: | --: | --: | --: |
| default | 2,930 | 0.331 ms | 9.3 ms | 83% of 5,784 |
| `SPINEL_GC_CONC=0` (no sweeper thread) | 3,084 (+5%) | 0.314 ms | 8.3 ms | 83% |
| `SPINEL_GC_FULL_INTERVAL=8` | 3,395 (+16%) | 0.285 ms | 7.7 ms | 12.5% of 4,814 |
| both | 3,444 (+18%) | 0.281 ms | 8.1 ms | 12.5% |

`GET /articles/1` moves the same way: +6% without the sweeper and +17%
with the interval fixed at 8. Peak RSS is 14 to 15 MB in every row.

- **Nearly every collection is a full one.** The full cadence adapts
  (`sp_gc_full_interval`, lib/sp_gc.c): when what the minors between two
  full collections promoted and the full then freed exceeds 1/16 of the
  live set per minor (`SP_GC_PROMOTED_DEAD_CUT`), the interval halves, down
  to 1, every cycle full. At 1 it tries 2 again after eight fulls, and
  goes back to 1. A server's in-flight requests are exactly that
  garbage: with a collection every 2.8 requests and 16 requests in flight,
  each minor promotes the objects of the requests being served, and they
  die as their responses go out, against a live set of 0.7 MB. Marking the
  whole live set on 83% of collections costs more than carrying that
  garbage for eight cycles: fixing the interval at 8 is worth 16 to 17%.
  The rule was added for an interpreter whose promoted frames were 13% of
  its live set per minor (390a0ec95, 2026-09-12); it weighs what is
  promoted against the live set, not against what a full mark costs.
  Aging, which keeps a first-time survivor young for one more minor and
  is what would keep request objects out of the old generation, is off
  whenever the slab allocator is on (`sp_gc_age_on` is cleared when
  `sp_slab_on`). With the slab off (`SPINEL_GC_SLAB=0`) aging cuts the
  full share from 83% to 51%, but the slab off costs 30% on its own (and
  is where J shows), so that is not a way out today.
- **The sweep goes to a thread that shares the CPU.** Since the
  concurrent sweep (f98add994, 2026-09-14, measured on a 32-core machine)
  the collector releases the world and hands the sweep to sweeper threads,
  `min(workers, 8)` of them, so one at `SPINEL_WORKERS=1` however many
  CPUs the process may use. On one CPU the hand-off is two `futex` wakes
  and a wait, and the sweeper preempts the worker to do the sweep it would
  have done itself: 1.64 context switches per request against 0.21, about
  half of them involuntary. Over ten alternated runs each, no sweeper gave
  +5.4% requests a second (3,083 against 2,925, Welch's t 2.4), 5.5% less
  CPU per request and 12% lower p99. The handed-off sweep also makes the
  slab's chunk release walk twenty times as many chunks (4.08 million in
  74,401 releases, against 0.2 million in 2,369). With four CPUs and the
  server unpinned, the sweeper's removal did not change requests a second
  (the client was the limit there).
- Re-tried on this build: a larger `SPINEL_GC_THRESHOLD_KB` (4096: a
  sixth of the collections and 4.5% of wall instead of 13%, but the same
  requests a second with the sweeper, and +12% instead of +5% without it,
  at 18 MB; 16384: 9% slower and twice the RSS), and `SPINEL_GC_MINOR=0`
  (+8%, less than the fixed interval).
- Today: nothing in CyberTrain. `SPINEL_GC_FULL_INTERVAL=8` (and
  `SPINEL_GC_CONC=0` on a one-CPU host) can be set in a deployment's
  environment; the deploy files `cybertrain new` writes mention only
  `SPINEL_WORKERS`.
- Fix: (a) do not let the promoted-garbage rule take the full cadence
  below the default when the live set is small, or weigh what a full mark
  costs (the live set it walks) against the promoted garbage it frees;
  or make aging work with the slab, so that a request's objects die young.
  (b) Start no sweeper thread when the process may use one CPU
  (`sp_available_cpus() == 1`, which already narrows by affinity and the
  cgroup quota): the collector then sweeps inline, as `SPINEL_GC_CONC=0`
  does, which the code already falls back to when no sweeper started.

### 6. The system allocator

Linking jemalloc (`allocator = "jemalloc"` in spin.toml, or `LD_PRELOAD`)
gives 1.3 to 1.4 times the requests on the dynamic pages. It is not the
default because it needs jemalloc's development package to build. (On
2026.10.09-7009 jemalloc no longer helped, see E.)

- Fix: ship or vendor a faster allocator, or a size-class pool for the
  runtime's own small objects.

### 7. A `Mutex` on the request path stalls for seconds

A `Mutex#synchronize` taken on every request (a process-wide cache) stalled
requests for seconds with `SPINEL_WORKERS=2`; the two-core benchmark failed
about one run in two with wrk timeouts or a dead server, and five of five
passed once the lock was gone (rule 57).

- Today: no locks on the per-request path.
- Fix: find why an uncontended lock between two workers can wait that long
  (a fiber holding it while parked, or a missed wake-up).

## Typing and code generation

Each made code slower than it reads; all are in rule 56. `spinel
--emit-types` and `-S` were how they were found. Status is for
2026.10.25-7018 and 2026.10.26.7019 (the same on both), from their generated
C for a small program.

| What happens | Cost | What would fix it | 2026.10.25-7018, 2026.10.26.7019 |
| --- | --- | --- | --- |
| `"#{v}"` allocates and copies even when `v` is a String | an object per call | skip the copy for a single String interpolation | still copies |
| `Array#clear` anywhere makes that Array `sp_PolyArray` | every element access is dynamic | keep the element type through `clear` | not re-checked |
| An Array of the class that holds it is `sp_PolyArray` | same | type self-referencing element Arrays | not re-checked |
| A Hash with object values boxes them | every lookup is polymorphic | infer the value type | not re-checked |
| A nullable object parameter is boxed, and so is what returns it | the method's result is polymorphic | a nullable object type | not re-checked |
| A block (`each`, `map`, `times`) allocates a Proc and closure cells per call | the template interpreter's loops had to become `while` | inline blocks of known methods | not re-checked |
| `each { return ... }` compiles to `setjmp` and a Proc | slow early exits | a non-local return without `setjmp` when the block is inlined | not re-checked |
| `String#to_sym` searches the symbol table linearly | O(symbols) per call | a hashed symbol table | **fixed**: hashed lookup |
| `str << int` makes a one-character String | an object per byte | append the byte directly | still builds a String (`sp_int_codepoint_to_str_in`) before appending |

## FFI and tools

- **`ffi_source` shares a translation unit with the runtime** (rule 59). An
  `extern` there must use the types already emitted (`const char *` for
  `sqlite3_column_text`, `long` for a `:long` return) or the build stops
  with "conflicting types". Document it, or compile `ffi_source` on its
  own. Since 2026.10.09-7009 the runtime's own declarations are under other
  names (B), so a conflicting `extern` no longer collides, but calling an
  `ffi_func` by its C name needs one (since 2026.10.26.7019 a build error
  without it, see B).
- **A `:str` return always copies.** About 30 objects per article page are
  SQLite text columns. A borrowed or into-buffer return would let a caller
  avoid them.
- **`--emit-types`** was the most useful tool; naming the call site that
  widened a method to untyped would make it quicker still.
- **`SPINEL_ALLOC_REPORT` / `SPINEL_ALLOC_SITES`** gave deterministic object
  counts, which is what made progress measurable on a VM with 5 to 15% run
  to run noise. Symbol names in the report instead of offsets (now
  `addr2line` on each) would help.
- **`--cc=<wrapper>`** is how a generated C file can be patched with
  `fprintf`s before it compiles; it found F.

## Regressions in newer packages

None of these happens on 2026.09.12, except D, which raises there too (see D). First found on 2026.10.09-7009 (A to E, while
benchmarking), re-checked, with F and G new, on 2026.10.25-7018, and fixed in the fork's
2026.10.26.7019 except D, which is by design in the default `raise` mode and
which CyberTrain works around, and B, which that release turns into a build
error by design (and E, not re-measured). Each section's reduced program
from A, C, F and G prints Ruby's result on 2026.10.26.7019. H is new on
2026.10.26.7019 itself. The fixes are merged into matz/spinel (#10254 to
#10263, 2026-10-26); on master 9b9972399 (re-checked on 2026-10-27) H is
still present, and D still raises, by design. H is fixed by #10415, merged
2026-10-27 (master 003ceda5d). I is new on the fork's master 49ccdced
(2026-10-30) and absent from 2026.10.27.7020. J is on both, seen only
with the object slab off, and absent from 2026.09.12.

On 2026.10.25-7018, the ten `spin test` failures:

| Test | Cause |
| --- | --- |
| gen_runner_models.rb | A |
| gen_namespaced.rb, gen_routes_compiles.rb | C (`view_assigns`) |
| client.rb, router.rb | C (attribute write in a route block) |
| http_response.rb | F |
| send_blob.rb | G |
| http_client.rb | 3, made visible by the untyped `OpenSSL::Digest#to_s` |
| template_engine.rb | a deliberate refusal (below C) |
| template_integration.rb | a new refusal (below C) |

On 2026.10.26.7019 only template_engine.rb failed, at the same deliberate
refusal; with its argument built where the call sees it, 98 of 98 pass.

### A. A receiverless call with a block inside `instance_eval` is `NoMethodError`

Present on 2026.10.25-7018; **fixed in 2026.10.26.7019** (the program
below prints `res x` and `res y`, and examples/blog's `spin run gen` writes
files identical to the committed ones). Merged into matz/spinel as #10254.

```ruby
class Mapper
  def initialize; @s = Array.new(0) { "" }; end
  def res(name, &block)
    @s << "res #{name}"
    block.call(self) unless block.nil?
    nil
  end
  def s = @s
end
m = Mapper.new
m.instance_eval do
  res(:x) { |a| a.res :y }   # undefined method 'res' for an instance of Mapper
end
puts m.s
```

The same call without a block, or with an explicit receiver
(`instance_eval do |r| r.res(:x) { ... } end`), works. It breaks every
app's `config/routes.rb` that nests `resources`: examples/blog's
`spin run gen` stops with "undefined method 'resources' for an instance of
Cybertrain::Gen::Mapper", and so does test/gen_runner_models.rb.

### B. `ffi_func` functions are no longer declared under their own names

The runtime declares them as `sp_ffi_fN_<name>` with an
`__asm__` label (`extern long sp_ffi_f0_strlen(const char *)
__asm__(SP_FFI_SYM("strlen"))`), so an `ffi_source` block calling one by
its C name gets an implicit declaration: `int`, a cut pointer, a SIGSEGV.
CyberTrain declares what it calls (db/sqlite_ffi.rb, aedcf4b), which works
on every build.

Settled in 2026.10.26.7019, as suggested here: the generated C is compiled
with `-Werror=implicit-function-declaration`, so the call above is a build
error instead of a crash. The private names stay (declaring the function
under its C name as well would bring back the conflicting-types errors),
and Spinel's docs/FFI.md says a fragment declares what it calls or
includes the header. CyberTrain's declaration is therefore required, not a
workaround to remove. Merged into matz/spinel as #10255.

### C. Generated C that does not compile

None of the shapes below is reported on 2026.10.26.7019, nor on matz/spinel
master, where their fixes are merged as #10258 (the dispatched call's
result) and #10259 (the attribute write). On 2026.10.25-7018:

- **A dispatched call's result is not boxed into a boxed local.**
  `assigns = view_assigns` in `Controller#view_env` (controller.rb:458),
  where the base class returns `{}` and generated controllers return
  `{ "viewer" => @viewer }`: the local is `sp_RbVal`, the switch over the
  subclasses yields `sp_StrPolyHash *`, and the assignment does not compile
  ("incompatible types when assigning to type `sp_RbVal` from type
  `sp_StrPolyHash *`"). test/gen_namespaced.rb and
  test/gen_routes_compiles.rb. On 2026.10.09-7009 the same methods failed
  one step earlier, in the overriding method's return type.
- **An attribute write in a route block, of a `to_s` value.**
  `router.get(...) { |c| c.response.body = c.request.header("X-Token").to_s }`
  (test/client.rb) and `{ |c| c.response.body = c.params[:a].to_s }`
  (test/router.rb): `c` is boxed (a Context or a Test::Client), and the
  write compiles to `iv_body = SP_STR_B(...)`, a `const char *` into an
  `sp_String *` field (`-Werror=incompatible-pointer-types`). A smaller
  program of the same shape compiles, so it takes something more of these
  programs; the generated C is the evidence.

The template lexer's `sp_poly_opnd_i` errors of 2026.10.09-7009
(cybertrain/template/lexer.rb lines 48 and 91) are not reported any more.

Two compile-time refusals, which name the line and stop instead of
generating wrong code:

- test/template_engine.rb (since 2026.10.09-7009): "a typed Hash is passed
  to `render_with_layout`'s parameter `env`, which the method stores keys or
  values of other types into". The next section has the details. Still refused on 2026.10.26.7019
  (re-checked on 2026-10-26 with the test's earlier form), and on matz/spinel
  master 9b9972399 (re-checked on 2026-10-27 with the earlier form,
  `git show 81778ea^:test/template_engine.rb`, refused at line 49), although
  #10316 ("An empty {} handed on through a parameter takes the Hash kind its
  callee wants", the fork's `fix/empty-hash-through-param`) is merged there:
  that fix does not cover this program. Fixed in CyberTrain by storing the
  title String into the Hash in `layout_env`, before it returns the Hash
  (see the next section: passing a call alone is still refused).
- test/template_integration.rb (new): "a constant write given a Hash,
  which no conversion keeps in its `sp_StrPolyHash *` slot", at
  `Migration::Base::VERSIONS = begin h = { "" => "" }; h.delete(""); h end`
  (migration.rb:173), the seeding idiom of rule 9. If the refusal is
  intended, rule 9 needs another idiom; either way CyberTrain has to change
  for it. Not refused any more on 2026.10.26.7019, nor on matz/spinel
  master since #10261, so the idiom stays.

#### The refusal in test/template_engine.rb

Still refused on 2026.10.27.7020 (re-checked on 2026-10-28 with the test's
earlier form, `git show 81778ea^:test/template_engine.rb`, refused at line
49). It is the one CyberTrain workaround left that a change in Spinel could
remove, and the candidate for an upstream pull request.

What happens: a Hash whose value type is settled in one method (say
String => Integer), returned, and passed on to a method that stores a value
of another type into it, is refused at the call. CRuby runs the program.
The message suggests building the argument from a hash literal the call can
see, which is not always possible: the Hash was built somewhere else.

```ruby
class Box
  def initialize(s)
    @s = s
  end
  def to_s
    @s
  end
end

def new_env
  env = {}
  env["n"] = 7
  env
end

def fill(env)
  env["content"] = Box.new("page")
  env.size
end

env = new_env
p fill(env)                # CRuby: 2
p env["content"].to_s      # CRuby: "page"
```

2026.10.27.7020 refuses it:

```
spinel: refusal.rb:22: a typed Hash is passed to `fill`'s parameter `env`, which the method stores keys or values of other types into: the caller's hash cannot hold them, and a converted copy would not see the stores. Build the argument from a hash literal the call can see, so it is widened with the parameter.
spinel: 1 refusal, nothing written
```

Variations, all on 2026.10.27.7020:

| Shape | Result |
| --- | --- |
| The program above (Hash from `new_env` through a local) | refused |
| `fill(new_env)`, the call itself as the argument | refused |
| `env = new_env; env["title"] = "x"; fill(env)` (the caller widens it to String and Integer values first; this is test/template_engine.rb's earlier form) | refused |
| The `"title"` store moved into a method that returns the Hash (`def titled_env; env = new_env; env["title"] = "x"; env; end`, then `fill(titled_env)`) | compiles, prints CRuby's result |
| `env = {}; env["n"] = 7; fill(env)` at the call site, the literal visible to the call | compiles, prints CRuby's result |
| The program above storing a String (`"page"`) instead of a `Box` | compiles and prints CRuby's result, with `warning: type inference did not converge in 128 rounds` |

So in the shapes checked, what decides it is where the Hash's value type
is settled, not whether it reaches the call through a local: a Hash whose
values are already polymorphic when it leaves the method that builds it is
accepted, and a Hash whose only value type is Integer is refused when the
callee stores a `Box`, even when the caller widens it afterward. Storing a
String instead compiles (last row), so not every Hash with one value type
is refused.

A related shape is accepted but wrong at run time. When the literal is
visible to the call and the callee also reads the Integer before storing
the object, the program raises:

```ruby
def fill(env)
  n = env["n"]
  env["content"] = Box.new("page")
  n
end

env = {}
env["n"] = 7
p fill(env)                # CRuby: 7
```

2026.10.27.7020 compiles it and prints `wrong argument type Integer
(expected Box) (TypeError)`. 2026.09.12 generates C that does not compile.
That is wrong code, not a refusal, and the more serious of the two for an
upstream report. With a String stored instead of a `Box` it prints CRuby's
result.

Who meets it: anyone who builds a Hash in one method and hands it to
another that adds values of another type. In CyberTrain that is a caller of
`Engine#render_with_layout`, which stores the rendered page into `env`
(`env["__content"] = SafeString.of(...)`). `Controller#render` is not
affected, because the controller builds its environment where the store
widens it. An application that calls the Engine directly is.

What would fix it in Spinel: widen a Hash where it is built when a store
reached through a parameter needs a wider type, following the Hash back
through method returns and locals (#10316 does this for an empty `{}`
handed on through a parameter, not for a Hash returned from a method). If
that is too wide a change, the refusal message should at least name what
works ("settle the Hash's value types in the method that builds it"), since
building it from a literal at the call is often not possible. The run-time
`TypeError` above needs a fix either way: the callee's read of `env["n"]`
must use the widened value type.

Today: test/template_engine.rb builds the Hash in `layout_env`, which
stores the title String into it before returning it, so its values are
already polymorphic when it reaches `render_with_layout`. It is
`layout_env`'s store that matters; passing the call instead of a local
alone is still refused (second row of the table).

Not reported upstream yet.

### D. `String#to_i` on more digits than an Integer holds raises `RangeError`

By design in the default `raise` mode, not a bug to fix.
On 2026.10.26.7019 (re-checked on 2026-10-26) and on matz/spinel master
9b9972399 (re-checked on 2026-10-27), `"99999999999999999999".to_i` raises
`RangeError: integer overflow parsing "99999999999999999999"`; CRuby returns
a Bignum. 2026.09.12 raises the same `RangeError`, for a literal and for a
run-time String (re-checked on 2026-10-28 on a build of its commit,
112bae85c1a2): D was never a regression. This document used to say
2026.09.12 saturated, after spikes/NOTES.md rule 25, which 977bfdb
(2026-10-22) already corrected; the raise has been there since 412a2200c
(2026-05-27), which that release includes.

- Why: upstream 412a2200c (Matz, 2026-05-27, "runtime: to_i / Integer() on
  overflowing input raise RangeError", fixes #842) replaced the silent
  saturation at INT64_MAX on purpose, because it hid the precision loss
  and made `rescue RangeError` ineffective. Spinel's docs/int-overflow.md
  describes the default `raise` mode as catching overflow loudly, never
  silently wrong, and as a deliberate deviation from CRuby;
  docs/limitations.md lists Integer overflow under "By design".
- `--int-overflow=promote` is experimental in Spinel's own words
  (docs/int-overflow.md): its coverage is not complete, and some overflow
  paths through method arguments, closures and certain containers still
  raise rather than promote. For the parse itself it gives CRuby's answer:
  in the shapes checked on master 9b9972399 (and before that on
  0d0a621fb), `String#to_i`, `to_i(base)`, `Integer()` (also with
  `exception: false` and `"0x..."`), `hex` and `oct` return the same
  Bignum CRuby does, for literals and for run-time Strings
  (ARGV, a Hash value, a method parameter) (upstream 317d9bbe8, 2026-09-26,
  "promote mode reads String#to_i and Integer() past sp_int as a Bignum";
  #10263 covers `String#hex` and `#oct` past the word in that mode). What
  the program then does with the Bignum is outside those checks.
- Today: test/http_request.rb passes because `Request#content_length`
  refuses more than 18 digits before calling `to_i` (977bfdb). CyberTrain
  keeps that guard. Building with `--int-overflow=promote` would be an
  alternative only once the whole program is known to work in that mode.

### E. More allocation per request

Measured on 2026.10.09-7009 only (examples/blog did not build on
2026.10.25-7018; 2026.10.26.7019 is not measured yet). An article page allocated 852 objects instead of 511
(same source): about 136 more boxed Arrays from `each_key` on a
polymorphic Hash (`sp_poly_each_elem`), about 92 more Strings inside
`sp_StrPolyHash_set`, and about 50 more internal objects. With jemalloc the
pages were 7 to 15% slower than on 2026.09.12; with system malloc the other
gains covered it.

### F. A call whose result is always nil is dropped when passed to a typed parameter

New on 2026.10.25-7018, and silent. When a method that always returns nil
is called as the argument of a parameter typed otherwise (here a String),
the argument compiles to the constant `NULL`: the call, with its side
effects, is gone.

```ruby
class Box
  def initialize = @items = ["a"]
  def clear!
    @items.clear
    nil
  end
  def size = @items.size
end
def check_nil(v)
  puts(v.nil? ? "nil" : "got #{v.inspect}")
end
check_nil "x"          # v is typed String
b = Box.new
check_nil b.clear!     # compiled as check_nil(NULL): clear! never runs
puts b.size            # 1 on 2026.10.25-7018; 0 on 2026.09.12, 2026.10.26.7019 and in Ruby
```

**Fixed in 2026.10.26.7019**, and merged into matz/spinel as #10260.

Seen in test/http_response.rb: `assert_nil res.drop_header("Location")`
compiled to `sp_assert_nil(NULL)`, so the header was never dropped and the
next assertion failed. Tests are where this shape is common (`assert_nil`
around a mutating call), and they then test nothing.

- Fix: evaluate the argument for its side effects, then pass nil.

### G. `<<` of a binary String keeps UTF-8, then a Regexp raises

New on 2026.10.25-7018. Appending an ASCII-8BIT String to an ASCII-only
UTF-8 String leaves the result UTF-8 (CRuby makes it ASCII-8BIT), and a
Regexp on it now validates the encoding and raises:

```ruby
body = "\x89PNG\r\n".b
out = +"HTTP/1.1 200 OK\r\n"
out << "X-A: 1\r\n\r\n"
out << body
p out.encoding.to_s           # "UTF-8"; Ruby: "ASCII-8BIT"
p out.scan(/^x-a:/i).length   # ArgumentError: invalid byte sequence in UTF-8; Ruby: 1
```

**Fixed in 2026.10.26.7019** (it prints "ASCII-8BIT" and 1, as Ruby does),
and merged into matz/spinel as #10262.

2026.09.12 also said "UTF-8" but did not validate, so the scan worked.
Seen in test/send_blob.rb, which scans `Response#to_http` of a PNG
download. An application hits it when it matches a Regexp against a
response or request whose binary body holds bytes that are not valid
UTF-8 (a PNG or JPEG does; an ASCII-only body does not).

- Fix: follow CRuby's encoding of the result of `<<` (ASCII-only receiver
  plus a binary argument gives ASCII-8BIT).

### H. A forwarded block's value loses an application class

New on 2026.10.26.7019 (reported downstream on 2026-10-27, issue #27;
2026.10.25-7018 not checked; the reporter saw it pass on matz/spinel's
2026.10.25 release, which only hid it: see the bisection below). When a method forwards its block with `&block` to a
yielding method, and the program's blocks for it return different types,
the forwarding call's value is boxed without the class of an application
object: calling a method on it raises `NoMethodError`, and the method is
not even emitted.

```ruby
class Pool; def with; begin; yield 1; ensure; nil; end; end; end
module Db; @pool = Pool.new; def self.with(&block) = @pool.with(&block); end
class Result; def ok? = true; end
def result_of = Db.with { |c| Result.new }
p result_of.ok?      # undefined method 'ok?' for an instance of Result (NoMethodError);
                     # true on 2026.09.12 and in Ruby
p Db.with { |c| 1 }  # without this second block, or calling Pool#with directly: true
```

The generated C dispatches `ok?` with a `switch` that has only the
`default:` NoMethodError case; 2026.09.12's has `case <Result>:`. Builtin
values (Arrays, Hashes, Integers, Strings, true/false) still dispatch, so
CyberTrain's own `Cybertrain::DB.with` sites, which return rows and
Integers, are unaffected, and its 98 test programs pass. An application's
`DB.with { |c| ... }` that returns its own object breaks, because the
framework's blocks already make DB.with's value polymorphic. The reporter
also saw a Boolean block value refused as a condition ("unsupported
condition (non-bool)") in a larger program; that was not reproduced.

CyberTrain's workaround while it was pinned to 2026.10.26.7019: DB.with's
comment said to assign such a value to a local declared before the block
(as DB.transaction already requires), and test/db_with_value.rb covered
that form and a Boolean condition (spikes/NOTES.md rule 77). Since the pin
moved to 2026.10.27.7020, which carries the fix below, the comment no
longer asks for it, and the test also covers the block's own value, which
raises the reported `NoMethodError` on 2026.10.26.7019 (issue #90).

Bisected on 2026-10-27 between matz/spinel's 2026.10.25 release (2814693f6)
and the fork's 2026.10.26.7019, whose compiler is matz/spinel master
9d1040375 (the fork adds only its Docker image files). The first bad commit
is upstream b6ca77437 (2026-10-25, "superclass answers its parents' Class
objects, and a dynamic name's method takes what dynamic calls hand on",
src/analyze_cls.c only). It exposes an older gap rather than adding one:

- The gap: the class analysis does not carry a block's value class from
  the call site, through the `&block` forward, into the inner yield's
  value once a second call site passes a block of another type. A program
  with no dynamic name already fails on 2026.10.25:

  ```ruby
  class R; def ok? = true; end
  def run_block = yield(0)
  def with(&block) = run_block(&block)
  p with { |c| 1 }
  r = with { |c| R.new }
  puts r.ok?   # NoMethodError on 2026.10.25 and on 2026.10.26.7019
  ```

- What hid it: a call to `method` (or `send`, `public_send`) with a
  computed name, or with no name at all as in `req.method`, makes every
  method name dynamic (a literal Symbol or String name, `method(:m)`,
  makes only that one dynamic), and until b6ca77437 a dynamic name's
  method had its parameters, its `&block` one included, seeded with every
  class. The forwarded value then held every
  class, and `r.ok?` dispatched over every class that defines `ok?`.
  CyberTrain programs always have such a call (`Request#method`, called
  as `req.method` in cybertrain/middleware/csrf_protection.rb and
  cybertrain/http/request.rb), which is why the reporter's program passed
  on 2026.10.25. Adding `class Req; attr_reader :method; def initialize =
  (@method = "GET"); end` and `puts Req.new.method` to the program above
  makes it print `true` on 2026.10.25.
- What b6ca77437 changed: a dynamic (not opaque) name's parameters now
  take a `dynarg` element, and the `&block` parameter only the builtin
  values, so the gap shows again.

Still present on matz/spinel master b7007eb8b (2026-10-27), and on master
9b9972399: both programs above still raise `NoMethodError` (re-checked on
2026-10-27). **Fixed** by matz/spinel#10415, merged 2026-10-27: on master
003ceda5d both programs print Ruby's result. A read of the forwarded
`block` as a proc's value now marks the method as reading its yields'
value in every class walk, not only the closed one, and so does a block
forwarded to a receiverless call of a method of the same class
(`def forward(&block) = run(&block)`), which review of the PR found.

- Fix: carry the classes the block can return through the `&block`
  forward into the forwarding call's boxed value, as 2026.09.12 did.

### I. A constant written `Array.new(n) { Obj.new }` is refused

New on the fork's master 49ccdced (2026-10-30, "Merge branch
'matz:master'"), built from source on 2026-10-30; 2026.10.27.7020 builds
the same source. In examples/blog, `spin build blog` stops with:

```
spinel: warning: type inference did not converge in 128 rounds; the output may be built from unsettled types (please report this program)
spinel: cybertrain/controller.rb:111: a constant write given a Array, which no conversion keeps in its sp_PtrArray * slot
spinel: 1 refusal, nothing written
```

Line 111 is `NO_SKIPS = Array.new(0) { Callback.new(:skip, nil, nil, [],
[], -1) }`, the Array seeded with its element type and emptied
(spikes/NOTES.md rule 9). Of CyberTrain's tests, test/controller_status.rb
makes the same refusal and test/controller.rb does not; `spin test` was
not run in full on that build. Reduced (prints `0` in Ruby and on
2026.10.27.7020; refused, with the same warning, on 49ccdced):

```ruby
class Cb
  attr_reader :name
  def initialize(name) = (@name = name)
end
NONE = Array.new(0) { Cb.new(nil) }
p NONE.size
```

The same write inside a class (`K::NONE`) is refused too. These are not:
a literal (`[Cb.new(:a)]`), `[1, 2].map { |i| Cb.new(i) }`,
`Array.new(2) { |i| Cb.new(i) }.freeze`, a method's return value, and
`Array.new(0) { ... }` assigned to a local.

Bisected on 2026-10-30 (`git bisect run` on the fork's history between
2026.10.27.7020 and 49ccdced, test/controller_status.rb compiled with
`-c`): the first bad commit is 8594f2be2 (2026-10-29, "Narrow an object
table handed to its elements' methods, and a constant one", merged as
matz/spinel#10527). It gives a constant that holds a table of objects a
slot of its own, narrowed to `sp_PtrArray *`, and takes the constant's
statement-position writes as its sources (`narrow_object_arrays`, step
5a' in src/analyze.c). The value of the write is classified as a local's
would be, and `Array.new(n) { obj }` passes as an object table. Only an
Array literal, though, is noted as built in place at the narrowed kind
(`oa_note_src` is called for an `ArrayNode` alone): `Array.new`'s value
is still built boxed, and the write of a boxed Array into the narrowed
slot is refused.

- Today: nothing to do; CyberTrain is pinned to 2026.10.27.7020. If a
  later release keeps the refusal, a `.freeze` on the `Array.new`, or
  `[Callback.new(...)][0, 0]`, avoids it: both forms of the reduced
  program print Ruby's result on 49ccdced and on 2026.10.27.7020.
- Fix: in step 5a', kill the constant's slot (keep it boxed) when a write's
  value is not an Array literal, or build `Array.new(n) { ... }` at the
  narrowed kind as a literal is; and add the program above as a test
  beside test/object_array_constant.rb.

### J. With the slab off, AddressSanitizer finds a thread's captured variables freed before it runs

Found on 2026-10-30 on 2026.10.27.7020 while re-measuring 5, and present on
the fork's master 49ccdced; not on 2026.09.12. The object slab
(`lib/sp_slab.c`, on by default) recycles freed slots itself, so an
AddressSanitizer build sees a use-after-free only when the slab is off
(`SPINEL_GC_SLAB=0`, which allocates every object with `calloc`). With it
off, this program fails under AddressSanitizer in every run (3 of 3 on
2026.10.27.7020, 2 of 2 on 49ccdced) when a client opens and closes
connections quickly (8 at a time, each sending one to three requests),
`SPINEL_WORKERS=1`:

```ruby
require "socket"

class Srv
  def run(port)
    server = TCPServer.new("127.0.0.1", port)
    Thread.new { accept_loop(server) }.join
  end

  def accept_loop(server)
    while true
      spawn_connection(server.accept) unless server.wait_readable(0.1).nil?
    end
  end

  def spawn_connection(sock)
    Thread.new { serve(sock) }
  end

  def serve(sock)
    while !sock.wait_readable(5).nil?
      req = sock.readpartial(4096)
      body = "#{req.bytesize} #{Time.now.to_f}\n" * 20
      sock.write("HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    end
  rescue EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE
  ensure
    sock.close unless sock.closed?
  end
end

Srv.new.run((ARGV[0] || "3570").to_i)
```

- What AddressSanitizer reports: the 64-byte object allocated at
  `Thread.new { serve(sock) }` in `spawn_connection` (the block's capture
  struct, `_fib_cap_Srv_spawn_connection_1`, holding `self` and `sock`) is
  freed by a collection that another connection's `serve` started, and is
  then read by the new thread's fiber body on its first line
  (`sp_Srv *self = _fc->self_ptr`). The same happens with
  `SPINEL_GC_CONC=0` (3 of 3) and with `SPINEL_GC_MINOR=0` (2 of 2), so
  neither the concurrent sweep nor the minor collection is needed for it.
  Built by 2026.09.12, which has no slab and so lets AddressSanitizer see
  every object, the same program passed 2 of 2.
- What was ruled out: the generated code roots the fiber and the capture
  struct across the allocations and stores the struct into the fiber's
  `user_data` behind a write barrier; the fiber's scan marks `user_data`,
  and the live-thread registry marks every thread record, whose scan marks
  its fiber. A counting variant of the program started `serve` exactly as
  many times as it spawned threads (4,002 of 4,002, slab on and off), so a
  finished thread is not run a second time. Where the chain breaks for a
  thread that has been spawned but has not started is not known.
- In examples/blog under the same conditions, AddressSanitizer reports
  this and a second one: the frozen String `Module#name` caches
  (`sp_str_frozen_name`, used by `Controller.chain_for`'s `k.name`) freed
  by the object sweep and read again on a later request. A plain build
  with the slab off also dies with SIGSEGV (in `sp_Controller_run_action`
  where gdb caught it): 6 of 31 loaded runs, and 1 of 2 runs of 12,000
  short connections.
- Whether the default (slab on) is affected is open. A plain build with
  the slab on did not crash in over 70 loaded runs and 36,000 short
  connections, but the collector decides what to free the same way with
  the slab on or off, and the slab can hand out a freed slot again
  later. An AddressSanitizer build with the slab on stopped in 5 of 6
  runs with a wild read inside `serve`'s `rescue StandardError` (a block
  that plain builds never entered in any run), which may be an artifact of
  AddressSanitizer and fiber stack switching rather than this bug.
- Today: nothing in CyberTrain; it runs with the slab on.
- Fix: find why a spawned thread's capture struct is unreachable before
  the thread first runs, and add the program above to the tests with an
  AddressSanitizer job that runs with `SPINEL_GC_SLAB=0`, since the slab
  hides this class of bug from AddressSanitizer.
