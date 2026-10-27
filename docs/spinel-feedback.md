# Feedback for Spinel

What building and speeding up CyberTrain found in Spinel itself, written so
each item can become an issue upstream. Each says what happens, how it was
seen, what CyberTrain does about it today, and what would fix it in Spinel.

Four builds are covered:

- **2026.09.12** (112bae85c1a2), matz/spinel's release, which CyberTrain
  was pinned to until 2026-10-26. Items 1 to 7 and the tables were found on
  it.
- **2026.10.25-7018** (0e3ccff, `spinel --version`: `unreleased
  (0e3ccffa8)`), a package of the
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) fork
  (`ghcr.io/saeki-mototsune/spinel`), checked on 2026-10-25 against
  CyberTrain 0a0d99e. `spin test` passed 88 of 98, and examples/blog did not
  get past `spin run gen`. The regressions are A to G at the end; an
  earlier package (2026.10.09-7009, edb9dd0, checked on 2026-10-13) is in
  [benchmark-spinel-2026.10.09.md](benchmark-spinel-2026.10.09.md).
- **2026.10.26.7019** (80b2f98), the fork's release tag carrying the fixes
  for A, C, F, G and 3, and the build CyberTrain is pinned to now
  (`Cybertrain::SPINEL_TAG`, `Cybertrain::SPINEL_REPOSITORY`). With the
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

The evidence is in [spikes/NOTES.md](../spikes/NOTES.md) (rules 22 and 56 to
59, 62), [benchmark.md](benchmark.md) and
[performance-next.md](performance-next.md).

