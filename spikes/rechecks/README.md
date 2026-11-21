# Retained compiler rechecks

Each program here is evidence for an item of
[docs/spinel-feedback.md](../../docs/spinel-feedback.md), named in the
table below, and is kept until that item is closed there ("Item register"
says what closed means). A program that now prints CRuby's result is still
kept: passing is not closed. The rules written because of the items are in
[NOTES.md](../NOTES.md). None of these programs is a claim that a
workaround can be removed from the whole framework.
Run them explicitly; they are not part of `spin test` or the CI gate.

What this file and the programs' headers say a program did is the run that
produced the program and its `.expected` file, with its date, machine and
tools. It is not brought up to a later pin: what a program did on each pin
is in docs/spinel-feedback.md, "Status by rule".

## Programs and their items

A file of several sections is kept section by section: a section goes when
its item is closed, and a section whose item is a constraint or a record
is permanent. `run.sh` runs the programs of this directory and belongs to
none of them.

| Program | Item | Rules | Kept until |
| --- | --- | --- | --- |
| `value_shapes.rb` | rule 12, rule 18, rule 60 | 12, 18, 60 | each is closed |
| `exception_shapes.rb` | AE, rule 46 | 46, 47, 53, 54 | AE and rule 46 are closed |
| `openssl_dispatch.rb` | rule 62 | 62 | rule 62 is closed |
| `decimal.rb` | not a Spinel item: a probe for docs/design.md D42 | | while D42 stands |
| `dispatch_shapes.rb` | rule 1 to rule 6, rule 30, rule 31, rule 40, rule 42 | 1 to 6, 30, 31, 40, 42 | each is closed; the sections of rules 1, 2 and 5 (constraints) are permanent |
| `type_shapes.rb` | rule 7 to rule 11, rule 14, rule 26, rule 29, rule 34, rule 35, rule 37, rule 39, rule 41, rule 43, rule 46 | 7 to 11, 14, 26, 29, 34, 35, 37, 39, 41, 43, 46 | each is closed |
| `constant_order.rb` | AV (the half of rule 17 that matches CRuby: a constant assigned with `=`) | 17 | AV is closed |
| `io_shapes.rb` | rule 19, rule 28 | 19, 28 | each is closed |
| `socket_shapes.rb` | rule 21, AW (the reads of rule 27 that match CRuby) | 21, 27 | each is closed |
| `socket_bare_readpartial.rb` | rule 20 | 20 | rule 20 is closed |
| `rescue_shapes.rb` | rule 32, rule 44, rule 45, rule 50, AE | 32, 44, 45, 47, 50 | each is closed |
| `json_error_shapes.rb` | rule 33, rule 48, rule 61 | 33, 48, 61 | each is closed |
| `block_call_shapes.rb` | rule 69 | 69 | rule 69 is closed |
| `container_shapes.rb` | rule 51, rule 55, Q | 51, 55, 86 | each is closed |
| `outbound_socket_shapes.rb` | rule 72 (not O, which is `connect_timeout:`) | 72 | rule 72 is closed |
| `invalid_utf8_shapes.rb` | AD, AU (the calls of rule 52 that match CRuby) | 52 | AD and AU are closed |
| `builtin_superclass_no_module.rb` | AJ | 104 | AJ is closed |
| `json_nesting_shapes.rb` | rule 61 | 61 | rule 61 is closed |
| `define_method_shapes.rb` | rule 1 (a constraint: no run-time code) | 1 | permanent |
| `builtin_superclass_with_module.rb` | AJ | 104 | AJ is closed |
| `nil_only_puts_openssl.rb` | K | 78 | K is closed |
| `float_range_boxed.rb` | Q | 86 | Q is closed |
| `differing/env_nonliteral_key.rb` | AS | 123 | AS is closed |
| `differing/require_in_regex.rb` | AR | 122 | AR is closed |
| `differing/invalid_utf8.rb` | AD, AU | 52 | AD and AU are closed |
| `differing/rescue_from_json_error.rb` | rule 48 | 48 | rule 48 is closed |
| `differing/class_before_definition.rb` | AV | 17 | AV is closed |
| `differing/socket_bytes.rb` | AW | 27 | AW is closed |

