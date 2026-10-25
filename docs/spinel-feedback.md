# Feedback for Spinel

What building and speeding up CyberTrain found in Spinel itself, written so
each item can become an issue upstream. Each says what happens, how it was
seen, what CyberTrain does about it today, and what would fix it in Spinel.

Two builds are covered:

- **2026.09.12** (112bae85c1a2), the release CyberTrain is pinned to
  (`Cybertrain::SPINEL_TAG`). Items 1 to 7 and the tables were found on it.
  CI runs the 98 framework tests and examples/blog on it.
- **2026.10.25-7018** (0e3ccff, `spinel --version`: `unreleased
  (0e3ccffa8)`), the newest package of the
  [saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel) fork
  (`ghcr.io/saeki-mototsune/spinel:latest`), checked on 2026-10-25 against
  CyberTrain 0a0d99e. `spin test` passes 88 of 98, and examples/blog does
  not get past `spin run gen`. The regressions are A to G at the end; an
  earlier package (2026.10.09-7009, edb9dd0, checked on 2026-10-13) is in
  [benchmark-spinel-2026.10.09.md](benchmark-spinel-2026.10.09.md).

The evidence is in [spikes/NOTES.md](../spikes/NOTES.md) (rules 22 and 56 to
59, 62), [benchmark.md](benchmark.md) and
[performance-next.md](performance-next.md).

Suggested order: A and F (A breaks every app whose routes nest
`resources`, F loses a call silently), 1 to 3, then G, C and the rest of
the regressions, then 4 to 7, then the rest.

## Status at a glance

"Not re-checked" means no one has tried it on that build; it is not a claim
that it is fixed.

| Item | 2026.09.12 | 2026.10.25-7018 |
| --- | --- | --- |
| 1. A generated `new` frees its own arguments | yes | not re-checked |
| 2. A `to_s`-only parameter narrowed to one caller's type | yes | not re-checked |
| 3. An Array assigned to a wider local is copied | yes | yes |
| 4 to 7. Runtime cost | yes | not re-measured |
| `String#to_sym` searches linearly | yes | **fixed** (hashed) |
| `"#{v}"` copies a String | yes | yes |
| A. Block call inside `instance_eval` is `NoMethodError` | no | **yes** |
| B. `ffi_func` declared under another name | no | yes (worked around) |
| C. Generated C that does not compile | no | yes, other shapes |
| D. `String#to_i` raises `RangeError` on overflow | no | yes (worked around) |
| E. More allocation per request | no | not re-measured |
| F. A call whose result is always nil is dropped | no | **yes** |
| G. `<<` of a binary String keeps UTF-8, then a Regexp raises | no | **yes** |
| `OpenSSL::Digest#to_s` is untyped | no (the package has none) | yes (why 3 shows in test/http_client.rb) |

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

- Seen in the router tests (wrong output, no error). A two-caller program
  (`esc(1)`, `esc("abc")`) does not show it on either build; it takes the
  router tests' shapes.
- Today: keep a `case value when String` on the parameter and pass
  `x.to_s` from callers (rule 56).
- Fix: unify the types of every call site, or widen to untyped instead of
  picking one.

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
puts f(true)           # 1 on both builds; Ruby prints 2
```

- Seen on 2026.10.25-7018 in test/http_client.rb: `::ffff:127.0.0.1` was
  classified as "reserved" instead of "loopback", because
  `IpAddress.parse_ipv6`'s dotted-IPv4 tail went into the copy. It surfaced
  only there because on that build `parse_ipv4`'s `s = text.to_s` is boxed
  in that program: the openssl package's `OpenSSL::Digest#to_s` returns an
  untyped value, which leaves the result of every `x.to_s` on a boxed
  receiver untyped (rule 62's remedy then no longer narrows), and the bytes
  pushed into `groups` came out boxed.
- Today: nothing; the IPv6 parser works on 2026.09.12 because the bytes
  stay typed there.
- Fix: keep aliasing. Either widen the Array where it is made (the
  assignment shares its storage), or refuse the program at compile time
  instead of copying.

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
2026.10.25-7018, from its generated C for a small program.

| What happens | Cost | What would fix it | 2026.10.25-7018 |
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
  `ffi_func` by its C name needs one.
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
[benchmark-spinel-2026.10.09.md](benchmark-spinel-2026.10.09.md)) and
re-checked, with F and G new, on 2026.10.25-7018.

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

### A. A receiverless call with a block inside `instance_eval` is `NoMethodError`

Still present on 2026.10.25-7018.

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

Still present. The runtime declares them as `sp_ffi_fN_<name>` with an
`__asm__` label (`extern long sp_ffi_f0_strlen(const char *)
__asm__(SP_FFI_SYM("strlen"))`), so an `ffi_source` block calling one by
its C name gets an implicit declaration: `int`, a cut pointer, a SIGSEGV.
CyberTrain declares what it calls (db/sqlite_ffi.rb, aedcf4b), which works
on both builds. gcc 13 only warns; making
`-Werror=implicit-function-declaration` the default (gcc 14 does) would
have turned the crash into a build error.

### C. Generated C that does not compile

On 2026.10.25-7018:

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
  built where the call can widen it. CyberTrain's to fix.
- test/template_integration.rb (new): "a constant write given a Hash,
  which no conversion keeps in its `sp_StrPolyHash *` slot", at
  `Migration::Base::VERSIONS = begin h = { "" => "" }; h.delete(""); h end`
  (migration.rb:173), the seeding idiom of rule 9. If the refusal is
  intended, rule 9 needs another idiom; either way CyberTrain has to change
  for it.

### D. `String#to_i` on more digits than an Integer holds raises `RangeError`

Still present: `"99999999999999999999".to_i` raises `RangeError: integer
overflow parsing "99999999999999999999"` where 2026.09.12 saturated. CRuby
returns a Bignum; saturating, or raising only from `Integer()`, would keep
`to_i` total. test/http_request.rb passes now: `Request#content_length`
refuses more than 18 digits before calling `to_i` (977bfdb).

### E. More allocation per request

Measured on 2026.10.09-7009 only (examples/blog does not build on
2026.10.25-7018). An article page allocated 852 objects instead of 511
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
puts b.size            # 1 on 2026.10.25-7018; 0 on 2026.09.12 and in Ruby
```

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

2026.09.12 also said "UTF-8" but did not validate, so the scan worked.
Seen in test/send_blob.rb, which scans `Response#to_http` of a PNG
download. An application hits it when it matches a Regexp against a
response or request whose binary body holds bytes that are not valid
UTF-8 (a PNG or JPEG does; an ASCII-only body does not).

- Fix: follow CRuby's encoding of the result of `<<` (ASCII-only receiver
  plus a binary argument gives ASCII-8BIT).