Suggested order for what is still open: H (still present on master
9b9972399; fix proposed in matz/spinel#10415, not merged yet), and the two
shapes found in review (#10416 and #10417, not merged yet)
(see "Two shapes master 9b9972399 still gets wrong"), then deciding whether
CyberTrain keeps its workarounds for 1 and 2 (neither reproduced on master
9b9972399), then 4 to 7, then the rest. (B and D are settled as by design:
since 2026.10.26.7019 B is a build error, see B; D's `RangeError` is the
default `raise` mode's intended behaviour, and the experimental
`--int-overflow=promote` parses CRuby's Bignum, see D.)

## Status at a glance

"Not re-checked" means no one has tried it on that build; it is not a claim
that it is fixed.

| Item | 2026.09.12 | 2026.10.25-7018 | 2026.10.26.7019 | master 9b9972399 |
| --- | --- | --- | --- | --- |
| 1. A generated `new` frees its own arguments | yes | not re-checked | not re-checked | not reproduced (arguments rooted at the call site; no ASan run) |
| 2. A `to_s`-only parameter narrowed to one caller's type | yes | not re-checked | not re-checked | not reproduced (47 of 47 related test files pass without the workaround) |
| 3. An Array assigned to a wider local is copied | yes | yes | **fixed** | **fixed** (#10257) |
| 4 to 7. Runtime cost | yes | not re-measured | not re-measured | not re-measured |
| `String#to_sym` searches linearly | yes | **fixed** (hashed) | fixed | not re-checked |
| `"#{v}"` copies a String | yes | yes | yes | not re-checked |
| A. Block call inside `instance_eval` is `NoMethodError` | no | **yes** | **fixed** | **fixed** (#10254) |
| B. `ffi_func` declared under another name | no | yes (worked around) | by design: an undeclared call is a build error; CyberTrain declares it | by design (#10255) |
| C. Generated C that does not compile | no | yes, other shapes | **fixed** (not seen) | **fixed** (#10258, #10259); the template_engine.rb refusal is still made |
| D. `String#to_i` raises `RangeError` on overflow | no | yes (worked around) | yes (worked around, re-checked) | by design (raise mode); promote (experimental) parses a Bignum |
| E. More allocation per request | no | not re-measured | not re-measured | not re-measured |
| F. A call whose result is always nil is dropped | no | **yes** | **fixed** | **fixed** (#10260) |
| G. `<<` of a binary String keeps UTF-8, then a Regexp raises | no | **yes** | **fixed** | **fixed** (#10262) |
| H. A forwarded block's value loses an application class | no | not checked (predates b6ca774) | **yes** (new; worked around) | **yes** |
| `OpenSSL::Digest#to_s` is untyped | no (the package has none) | yes (why 3 shows in test/http_client.rb) | **fixed** (returns a String) | **fixed** (#10256) |
| Two shapes found in review (a Hash through a chain of locals into a constant; a `case` of 17 or more Array arms) | not checked | not checked | not checked | **yes** |

## What CyberTrain still works around

Re-checked on 2026-10-27 against matz/spinel master 9b9972399, built from
source; CyberTrain itself is still pinned to 2026.10.26.7019 (`spinel
2026.10.26.7019 (80b2f988)`), where the rows were checked on 2026-10-26
(the H row on 2026-10-27, when it was added). The regressions that release
fixes (A, the generated C of C, F, G, and 3) never had a workaround in
CyberTrain: it stayed on 2026.09.12, where they do not happen, until it
moved to 2026.10.26.7019. The refusal listed under C is separate: both
builds still make it, and CyberTrain's workaround for it stays. The first
four rows below are still needed on master 9b9972399; the last one did not
reproduce there, but is kept until it is decided whether to drop it:

| Workaround | Item | On 2026.10.26.7019 | On master 9b9972399 |
| --- | --- | --- | --- |
| `extern` declarations in the `ffi_source` of cybertrain/db/sqlite_ffi.rb | B | required: an undeclared call is now a build error | required (#10255) |
| `Request#content_length` refuses more than 18 digits before `to_i` (cybertrain/http/request.rb) | D | `"99999999999999999999".to_i` still raises `RangeError` | still raises `RangeError`, by design in the default `raise` mode; kept (`--int-overflow=promote`, experimental, parses it as a Bignum; see D) |
| test/template_engine.rb passes the layout's Hash as a call (`layout_env`) | refusal under C | the earlier form, through a local, is still refused | still refused at line 49, with #10316 merged |
| `DB.with`'s comment, and test/db_with_value.rb: an application object computed in a DB.with block goes through a local declared before it (rule 77) | H | required: the block's own value raises NoMethodError on a method call | required: both programs of H still raise `NoMethodError`; fix proposed in #10415 |
| `Html.escape`'s `case value when String`, `SafeString.of` and binding arguments to locals (rules 56, 58) | 1, 2 | not re-checked, kept | not reproduced in the shapes checked (see 1 and 2); kept until decided |

Every fix the fork carried is now in matz/spinel master, not only in the
fork (#10254 to #10263, and #10316). #10316 is the fork's
`fix/empty-hash-through-param`, which this document used to name for the
refusal under C; it is merged, and it does not remove that refusal (see C).
The row for H can be removed once its fix is in a build CyberTrain uses.
The row for D stays as long as CyberTrain builds in the default `raise`
mode, where the `RangeError` is by design (see D).

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

### 2. A parameter used only through `to_s` is narrowed to one caller's type

`Html.escape(value)` was typed as taking an Integer because one caller
passed one; Strings passed by other callers came out as `"0"`. A parameter
of a caller that is otherwise unused is typed as an Integer the same way.

- Seen in the router tests (wrong output, no error). A two-caller program
  (`esc(1)`, `esc("abc")`) does not show it on either build; it takes the
  router tests' shapes.
- Today: keep a `case value when String` on the parameter and pass
  `x.to_s` from callers (rule 56).
- Fix: unify the types of every call site, or widen to untyped instead of
  picking one.

Re-checked on 2026-10-27 on matz/spinel master 9b9972399: with
`Html.escape`'s `case value when String ... else "#{value.to_s}" end`
replaced by `str = value.to_s`, the 47 CyberTrain test files that mention it
or the router (`grep -lE "Html|escape|router|Router" test/*.rb`, 843 `test`
blocks between them) all pass under `spin test`. Not
reproduced; the workaround can be reconsidered, but this check does not
prove the general case.

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
A `case` of 17 or more arms still copies, see the next section.

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

### Two shapes master 9b9972399 still gets wrong

Found in review of the upstream fixes, and still wrong on matz/spinel
master 9b9972399 (2026-10-27). Fixes are proposed in matz/spinel#10416
(the chain of locals) and #10417 (the `case` of 17 or more arms), not merged
yet. As far as known
neither affects CyberTrain's own tests.

- **A Hash literal handed through a long chain of locals into a
  constant.** `a = {"x"=>1}; b = a; c = b; d = c; e = d; f = e; DEEP = f`,
  then a method that stores `DEEP["y"] = "s"`, raises `TypeError` at run
  time: "cannot store a String key with a String value into a hash Spinel
  typed as String-keyed with Integer values".
- **A `case` of 17 or more arms yielding Arrays**, assigned to a local that
  is then pushed to, loses the push: the Array is copied, as in 3.

## Runtime cost

On examples/blog, one core, about a fifth of each request is thread
hand-offs and another fifth is collection and malloc/free; neither can be
changed from the application except by allocating less. Measured on
2026.09.12; 2026.10.25-7018 was not measured (examples/blog does not build
on it, see A).

### 4. Parking a fiber goes through the monitor thread

A connection's fiber that parks on `wait_readable` is woken by the
scheduler's monitor thread and handed back: about 16 `futex` calls per
request.

- Seen with `strace -c` and perf. A `wait_readable(0)` before the real wait
  did not change `futex` or `epoll_wait` counts (the next request is never
  there yet), and a blocking `readpartial` would hold the only worker.
- Fix: continue without a hand-off when the descriptor is already ready,
  or let the worker check readiness itself when `SPINEL_WORKERS=1`.

### 5. A collection stops every thread even with one worker

- None of `SPINEL_GC_AGE`, `SPINEL_GC_OBJ_BUDGET`, `SPINEL_GC_MINOR=0`, a
  larger `SPINEL_GC_THRESHOLD_KB` or `SPINEL_SCHED_POLL` beat the defaults.
- Fix: skip the stop-the-world rendezvous when there is one worker.

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

None of these happens on 2026.09.12. First found on 2026.10.09-7009 (A to E, while
benchmarking, see
[benchmark-spinel-2026.10.09.md](benchmark-spinel-2026.10.09.md)),
re-checked, with F and G new, on 2026.10.25-7018, and fixed in the fork's
2026.10.26.7019 except D, which is by design in the default `raise` mode and
which CyberTrain works around, and B, which that release turns into a build
error by design (and E, not re-measured). Each section's reduced program
from A, C, F and G prints Ruby's result on 2026.10.26.7019. H is new on
2026.10.26.7019 itself. The fixes are merged into matz/spinel (#10254 to
#10263, 2026-10-26); on master 9b9972399 (re-checked on 2026-10-27) H is
still present, and D still raises, by design.

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
  values of other types into". Not a regression: the test's `{}` should be
  built where the call can widen it. Still refused on 2026.10.26.7019
  (re-checked on 2026-10-26 with the test's earlier form), and on matz/spinel
  master 9b9972399 (re-checked on 2026-10-27 with the earlier form,
  `git show 81778ea^:test/template_engine.rb`, refused at line 49), although
  #10316 ("An empty {} handed on through a parameter takes the Hash kind its
  callee wants", the fork's `fix/empty-hash-through-param`) is merged there:
  that fix does not cover this program. Fixed in CyberTrain by passing the
  Hash as a call (`layout_env`) instead of through a local.
- test/template_integration.rb (new): "a constant write given a Hash,
  which no conversion keeps in its `sp_StrPolyHash *` slot", at
  `Migration::Base::VERSIONS = begin h = { "" => "" }; h.delete(""); h end`
  (migration.rb:173), the seeding idiom of rule 9. If the refusal is
  intended, rule 9 needs another idiom; either way CyberTrain has to change
  for it. Not refused any more on 2026.10.26.7019, nor on matz/spinel
  master since #10261, so the idiom stays.

### D. `String#to_i` on more digits than an Integer holds raises `RangeError`

By design in the default `raise` mode, not a bug to fix.
On 2026.10.26.7019 (re-checked on 2026-10-26) and on matz/spinel master
9b9972399 (re-checked on 2026-10-27), `"99999999999999999999".to_i` raises
`RangeError: integer overflow parsing "99999999999999999999"` where
2026.09.12 saturated; CRuby returns a Bignum.

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

CyberTrain's workaround: DB.with's comment says to assign such a value to
a local declared before the block (as DB.transaction already requires),
and test/db_with_value.rb covers that form and a Boolean condition
(spikes/NOTES.md rule 77).

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
2026-10-27). Fixed in matz/spinel#10415, not merged yet: a read of the
forwarded `block` as a proc's value now marks the method as reading its
yields' value in every class walk, not only the closed one.

- Fix: carry the classes the block can return through the `&block`
  forward into the forwarding call's boxed value, as 2026.09.12 did.