## The first four programs, 2026-11-11

Recorded on 2026-11-11 against framework base `72104d7`: Linux x86_64,
Spinel `2026.11.04.7026` (`a2d06115`, GCC 14.2.0), `-O 0`, CRuby 3.3.8.
All four programs compiled and exited 0, and their output matched CRuby.
The checked-in `.expected` files are the reviewed CRuby output from that
run. No custom worker or GC-stress setting was used for these probes.

`exception_shapes.rb` was then strengthened in review. It now picks the raised
class at run time and catches it with `rescue StandardError`, the shape rules
47 and 54 were seen in. All four programs were re-run with `run.sh` on Linux
x86_64, Spinel `2026.11.04.7026` (`a2d06115`, GCC 13.3.0), `-O 0` and CRuby
3.3.6. All four matched. This is new evidence for these small shapes only;
no production workaround was removed and no GC-stress, macOS or optimized
framework-wide equivalence is claimed.

| Program | Evidence | What remains unproven |
| --- | --- | --- |
| `value_shapes.rb` | Rules 12/18/60: destructuring, a reopened module's class variable, NUL-preserving append after a slice | Collection/GC lifetimes, other buffer optimizations and application-scale inference |
| `exception_shapes.rb` | Rules 46/47/53/54: qualified names (including `JSON::ParserError`), `is_a?` on a superclass after `rescue StandardError`, an unraised exception's message, and the superclass chain of user-defined classes | The superclass chain of package classes, namespace aliases, missing rescue constants (81/89), stack depth and framework fault classification |
| `openssl_dispatch.rb` | Rule 62: `getbyte` on a boxed String with OpenSSL loaded | Other builtin names and dispatch paths in a complete application |
| `decimal.rb` | Design D42: String construction, ordering and scale rounding of exact decimals; Float collapses two distinct decimal inputs | Framework integration, Float construction, storage precision and SQLite round-trips |

## Programs added on 2026-11-19

The document review of 2026-11-15 ran one small program per shape for most
of rules 1 to 50 of NOTES, each in a scratch directory. Those that match
CRuby are kept here, grouped into eight programs with one commented section
per shape, so that the next pin re-runs them instead of deriving them
again; each section says which rule it is a shape of and what it leaves
out. They were run with
`run.sh` beside the four above on 2026-11-19, on Linux x86_64, Spinel
`2026.11.04.7026` (`a2d06115`, GCC 13.3.0), `-O 0` and CRuby 3.3.6, and all
twelve matched. The `.expected` files are CRuby's output from that run.
The shapes of one file are compiled and inferred as one program, which the
separate probes of 2026-11-15 were not; both forms matched CRuby. A
mismatch in a grouped file may need its section run alone before it says
anything about its rule.

Each section is evidence for its own small shape on that build and nothing
wider. Most of these rules were seen in the framework or in a larger
program and were never reduced, so a matching probe does not show the
cause is gone (the "Probe passes" of docs/spinel-feedback.md, "Status by
rule"). None was run optimized, on macOS or under GC stress, and none of
these programs was the ground for removing a workaround.

| Program | Evidence |
| --- | --- |
| `dispatch_shapes.rb` | Rules 1 to 6, 30, 31, 40, 42: reflection with non-literal names over two methods, two ivars and two constants; `instance_eval(&blk)` of a block parameter and `instance_exec` with a literal block; a base method calling a subclass-only method; `self.class.foo`; base chain methods returning `self`; `Method` objects in an Array and a Hash; a Symbol passed from a stored block; `yield self` in a base class; `call` with another arity; a lambda as a keyword argument |
| `type_shapes.rb` | Rules 7 to 11, 14, 26, 29, 34, 35, 37, 39, 41, 43, 46: a Time in an ivar that starts as nil; `when Array` and `when Hash` before `when Time`; unseeded containers; one method name on unrelated classes; `include?` with polymorphic receiver and argument; `obj.attr += x` in a block; `obj[k] = v` behind a chain of `call(env)` objects; a constructing `case` in `+`; an Array `target` beside a String one; `def body=` beside `attr_accessor :body` and a writer calling a cast helper; a String Hash literal given other types and 5,000 small frames on a Thread. For 11 and 37 only the output is compared, not the cost those rules are about |
| `constant_order.rb` | Rule 17 (value constants): a constant read before its assignment raises NameError at top level, in a module body and in a class body |
| `io_shapes.rb` | Rules 19 and 28: STDOUT, STDERR and a StringIO behind one call site; `URI.decode_www_form_component` on malformed escapes |
| `socket_shapes.rb` | Rules 21 and 27: a socket as a `Thread.new` argument; the encoding of what `readpartial`, `read(n)` and `read_nonblock` return |
| `socket_bare_readpartial.rb` | Rule 20: a bare `readpartial` at `SPINEL_WORKERS=1` while another thread ticks, decided by a 0.35 s timing window |
| `rescue_shapes.rb` | Rules 32, 44, 45, 47, 50: `rescue => e` and `ensure` in a yielding method called from nested blocks; `break` and `return` in blocks of yielding methods; `is_a?` after `rescue StandardError` |
| `json_error_shapes.rb` | Rules 33, 48, 61: JSON's errors against `rescue StandardError`; `JSON::ParserError` as a value and as an argument in a class body |

## Programs added for rules 51 and later

The same review ran programs for rules 51 to 122, and found rule 123. Six
that match CRuby are
kept here; they were run with `run.sh` beside the twelve above on
2026-11-19, on the same machine and tools, and all eighteen matched. Three
of them are the matching half of a rule whose other half differed on that
build; that half was put under `differing/`, described below. Two of those
halves have since moved up ("Programs moved up from `differing/`").

| Program | Evidence |
| --- | --- |
| `block_call_shapes.rb` | Rule 69: a `&block` method that calls `block.call` and has an `ensure` or a `rescue`; a Proc passed two levels down and called with a user-class instance whose method the block calls |
| `container_shapes.rb` | Rules 51, 55, 86: Symbol and String keys through one `key.to_s` reader, and `keys` on a user class beside `Hash#keys`; an append through a value read out of a container; an Integer and a String Range matched by `when Range` from a Hash value and through a parameter |
| `outbound_socket_shapes.rb` | Rule 72, on Linux: SocketError for an unresolvable name, `entry[3]` of a `getaddrinfo` entry, `IPSocket.getaddress`, `Addrinfo.tcp`, `SO_ERROR` after a refused connect, the Errno class from a second `connect_nonblock`, `Errno::ECONNREFUSED::Errno`. Class names only, since the messages are worded differently; not `connect_timeout:` |
| `invalid_utf8_shapes.rb` | Rule 52: `valid_encoding?`, `split` raising ArgumentError and `index` on a UTF-8 literal with a stray byte |
| `builtin_superclass_no_module.rb` | Rule 104: the `superclass` chain of `ArgumentError` and `RuntimeError` in a program that defines no module |
| `json_nesting_shapes.rb` | Rule 61: `JSON.generate`'s NestingError against `rescue JSON::ParserError, StandardError`, `rescue StandardError`, `rescue JSON::ParserError`, and on a Thread whose `ensure` runs |

## Program added on 2026-11-20

| Program | Evidence |
| --- | --- |
| `define_method_shapes.rb` | NOTES, "Permanent: how CyberTrain is written for an ahead-of-time compiler": `define_method` with a literal name in a class body; a class macro defining two methods whose blocks read and write an ivar, called from a subclass body; a macro taking the name as its parameter, called with literal Symbols. Not a method defined while the program runs, which is refused (the two programs are in that section of NOTES) |

Run with `run.sh` beside the eighteen above on 2026-11-20, on Linux x86_64,
Spinel `2026.11.04.7026` (`a2d06115`, GCC 13.3.0), `-O 0` and CRuby 3.3.6:
all nineteen matched. Its `.expected` file is CRuby's output from that run.

## Programs moved up from `differing/`, 2026-11-21

Three programs that were written under `differing/` on 2026-11-19, because
they differed from CRuby on Spinel `2026.11.04.7026`, print CRuby's result
on Spinel `2026.11.15.7033` and were moved into this directory with an
`.expected` file, as the next section says. Their headers were written for
the run of 2026-11-19 and still describe it: what the header calls "the
compiled program" is the program built by `2026.11.04.7026`. Only the
paths in the headers were changed.

| Program | Evidence |
| --- | --- |
| `nil_only_puts_openssl.rb` | Rule 78: `@io.puts(line)` on a nil-only ivar with `openssl` required builds and prints `ok` |
| `float_range_boxed.rb` | Rule 86: a Range of Time built from a literal and with `Range.new`; a Float Range matched by `when Range` from a Hash value and through a parameter that also takes an Integer Range and an Array |
| `builtin_superclass_with_module.rb` | Rule 104: with a module defined, the `superclass` chain of a user-defined subclass of `ArgumentError`, of `RuntimeError` and of `ArgumentError` |

Run with `run.sh` beside the nineteen above on 2026-11-21, on Linux x86_64,
Spinel `2026.11.15.7033` (`a2f3bfaa`, GCC 13.3.0), `-O 0` and CRuby 3.3.6:
all twenty-two matched. The three `.expected` files are CRuby's output from
that day. Built with Spinel `2026.11.04.7026` (`a2d06115`) the same day as
a control, each of the three did what its header says. As for every
program here, this is evidence for these small programs on that build,
`-O 0`, on Linux, with no GC stress; no workaround was removed for it, and
rules 78, 86 and 104 stand until K, Q and AJ are closed.

## Programs that still differ: `differing/`

`run.sh` reads only the `.rb` files of this directory and expects each to
match CRuby, so a program that still differs, and one that needs the
framework on the load path, cannot sit beside them. Those of rules 51 and
later are in `differing/`. Each file's header gives the commands to run it
from the repository root and what CRuby and the compiled program did on
2026-11-19 (Linux x86_64, Spinel `2026.11.04.7026`, `a2d06115`, GCC 13.3.0,
`-O 0`, CRuby 3.3.6). Nothing runs them automatically. On a new pin, run
each by its header: a program that then matches CRuby moves up into this
directory with an `.expected` file, and the rule's row in
docs/spinel-feedback.md, "Status by rule", says so. The limits stated above
hold for these programs too: small programs, `-O 0`, Linux, no GC stress.

Seven programs were written here. Three moved up on 2026-11-21 (the
section above); for those the table gives what each showed while it was
here. The four that remain are the three that still differed in the run
of 2026-11-21 (docs/spinel-feedback.md, "Status by rule", rows 52, 122 and
123 on 2026.11.15.7033) and the one that needs the framework.

Two more were added on 2026-11-21, the last two rows of the table: the
reductions of rules 17 and 27, whose source was until then inline in
docs/spinel-feedback.md, "Status by rule". Their headers give the run that
produced them: Linux x86_64, Spinel `2026.11.15.7033` (`a2f3bfaa`, GCC
13.3.0), `-O 0`, CRuby 3.3.6, with Spinel `2026.11.04.7026` (`a2d06115`)
as a control.

| Program | What it showed |
| --- | --- |
| `differing/env_nonliteral_key.rb` | Rule 123: after `require "cybertrain/http/request"` and `require "cybertrain/config"`, `Config.env_or` answers the variable's name for a variable that is set. Needs `-I .`. Not reduced |
| `differing/require_in_regex.rb` | Rule 122: a require-shaped regex literal stops a `--strict-require` build; without the flag it is a warning and the match fails |
| `differing/invalid_utf8.rb` | Rule 52: `byteindex` off a character boundary returns an offset, and `strip` returns the String, where CRuby raises |
| `builtin_superclass_with_module.rb` (moved up) | Rule 104: with a module defined, `superclass` on `RuntimeError` is NoMethodError, after a user-defined subclass of `ArgumentError` walked its whole chain |
| `nil_only_puts_openssl.rb` (moved up) | Rule 78: the C compiler refuses `@io.puts(line)` on a nil-only ivar once `openssl` is required |
| `float_range_boxed.rb` (moved up) | Rule 86: a Range of Time raises TypeError when built; a Float Range is not matched by `when Range` from a Hash value or through a parameter |
| `differing/rescue_from_json_error.rb` | Rule 48, added 2026-11-20 (same machine and tools): `rescue_from JSON::ParserError` on `Cybertrain::Controller`, with a block and with `with:`, answers for an action's failed `JSON.parse`, and the error is re-raised when no handler is registered. Needs `-I .`; compiled side only, since CRuby cannot load the controller's SQLite FFI bindings without the preview's shim. It does not differ: it printed what it is written to print |
| `differing/class_before_definition.rb` | Rule 17, added 2026-11-21: a class used above its `class` statement runs, where CRuby raises NameError |
| `differing/socket_bytes.rb` | Rule 27, added 2026-11-21: `IO#gets` on a socket answers an ASCII-8BIT String, as under CRuby (a UTF-8 one when built by `2026.11.04.7026`), and an append of a socket's bytes to a UTF-8 String that holds non-ASCII appends, where CRuby raises Encoding::CompatibilityError |

## Running

Run them with the pinned toolchain, CRuby and the documented OpenSSL
development libraries configured:

```bash
spikes/rechecks/run.sh
```

The script prints its output directory first, then runs every probe even
after one fails, and exits 1 if any did. With the twenty-two programs here it
takes about a minute. Each failure names the file that holds its output. Each compile and each run is bounded at 180 seconds
(`RECHECK_TIMEOUT`; `gtimeout` on macOS, unbounded with a note when
neither exists). Compiler output other than the usual `src -> bin` line is
flagged as `warn`. A timeout or missing native library
is inconclusive; keep the diagnostics rather than calling it a language
regression. Review compile warnings even when output matches. Keep outputs
outside the package (rule 98); remove the temporary directory after inspection.
Do not automatically regenerate expectations on a mismatch.

These probes do not cover optimized builds, macOS, GC stress, all subcases of
a numbered rule, framework integration or SQLite decimal round-trips. When
using them to justify a compiler upgrade or workaround removal, add and run
the relevant integration/stress checks described in NOTES' maintenance
procedure. Retain a failing reduction as evidence even before it can become
a passing framework test.

A failing reduction does not belong in this directory as a `.rb` file,
because `run.sh` expects every program here to match CRuby, and neither
does a program that needs the framework on the load path, since `run.sh`
compiles each file on its own. Put such a program in `differing/` with a
header like the ones there. The reductions of rules 1 to 50 that still
differ were recorded before that directory existed and have their source
inline in docs/spinel-feedback.md, "Status by rule" (the table of
2026.11.04.7026): rule 54's `JSON::ParserError` superclass
walk, the stored block of rule 2, and rule 36's probe, which needs the
framework. Two that were inline there are in `differing/` since
2026-11-21: the class used above its definition of rule 17
(`differing/class_before_definition.rb`) and the `IO#gets` of rule 27
(`differing/socket_bytes.rb`).
